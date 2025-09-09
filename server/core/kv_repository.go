package core

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go/jetstream"
)

// RepositoryConfig holds configuration for the KV repository
type RepositoryConfig struct {
	// KV store name
	KVStoreName string

	// Cache configuration
	CacheConfig CacheConfig

	// Sync configuration
	SyncConfig SyncConfig

	// Logger
	Logger *jst_log.Logger
}

// SyncConfig holds synchronization configuration
type SyncConfig struct {
	// Batch size for bulk operations
	BatchSize int
}

// KVRepository provides a local-like interface to a KV store with automatic synchronization
type KVRepository struct {
	kvStore jetstream.KeyValue
	config  RepositoryConfig
	logger  *jst_log.Logger

	// Local cache
	cache   map[string]*CacheEntry
	cacheMu sync.RWMutex

	// KV watcher
	watcher   jetstream.KeyWatcher
	watcherMu sync.RWMutex

	// Event handlers
	eventHandlers map[string][]func(string, interface{}, interface{})
	handlersMu    sync.RWMutex

	// Context for cancellation
	ctx    context.Context
	cancel context.CancelFunc
}

// RepositoryEvent represents a repository event
type RepositoryEvent struct {
	Type      string      `json:"type"`      // created, updated, deleted
	Key       string      `json:"key"`       // The key that changed
	OldValue  interface{} `json:"old_value"` // Previous value (nil for created)
	NewValue  interface{} `json:"new_value"` // New value (nil for deleted)
	Timestamp time.Time   `json:"timestamp"` // When the event occurred
	Revision  uint64      `json:"revision"`  // KV revision number
}

// NewKVRepository creates a new KV repository
func NewKVRepository(kvStore jetstream.KeyValue, config RepositoryConfig) *KVRepository {
	ctx, cancel := context.WithCancel(context.Background())

	repo := &KVRepository{
		kvStore:       kvStore,
		config:        config,
		logger:        config.Logger,
		cache:         make(map[string]*CacheEntry),
		eventHandlers: make(map[string][]func(string, interface{}, interface{})),
		ctx:           ctx,
		cancel:        cancel,
	}

	// Set defaults
	if repo.config.SyncConfig.BatchSize == 0 {
		repo.config.SyncConfig.BatchSize = 100
	}

	return repo
}

// Start begins watching the KV store for changes
func (r *KVRepository) Start() error {
	r.logger.Info("starting KV repository with real-time watching")

	// Initial sync to populate cache
	if err := r.syncAll(); err != nil {
		return fmt.Errorf("initial sync failed: %w", err)
	}

	r.logger.Info("KV repository synchronized with %d entries", len(r.cache))

	// Start KV watcher for real-time updates
	go r.startKVWatcher()

	return nil
}

// Stop stops watching and cleans up resources
func (r *KVRepository) Stop() error {
	r.logger.Info("stopping KV repository")

	// Cancel context
	r.cancel()

	// Stop watcher
	r.watcherMu.Lock()
	if r.watcher != nil {
		r.watcher.Stop()
		r.watcher = nil
	}
	r.watcherMu.Unlock()

	r.logger.Info("KV repository stopped")
	return nil
}

// Get retrieves a value by key
func (r *KVRepository) Get(key string) (interface{}, bool) {
	r.cacheMu.RLock()
	defer r.cacheMu.RUnlock()

	entry, exists := r.cache[key]
	if !exists {
		return nil, false
	}

	// Check if entry has expired
	if time.Since(entry.CreatedAt) > entry.TTL {
		return nil, false
	}

	return entry.Value, true
}

// GetWithRevision retrieves a value by key with its revision
func (r *KVRepository) GetWithRevision(key string) (interface{}, uint64, bool) {
	r.cacheMu.RLock()
	defer r.cacheMu.RUnlock()

	entry, exists := r.cache[key]
	if !exists {
		return nil, 0, false
	}

	// Check if entry has expired
	if time.Since(entry.CreatedAt) > entry.TTL {
		return nil, 0, false
	}

	return entry.Value, entry.Version, true
}

// Set sets a value in the repository (and KV store)
func (r *KVRepository) Set(key string, value interface{}) error {
	return r.SetWithTTL(key, value, r.config.CacheConfig.DefaultTTL)
}

// SetWithTTL sets a value with a specific TTL
func (r *KVRepository) SetWithTTL(key string, value interface{}, ttl time.Duration) error {
	// Marshal the value
	data, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("failed to marshal value: %w", err)
	}

	// Store in KV
	rev, err := r.kvStore.Put(r.ctx, key, data)
	if err != nil {
		return fmt.Errorf("failed to store in KV: %w", err)
	}

	// Update local cache
	r.updateCache(key, value, rev, ttl)

	// Emit event
	r.emitEvent("updated", key, nil, value)

	r.logger.Debug("set key %s with revision %d", key, rev)
	return nil
}

// Delete removes a key from the repository
func (r *KVRepository) Delete(key string) error {
	// Get old value for event
	oldValue, _, _ := r.GetWithRevision(key)

	// Delete from KV
	if err := r.kvStore.Delete(r.ctx, key); err != nil {
		return fmt.Errorf("failed to delete from KV: %w", err)
	}

	// Remove from cache
	r.cacheMu.Lock()
	delete(r.cache, key)
	r.cacheMu.Unlock()

	// Emit event
	r.emitEvent("deleted", key, oldValue, nil)

	r.logger.Debug("deleted key %s", key)
	return nil
}

// List returns all keys in the repository
func (r *KVRepository) List() []string {
	r.cacheMu.RLock()
	defer r.cacheMu.RUnlock()

	keys := make([]string, 0, len(r.cache))
	for key := range r.cache {
		keys = append(keys, key)
	}

	return keys
}

// ListWithValues returns all key-value pairs
func (r *KVRepository) ListWithValues() map[string]interface{} {
	r.cacheMu.RLock()
	defer r.cacheMu.RUnlock()

	result := make(map[string]interface{})
	for key, entry := range r.cache {
		// Check if entry has expired
		if time.Since(entry.CreatedAt) <= entry.TTL {
			result[key] = entry.Value
		}
	}

	return result
}

// Exists checks if a key exists
func (r *KVRepository) Exists(key string) bool {
	_, exists := r.Get(key)
	return exists
}

// Count returns the number of entries in the repository
func (r *KVRepository) Count() int {
	r.cacheMu.RLock()
	defer r.cacheMu.RUnlock()

	count := 0
	for _, entry := range r.cache {
		// Only count non-expired entries
		if time.Since(entry.CreatedAt) <= entry.TTL {
			count++
		}
	}

	return count
}

// Clear removes all entries from the repository
func (r *KVRepository) Clear() error {
	// Get all keys for events
	keys := r.List()

	// Clear cache
	r.cacheMu.Lock()
	r.cache = make(map[string]*CacheEntry)
	r.cacheMu.Unlock()

	// Emit events for all cleared keys
	for _, key := range keys {
		r.emitEvent("deleted", key, nil, nil)
	}

	r.logger.Info("cleared repository with %d entries", len(keys))
	return nil
}

// IsWatching returns true if the repository is watching for changes
func (r *KVRepository) IsWatching() bool {
	r.watcherMu.RLock()
	defer r.watcherMu.RUnlock()
	return r.watcher != nil
}

// OnEvent registers an event handler
func (r *KVRepository) OnEvent(eventType string, handler func(string, interface{}, interface{})) {
	r.handlersMu.Lock()
	defer r.handlersMu.Unlock()

	r.eventHandlers[eventType] = append(r.eventHandlers[eventType], handler)
}

// RemoveEventHandler removes an event handler
func (r *KVRepository) RemoveEventHandler(eventType string, handler func(string, interface{}, interface{})) {
	r.handlersMu.Lock()
	defer r.handlersMu.Unlock()

	handlers := r.eventHandlers[eventType]
	for i, h := range handlers {
		if fmt.Sprintf("%p", h) == fmt.Sprintf("%p", handler) {
			r.eventHandlers[eventType] = append(handlers[:i], handlers[i+1:]...)
			break
		}
	}
}

// syncAll performs a full synchronization with the KV store
func (r *KVRepository) syncAll() error {
	r.logger.Debug("performing full sync with KV store")

	// List all keys in KV store
	keys, err := r.kvStore.ListKeys(r.ctx)
	if err != nil {
		return fmt.Errorf("failed to list keys: %w", err)
	}

	// Clear current cache
	r.cacheMu.Lock()
	r.cache = make(map[string]*CacheEntry)
	r.cacheMu.Unlock()

	// Sync each key
	for key := range keys.Keys() {
		if err := r.syncKey(key); err != nil {
			r.logger.Warn("failed to sync key %s: %v", key, err)
		}
	}

	r.logger.Debug("full sync completed with %d keys", len(keys.Keys()))
	return nil
}

// syncKey syncs a single key from KV store
func (r *KVRepository) syncKey(key string) error {
	entry, err := r.kvStore.Get(r.ctx, key)
	if err != nil {
		return fmt.Errorf("failed to get key %s: %w", key, err)
	}

	// Unmarshal value
	var value interface{}
	if err := json.Unmarshal(entry.Value(), &value); err != nil {
		return fmt.Errorf("failed to unmarshal value for key %s: %w", key, err)
	}

	// Update cache
	r.updateCache(key, value, entry.Revision(), r.config.CacheConfig.DefaultTTL)

	return nil
}

// updateCache updates the local cache
func (r *KVRepository) updateCache(key string, value interface{}, revision uint64, ttl time.Duration) {
	r.cacheMu.Lock()
	defer r.cacheMu.Unlock()

	// Check if this is an update or new entry
	oldEntry, exists := r.cache[key]
	var oldValue interface{}
	if exists {
		oldValue = oldEntry.Value
	}

	// Create new cache entry
	entry := &CacheEntry{
		Key:       key,
		Value:     value,
		TTL:       ttl,
		CreatedAt: time.Now(),
		UpdatedAt: time.Now(),
		Version:   revision,
	}

	r.cache[key] = entry

	// Emit event if this is an update
	if exists {
		r.emitEvent("updated", key, oldValue, value)
	} else {
		r.emitEvent("created", key, nil, value)
	}
}

// startKVWatcher starts watching for KV changes using NATS WatchAll
func (r *KVRepository) startKVWatcher() {
	watcher, err := r.kvStore.WatchAll(r.ctx)
	if err != nil {
		r.logger.Error("failed to start KV watcher: %v", err)
		return
	}

	r.watcherMu.Lock()
	r.watcher = watcher
	r.watcherMu.Unlock()

	r.logger.Info("started KV watcher")

	// Process updates from NATS
	for {
		select {
		case <-r.ctx.Done():
			return
		case update := <-watcher.Updates():
			if update == nil {
				continue
			}

			r.handleKVUpdate(update)
		}
	}
}

// handleKVUpdate processes a KV update
func (r *KVRepository) handleKVUpdate(update jetstream.KeyValueEntry) {
	key := update.Key()
	operation := update.Operation()

	r.logger.Debug("KV update: %s %s (rev: %d)", operation, key, update.Revision())

	switch operation {
	case jetstream.KeyValuePut:
		// Unmarshal new value
		var value interface{}
		if err := json.Unmarshal(update.Value(), &value); err != nil {
			r.logger.Error("failed to unmarshal value for key %s: %v", key, err)
			return
		}

		// Get old value for event
		oldValue, _, _ := r.GetWithRevision(key)

		// Update cache
		r.updateCache(key, value, update.Revision(), r.config.CacheConfig.DefaultTTL)

		// Emit event
		if oldValue != nil {
			r.emitEvent("updated", key, oldValue, value)
		} else {
			r.emitEvent("created", key, nil, value)
		}

	case jetstream.KeyValueDelete:
		// Get old value for event
		oldValue, _, _ := r.GetWithRevision(key)

		// Remove from cache
		r.cacheMu.Lock()
		delete(r.cache, key)
		r.cacheMu.Unlock()

		// Emit event
		r.emitEvent("deleted", key, oldValue, nil)

	case jetstream.KeyValuePurge:
		// Handle purge operation
		r.emitEvent("purged", key, nil, nil)
	}
}

// emitEvent emits an event to registered handlers
func (r *KVRepository) emitEvent(eventType, key string, oldValue, newValue interface{}) {
	r.handlersMu.RLock()
	handlers := r.eventHandlers[eventType]
	r.handlersMu.RUnlock()

	// Call handlers in goroutines to avoid blocking
	for _, handler := range handlers {
		go func(h func(string, interface{}, interface{})) {
			defer func() {
				if rec := recover(); rec != nil {
					r.logger.Error("event handler panicked: %v", rec)
				}
			}()
			h(key, oldValue, newValue)
		}(handler)
	}
}

// GetKVStore returns the underlying KV store
func (r *KVRepository) GetKVStore() jetstream.KeyValue {
	return r.kvStore
}

// GetStats returns repository statistics
func (r *KVRepository) GetStats() map[string]interface{} {
	r.cacheMu.RLock()
	defer r.cacheMu.RUnlock()

	stats := map[string]interface{}{
		"total_entries": len(r.cache),
		"is_watching":   r.IsWatching(),
		"cache_size":    r.Count(),
	}

	// Count by TTL
	ttlCounts := make(map[time.Duration]int)
	for _, entry := range r.cache {
		ttlCounts[entry.TTL]++
	}
	stats["ttl_distribution"] = ttlCounts

	return stats
}
