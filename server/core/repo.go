package core

import (
	"context"
	"fmt"

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

type Repo[K RepoKey, V RepoValue] interface {
	Keys() (<-chan K, error)
	Get(key K) (V, error)
	History(key K) ([]V, error)
	Put(key K, value V) error
	Delete(key K) error
	Watch() (<-chan RepoUpdate[K, V], error)
}

type Operation string

const (
	OperationAdd    Operation = "add"
	OperationUpdate Operation = "update"
	OperationDelete Operation = "delete"
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

// repo is a standard repository that uses a key-value store to store values.
// It is used to store values in a key-value store and to watch for updates to the values.
//
// The values are stored as bytes in the key-value store.
// The values are deserialized from bytes to the V type when retrieved.
// The values are serialized to bytes when stored.
type repo[K RepoKey, V RepoValue] struct {
	updates      chan RepoUpdate[K, V]
	ctx          context.Context
	kv           jetstream.KeyValue
	lastRevision uint64
	stringToKey  func(string) K
}

// NewRepo creates a new StandardRepo instance with the provided context and key-value store.
// The repo is cleaned up when the context is cancelled.
func NewRepo[K RepoKey, V RepoValue](
	ctx context.Context,
	kv jetstream.KeyValue,
	stringToKey func(string) K,
) (Repo[K, V], error) {
	return &repo[K, V]{
		updates:      make(chan RepoUpdate[K, V]),
		ctx:          ctx,
		kv:           kv,
		stringToKey:  stringToKey,
		lastRevision: 0,
	}, nil
}

func (r *repo[K, V]) Keys() (<-chan K, error) {
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

func (r *repo[K, V]) Get(key K) (V, error) {
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

func (r *repo[K, V]) History(key K) ([]V, error) {
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

func (r *repo[K, V]) Put(key K, value V) error {
	_, err := r.kv.Put(r.ctx, key.String(), value.Bytes())
	if err != nil {
		return fmt.Errorf("put: %w", err)
	}
	return nil
}

func (r *repo[K, V]) Delete(key K) error {
	err := r.kv.Delete(r.ctx, key.String())
	if err != nil {
		return fmt.Errorf("delete: %w", err)
	}
	return nil
}

func (r *repo[K, V]) Watch() (<-chan RepoUpdate[K, V], error) {
	return r.updates, nil
}
