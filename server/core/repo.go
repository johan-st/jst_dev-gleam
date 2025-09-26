package core

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// RepoValue is a value type that can be used to identify a repository entry.
// It must have a Bytes() method that returns a slice of bytes.
type RepoValue[V any] interface {
	Bytes() []byte
	FromBytes(value []byte) (V, error)
}

// RepoKv common interface.
type RepoKv[V RepoValue[V]] interface {
	Keys() (<-chan string, error)
	Get(key string) (V, error)
	History(key string) ([]V, error)
	Put(key string, value V) error
	Delete(key string) error
	Watch() (<-chan RepoUpdate[V], error)
	Close() error
}

// RepoAppendOnly common interface.
type RepoAppendOnly[V RepoValue[V]] interface {
	Append(subject string, value V) error
	Watch(subject string) (<-chan RepoMsg[V], error)
	Close() error
}

// RepoMsg is a message from a repository.
type RepoMsg[V RepoValue[V]] struct {
	Headers nats.Header
	Data    V
	Err     error
}

func (m *RepoMsg[V]) IsError() bool {
	return m.Err != nil
}

func (m *RepoMsg[V]) Error() error {
	return m.Err
}

// RepoUpdate is an update from a repository.
type RepoUpdate[V RepoValue[V]] struct {
	operation Operation
	key       string
	value     V
}

type Operation string

const (
	OperationAdd     Operation = "add"
	OperationUpdate  Operation = "update"
	OperationDelete  Operation = "delete"
	OperationUnknown Operation = "unknown"
)

func (u *RepoUpdate[V]) IsPut() bool {
	return u.operation == OperationAdd
}

func (u *RepoUpdate[V]) IsUpdate() bool {
	return u.operation == OperationUpdate
}

func (u *RepoUpdate[V]) IsDelete() bool {
	return u.operation == OperationDelete
}

func (u *RepoUpdate[V]) Key() string {
	return u.key
}

func (u *RepoUpdate[V]) Value() V {
	return u.value
}

// --- REPO KV ---

// repoKv is a standard repository that uses a key-value store to store values.
// In memory cache is used to store values. It is updated when the key-value store is updated.
// TODO: make the cache an LRU cache.
// TODO: add a size limit to the cache.
type repoKv[V RepoValue[V]] struct {
	l            *jst_log.Logger
	kv           jetstream.KeyValue
	ctx          context.Context
	cache        map[string]V
	cacheMu      sync.RWMutex
	kvWatcher    jetstream.KeyWatcher
	watchers     []chan RepoUpdate[V]
	watchersMu   sync.RWMutex
	closeOnce    sync.Once
	closed       atomic.Bool
	lastRevision uint64
	inSyncWg     sync.WaitGroup
}

// NewRepoKv creates a new RepoKv instance with the provided context and key-value store.
// The repo is cleaned up when the context is cancelled.
func NewRepoKv[V RepoValue[V]](
	ctx context.Context,
	l *jst_log.Logger,
	kv jetstream.KeyValue,
) (RepoKv[V], error) {
	r := &repoKv[V]{
		l:            l,
		kv:           kv,
		ctx:          ctx,
		cache:        make(map[string]V),
		cacheMu:      sync.RWMutex{},
		kvWatcher:    nil,
		watchers:     make([]chan RepoUpdate[V], 0),
		watchersMu:   sync.RWMutex{},
		closeOnce:    sync.Once{},
		closed:       atomic.Bool{},
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
	go func(r *repoKv[V]) {
		for {
			select {
			case <-r.ctx.Done():
				r.Close()
				return
			case entry := <-watcher.Updates():
				if entry == nil {
					r.inSyncWg.Done()
					return
				}
				r.cacheMu.Lock()
				r.lastRevision = entry.Revision()
				r.handleUpdateNoLock(entry)
				r.cacheMu.Unlock()
			}
		}
	}(r)
	go func(r *repoKv[V]) {
		l.Debug("waiting for in sync")
		r.inSyncWg.Wait()
		r.l.Debug("repo in sync, starting broadcast loop")
		r.broadcastLoop()
	}(r)
	return r, nil
}

func (r *repoKv[V]) Keys() (<-chan string, error) {
	r.inSyncWg.Wait()
	keys, err := r.kv.ListKeys(r.ctx)
	if err != nil {
		return nil, fmt.Errorf("keys: %w", err)
	}
	return keys.Keys(), nil
}

func (r *repoKv[V]) Get(key string) (V, error) {
	r.inSyncWg.Wait()
	var value V
	entry, err := r.kv.Get(r.ctx, key)
	if err != nil {
		return value, fmt.Errorf("get: %w", err)
	}
	bytes := entry.Value()
	value, err = value.FromBytes(bytes)
	if err != nil {
		return value, fmt.Errorf("value from bytes: %w", err)
	}
	return value, nil
}

func (r *repoKv[V]) History(key string) ([]V, error) {
	r.inSyncWg.Wait()
	var (
		entries []V
	)

	kvEntries, err := r.kv.History(r.ctx, key)
	if err != nil {
		return entries, fmt.Errorf("get: %w", err)
	}

	for _, entry := range kvEntries {
		var value V
		value, err = value.FromBytes(entry.Value())
		if err != nil {
			return entries, fmt.Errorf("value from bytes: %w", err)
		}
		entries = append(entries, value)
	}
	return entries, nil
}

func (r *repoKv[V]) Put(key string, value V) error {
	r.inSyncWg.Wait()
	_, err := r.kv.Put(r.ctx, key, value.Bytes())
	if err != nil {
		return fmt.Errorf("put: %w", err)
	}
	return nil
}

func (r *repoKv[V]) Delete(key string) error {
	r.inSyncWg.Wait()
	err := r.kv.Delete(r.ctx, key)
	if err != nil {
		return fmt.Errorf("delete: %w", err)
	}
	return nil
}

func (r *repoKv[V]) Watch() (<-chan RepoUpdate[V], error) {
	r.inSyncWg.Wait()
	// Create a new channel for this watcher
	watcherChan := make(chan RepoUpdate[V])

	// Register the watcher
	r.watchersMu.Lock()
	r.watchers = append(r.watchers, watcherChan)
	r.watchersMu.Unlock()

	// Return the channel
	return watcherChan, nil
}

func (r *repoKv[V]) Close() error {
	if !r.closed.CompareAndSwap(false, true) {
		r.l.Debug("repo already closed")
		return fmt.Errorf("repo already closed")
	}
	// Stop the KV watcher
	if r.kvWatcher != nil {
		_ = r.kvWatcher.Stop()
	}

	// Close all watcher channels
	r.watchersMu.Lock()
	for _, watcherChan := range r.watchers {
		close(watcherChan)
	}
	r.watchers = make([]chan RepoUpdate[V], 0)
	r.watchersMu.Unlock()

	// Close the main updates channel
	// The original code had a `r.updates` field, but it's not defined in the provided file.
	// Assuming it's a placeholder for a channel that would be used for updates.
	// For now, removing it as it's not part of the provided file.

	return nil
}

// entryToUpdate converts a NATS KeyValue entry to a RepoUpdate
func (r *repoKv[V]) entryToUpdate(entry jetstream.KeyValueEntry) RepoUpdate[V] {
	key := entry.Key()

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
		return RepoUpdate[V]{
			operation: operation,
			key:       key,
		}
	}

	// For put operations, deserialize the value
	var value V
	value, err := value.FromBytes(entry.Value())
	if err != nil {
		// Log error but don't fail the update
		r.l.Error("value from bytes: " + err.Error())
		return RepoUpdate[V]{
			operation: operation,
			key:       key,
		}
	}

	return RepoUpdate[V]{
		operation: operation,
		key:       key,
		value:     value,
	}
}

// broadcastUpdate sends an update to all registered watchers
func (r *repoKv[V]) broadcastUpdate(update RepoUpdate[V]) {
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

func (r *repoKv[V]) broadcastLoop() {

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
				r.l.Debug("broadcastLoop received nil entry, continuing")
				continue
			}
			r.handleUpdate(entry)
			r.broadcastUpdate(r.entryToUpdate(entry))
		}
	}
}

func (r *repoKv[V]) handleUpdate(entry jetstream.KeyValueEntry) {
	r.cacheMu.Lock()
	defer r.cacheMu.Unlock()
	r.handleUpdateNoLock(entry)
}

func (r *repoKv[V]) handleUpdateNoLock(entry jetstream.KeyValueEntry) {
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

// --- REPO IN MEM ---

type repoInMem[V RepoValue[V]] struct {
	data       map[string]V
	dataMu     sync.RWMutex
	watchers   []chan RepoUpdate[V]
	watchersMu sync.RWMutex
}

func NewRepoInMem[V RepoValue[V]]() RepoKv[V] {
	return &repoInMem[V]{
		data:       make(map[string]V),
		dataMu:     sync.RWMutex{},
		watchers:   make([]chan RepoUpdate[V], 0),
		watchersMu: sync.RWMutex{},
	}
}

func (r *repoInMem[V]) Keys() (<-chan string, error) {
	r.dataMu.RLock()
	defer r.dataMu.RUnlock()
	keysChan := make(chan string)
	go func() {
		for key := range r.data {
			keysChan <- key
		}
		close(keysChan)
	}()
	return keysChan, nil
}

func (r *repoInMem[V]) Get(key string) (V, error) {
	r.dataMu.RLock()
	defer r.dataMu.RUnlock()
	var value V
	value, ok := r.data[key]
	if !ok {
		return value, fmt.Errorf("key not found")
	}
	return value, nil
}

func (r *repoInMem[V]) History(key string) ([]V, error) {
	return []V{}, fmt.Errorf("not available on RepoInMem")
}

func (r *repoInMem[V]) Put(key string, value V) error {
	r.dataMu.Lock()
	_, existed := r.data[key]
	r.data[key] = value
	r.dataMu.Unlock()

	op := OperationAdd
	if existed {
		op = OperationUpdate
	}

	r.broadcastUpdate(RepoUpdate[V]{
		operation: op,
		key:       key,
		value:     value,
	})
	return nil
}

func (r *repoInMem[V]) Delete(key string) error {
	r.dataMu.Lock()
	delete(r.data, key)
	r.dataMu.Unlock()

	r.broadcastUpdate(RepoUpdate[V]{
		operation: OperationDelete,
		key:       key,
	})
	return nil
}

func (r *repoInMem[V]) Watch() (<-chan RepoUpdate[V], error) {
	r.watchersMu.Lock()
	defer r.watchersMu.Unlock()
	watcherChan := make(chan RepoUpdate[V])
	r.watchers = append(r.watchers, watcherChan)
	return watcherChan, nil
}

func (r *repoInMem[V]) Close() error {
	return nil
}

func (r *repoInMem[V]) broadcastUpdate(update RepoUpdate[V]) {
	r.watchersMu.RLock()
	defer r.watchersMu.RUnlock()
	for _, watcher := range r.watchers {
		watcher <- update
	}
}

// --- REPO APPEND ONLY ---

type repoAppendOnly[V RepoValue[V]] struct {
	l   *jst_log.Logger
	js  jetstream.JetStream
	ctx context.Context
}

// NewRepoAppendOnly creates a new repository that appends and listens to a JetStream stream.
func NewRepoAppendOnly[V RepoValue[V]](ctx context.Context, l *jst_log.Logger, js jetstream.JetStream) RepoAppendOnly[V] {
	l.Debug("creating repo append only")
	return &repoAppendOnly[V]{
		l:   l,
		js:  js,
		ctx: ctx,
	}
}

func (r *repoAppendOnly[V]) Append(sub string, value V) error {
	r.l.Debug("appending to subject: " + sub)
	if err := SubjectValid(sub); err != nil {
		return fmt.Errorf("append: %w", err)
	}

	_, err := r.js.Publish(r.ctx, sub, value.Bytes())
	if err != nil {
		r.l.Error("publish: " + err.Error())
		return fmt.Errorf("append: %w", err)
	}

	return nil
}

func (r *repoAppendOnly[V]) Watch(subject string) (<-chan RepoMsg[V], error) {
	var (
		watcherChan = make(chan RepoMsg[V], 64)
		errChan     = make(chan error, 1)
	)

	go func() {
		defer close(watcherChan)
		_, err := r.js.Conn().Subscribe(subject, func(msg *nats.Msg) {
			var value V
			value, err := value.FromBytes(msg.Data)
			if err != nil {
				watcherChan <- RepoMsg[V]{
					Headers: msg.Header,
					Data:    value,
					Err:     fmt.Errorf("value from bytes: %w", err),
				}
				return
			}
			watcherChan <- RepoMsg[V]{
				Headers: msg.Header,
				Data:    value,
				Err:     nil,
			}
		})
		if err != nil {
			errChan <- fmt.Errorf("subscribe: %w", err)
			close(errChan)
			return
		}
		defer close(errChan)
	}()

	err := <-errChan
	if err != nil {
		close(watcherChan)
		return nil, err
	}
	return watcherChan, nil
}

func (r *repoAppendOnly[V]) Close() error {
	panic("not implemented")
}
