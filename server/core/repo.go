package core

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go/jetstream"
)

// RepoKey is a key type that can be used to identify a repository entry.
// It must be comparable and have a String() method.
type RepoKey interface {
	comparable
	String() string
}

// RepoValue is a value type that can be used to identify a repository entry.
// It must have a Bytes() method that returns a slice of bytes.
type RepoValue interface {
	Bytes() []byte
	FromBytes(value []byte) error
}

// Repo common interface.
type Repo[K RepoKey, V RepoValue] interface {
	Keys() (<-chan K, error)
	Get(key K) (V, error)
	History(key K) ([]V, error)
	Put(key K, value V) error
	Delete(key K) error
	Watch() (<-chan RepoUpdate[K, V], error)
	Close() error
}

type Operation string

const (
	OperationAdd     Operation = "add"
	OperationUpdate  Operation = "update"
	OperationDelete  Operation = "delete"
	OperationUnknown Operation = "unknown"
)

type RepoUpdate[K RepoKey, V RepoValue] struct {
	operation Operation
	key       K
	value     V
}

func (u *RepoUpdate[K, V]) IsPut() bool {
	return u.operation == OperationAdd
}

func (u *RepoUpdate[K, V]) IsUpdate() bool {
	return u.operation == OperationUpdate
}

func (u *RepoUpdate[K, V]) IsDelete() bool {
	return u.operation == OperationDelete
}

func (u *RepoUpdate[K, V]) Key() K {
	return u.key
}

func (u *RepoUpdate[K, V]) Value() V {
	return u.value
}

// --- STANDARD REPO ---

// repoKv is a standard repository that uses a key-value store to store values.
// It is used to store values in a key-value store and to watch for updates to the values.
type repoKv[K RepoKey, V RepoValue] struct {
	l            *jst_log.Logger
	kv           jetstream.KeyValue
	ctx          context.Context
	cache        map[K]V
	cacheMu      sync.RWMutex
	kvWatcher    jetstream.KeyWatcher
	watchers     []chan RepoUpdate[K, V]
	watchersMu   sync.RWMutex
	closeOnce    sync.Once
	closed       atomic.Bool
	stringToKey  func(string) K
	lastRevision uint64
	inSyncWg     sync.WaitGroup
}

// NewRepoKv creates a new StandardRepo instance with the provided context and key-value store.
// The repo is cleaned up when the context is cancelled.
func NewRepoKv[K RepoKey, V RepoValue](
	ctx context.Context,
	l *jst_log.Logger,
	kv jetstream.KeyValue,
	stringToKey func(string) K,
) (Repo[K, V], error) {
	r := &repoKv[K, V]{
		l:            l,
		kv:           kv,
		ctx:          ctx,
		cache:        make(map[K]V),
		cacheMu:      sync.RWMutex{},
		kvWatcher:    nil,
		watchers:     make([]chan RepoUpdate[K, V], 0),
		watchersMu:   sync.RWMutex{},
		closeOnce:    sync.Once{},
		closed:       atomic.Bool{},
		stringToKey:  stringToKey,
		lastRevision: 0,
		inSyncWg:     sync.WaitGroup{},
	}

	// Start watching the KeyValue store for changes
	watcher, err := kv.WatchAll(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to create kv watcher: %w", err)
	}
	r.kvWatcher = watcher
	r.inSyncWg.Add(1)
	go func(r *repoKv[K, V]) {
		defer r.inSyncWg.Done()
		for {
			select {
			case <-r.ctx.Done():
				r.Close()
				return
			case entry := <-watcher.Updates():
				r.cacheMu.Lock()
				defer r.cacheMu.Unlock()
				if entry == nil {
					r.l.Debug("inSyncWg.Done")
					r.inSyncWg.Done()
					continue
				}
				r.lastRevision = entry.Revision()
				r.handleUpdateNoLock(entry)
			}
		}
	}(r)
	go func(r *repoKv[K, V]) {
		r.inSyncWg.Wait()
		r.l.Debug("repo in sync, starting broadcast loop")
		r.broadcastLoop()
	}(r)
	return r, nil
}

func (r *repoKv[K, V]) Keys() (<-chan K, error) {
	r.inSyncWg.Wait()
	keys, err := r.kv.ListKeys(r.ctx)
	if err != nil {
		return nil, fmt.Errorf("keys: %w", err)
	}
	keysChan := make(chan K)
	go func() {
		for key := range keys.Keys() {
			keysChan <- r.stringToKey(key)
		}
		close(keysChan)
	}()
	return keysChan, nil
}

func (r *repoKv[K, V]) Get(key K) (V, error) {
	r.inSyncWg.Wait()
	var value V
	entry, err := r.kv.Get(r.ctx, key.String())
	if err != nil {
		return value, fmt.Errorf("get: %w", err)
	}
	err = value.FromBytes(entry.Value())
	if err != nil {
		return value, fmt.Errorf("value from bytes: %w", err)
	}
	return value, nil
}

func (r *repoKv[K, V]) History(key K) ([]V, error) {
	r.inSyncWg.Wait()
	var (
		entries []V
	)

	kvEntries, err := r.kv.History(r.ctx, key.String())
	if err != nil {
		return entries, fmt.Errorf("get: %w", err)
	}

	for _, entry := range kvEntries {
		var value V
		err = value.FromBytes(entry.Value())
		if err != nil {
			return entries, fmt.Errorf("value from bytes: %w", err)
		}
		entries = append(entries, value)
	}
	return entries, nil
}

func (r *repoKv[K, V]) Put(key K, value V) error {
	r.inSyncWg.Wait()
	_, err := r.kv.Put(r.ctx, key.String(), value.Bytes())
	if err != nil {
		return fmt.Errorf("put: %w", err)
	}
	return nil
}

func (r *repoKv[K, V]) Delete(key K) error {
	r.inSyncWg.Wait()
	err := r.kv.Delete(r.ctx, key.String())
	if err != nil {
		return fmt.Errorf("delete: %w", err)
	}
	return nil
}

func (r *repoKv[K, V]) Watch() (<-chan RepoUpdate[K, V], error) {
	r.inSyncWg.Wait()
	// Create a new channel for this watcher
	watcherChan := make(chan RepoUpdate[K, V])

	// Register the watcher
	r.watchersMu.Lock()
	r.watchers = append(r.watchers, watcherChan)
	r.watchersMu.Unlock()

	// Return the channel
	return watcherChan, nil
}

func (r *repoKv[K, V]) Close() error {
	if !r.closed.CompareAndSwap(false, true) {
		r.l.Debug("repo already closed")
		return fmt.Errorf("repo already closed")
	}
	r.closed.Store(true)
	// Stop the KV watcher
	if r.kvWatcher != nil {
		_ = r.kvWatcher.Stop()
	}

	// Close all watcher channels
	r.watchersMu.Lock()
	for _, watcherChan := range r.watchers {
		close(watcherChan)
	}
	r.watchers = make([]chan RepoUpdate[K, V], 0)
	r.watchersMu.Unlock()

	// Close the main updates channel
	// The original code had a `r.updates` field, but it's not defined in the provided file.
	// Assuming it's a placeholder for a channel that would be used for updates.
	// For now, removing it as it's not part of the provided file.

	return nil
}

// entryToUpdate converts a NATS KeyValue entry to a RepoUpdate
func (r *repoKv[K, V]) entryToUpdate(entry jetstream.KeyValueEntry) RepoUpdate[K, V] {
	key := r.stringToKey(entry.Key())

	// Determine operation type
	var operation Operation
	switch entry.Operation() {
	case jetstream.KeyValuePut:
		operation = OperationAdd
	case jetstream.KeyValueDelete:
		operation = OperationDelete
	case jetstream.KeyValuePurge:
		operation = OperationDelete
	default:
		r.l.Error("unknown operation: " + entry.Operation().String())
		operation = OperationUnknown
	}

	// For delete operations, we don't need to deserialize the value
	if operation == OperationDelete {
		return RepoUpdate[K, V]{
			operation: operation,
			key:       key,
		}
	}

	// For put operations, deserialize the value
	var value V
	err := value.FromBytes(entry.Value())
	if err != nil {
		// Log error but don't fail the update
		r.l.Error("value from bytes: " + err.Error())
		return RepoUpdate[K, V]{
			operation: operation,
			key:       key,
		}
	}

	return RepoUpdate[K, V]{
		operation: operation,
		key:       key,
		value:     value,
	}
}

// broadcastUpdate sends an update to all registered watchers
func (r *repoKv[K, V]) broadcastUpdate(update RepoUpdate[K, V]) {
	r.watchersMu.RLock()
	watchers := r.watchers[:]
	r.watchersMu.RUnlock()

	for _, watcherChan := range watchers {
		select {
		case watcherChan <- update:
		case <-r.ctx.Done():
			return
		case <-time.After(100 * time.Millisecond):
			r.l.Error("watcher channel full, skipping update")
		}
	}
}

func (r *repoKv[K, V]) broadcastLoop() {
	watcher, err := r.kv.WatchAll(r.ctx)
	if err != nil {
		r.l.Error("failed to create watcher: " + err.Error())
		return
	}
	r.kvWatcher = watcher
	for {
		select {
		case <-r.ctx.Done():
			return
		case entry := <-watcher.Updates():
			if entry == nil {
				panic("broadcastLoop ran before we where in sync")
			}
			r.handleUpdate(entry)
			r.broadcastUpdate(r.entryToUpdate(entry))
		}
	}
}

func (r *repoKv[K, V]) handleUpdate(entry jetstream.KeyValueEntry) {
	r.cacheMu.Lock()
	defer r.cacheMu.Unlock()
	r.handleUpdateNoLock(entry)
}

func (r *repoKv[K, V]) handleUpdateNoLock(entry jetstream.KeyValueEntry) {
	update := r.entryToUpdate(entry)
	switch {
	case update.IsPut():
		r.cache[update.Key()] = update.Value()
	case update.IsUpdate():
		r.cache[update.Key()] = update.Value()
	case update.IsDelete():
		delete(r.cache, update.Key())
	}
}

// Simple Repo

type simpleRepo[K RepoKey, V RepoValue] struct {
	data       map[K]V
	dataMu     sync.RWMutex
	watchers   []chan RepoUpdate[K, V]
	watchersMu sync.RWMutex
}

func NewRepoSimple[K RepoKey, V RepoValue]() Repo[K, V] {
	return &simpleRepo[K, V]{
		data:       make(map[K]V),
		dataMu:     sync.RWMutex{},
		watchers:   make([]chan RepoUpdate[K, V], 0),
		watchersMu: sync.RWMutex{},
	}
}

// Keys() (<-chan K, error)

func (r *simpleRepo[K, V]) Keys() (<-chan K, error) {
	r.dataMu.RLock()
	defer r.dataMu.RUnlock()
	keysChan := make(chan K)
	go func() {
		for key := range r.data {
			keysChan <- key
		}
		close(keysChan)
	}()
	return keysChan, nil
}

// Get(key K) (V, error)
func (r *simpleRepo[K, V]) Get(key K) (V, error) {
	r.dataMu.RLock()
	defer r.dataMu.RUnlock()
	var value V
	value, ok := r.data[key]
	if !ok {
		return value, fmt.Errorf("key not found")
	}
	return value, nil
}

// History(key K) ([]V, error)
func (r *simpleRepo[K, V]) History(key K) ([]V, error) {
	return []V{}, fmt.Errorf("not available on SimpleRepo")
}

// Put(key K, value V) error
func (r *simpleRepo[K, V]) Put(key K, value V) error {
	r.dataMu.Lock()
	_, existed := r.data[key]
	r.data[key] = value
	r.dataMu.Unlock()

	op := OperationAdd
	if existed {
		op = OperationUpdate
	}

	r.broadcastUpdate(RepoUpdate[K, V]{
		operation: op,
		key:       key,
		value:     value,
	})
	return nil
}

// Delete(key K) error
func (r *simpleRepo[K, V]) Delete(key K) error {
	r.dataMu.Lock()
	delete(r.data, key)
	r.dataMu.Unlock()

	r.broadcastUpdate(RepoUpdate[K, V]{
		operation: OperationDelete,
		key:       key,
	})
	return nil
}

// Watch() (<-chan RepoUpdate[K, V], error)
func (r *simpleRepo[K, V]) Watch() (<-chan RepoUpdate[K, V], error) {
	r.watchersMu.Lock()
	defer r.watchersMu.Unlock()
	watcherChan := make(chan RepoUpdate[K, V])
	r.watchers = append(r.watchers, watcherChan)
	return watcherChan, nil
}

// Close() error
func (r *simpleRepo[K, V]) Close() error {
	return nil
}

func (r *simpleRepo[K, V]) broadcastUpdate(update RepoUpdate[K, V]) {
	r.watchersMu.RLock()
	defer r.watchersMu.RUnlock()
	for _, watcher := range r.watchers {
		watcher <- update
	}
}
