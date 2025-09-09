package core

import (
	"context"
	"encoding/json"
	"sync"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go/jetstream"
)

// SimpleRepository provides a minimal KV repository with automatic sync
type SimpleRepository struct {
	kv     jetstream.KeyValue
	logger *jst_log.Logger
	cache  map[string]interface{}
	mu     sync.RWMutex
}

// NewSimpleRepository creates a minimal repository
func NewSimpleRepository(kv jetstream.KeyValue, logger *jst_log.Logger) *SimpleRepository {
	repo := &SimpleRepository{
		kv:     kv,
		logger: logger,
		cache:  make(map[string]interface{}),
	}
	
	// Start watching for changes
	go repo.watch()
	
	return repo
}

// Get retrieves a value by key
func (r *SimpleRepository) Get(key string) (interface{}, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.cache[key], true
}

// Set stores a value
func (r *SimpleRepository) Set(key string, value interface{}) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	
	_, err = r.kv.Put(context.Background(), key, data)
	return err
}

// Delete removes a key
func (r *SimpleRepository) Delete(key string) error {
	return r.kv.Delete(context.Background(), key)
}

// List returns all keys
func (r *SimpleRepository) List() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	
	keys := make([]string, 0, len(r.cache))
	for key := range r.cache {
		keys = append(keys, key)
	}
	return keys
}

// watch monitors KV changes and updates cache
func (r *SimpleRepository) watch() {
	watcher, err := r.kv.WatchAll(context.Background())
	if err != nil {
		r.logger.Error("failed to watch KV: %v", err)
		return
	}
	defer watcher.Stop()
	
	// Initial sync
	r.syncAll()
	
	// Watch for changes
	for update := range watcher.Updates() {
		if update == nil {
			continue
		}
		
		key := update.Key()
		
		switch update.Operation() {
		case jetstream.KeyValuePut:
			var value interface{}
			if err := json.Unmarshal(update.Value(), &value); err == nil {
				r.mu.Lock()
				r.cache[key] = value
				r.mu.Unlock()
			}
		case jetstream.KeyValueDelete:
			r.mu.Lock()
			delete(r.cache, key)
			r.mu.Unlock()
		}
	}
}

// syncAll loads all data from KV store
func (r *SimpleRepository) syncAll() {
	keys, err := r.kv.ListKeys(context.Background())
	if err != nil {
		r.logger.Error("failed to list keys: %v", err)
		return
	}
	
	r.mu.Lock()
	defer r.mu.Unlock()
	
	for key := range keys.Keys() {
		entry, err := r.kv.Get(context.Background(), key)
		if err != nil {
			continue
		}
		
		var value interface{}
		if err := json.Unmarshal(entry.Value(), &value); err == nil {
			r.cache[key] = value
		}
	}
}
