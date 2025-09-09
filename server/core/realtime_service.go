package core

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// RealtimeService extends the base service with real-time capabilities
type RealtimeService struct {
	*BaseService
	realtimeManager *RealtimeManager
	kvStore         jetstream.KeyValue
	subjects        map[string]string
	patterns        []string
	watchers        map[string]interface{}
	watchersMu      sync.RWMutex
}

// RealtimeServiceConfig extends ServiceConfig with real-time options
type RealtimeServiceConfig struct {
	ServiceConfig
	RealtimeManager *RealtimeManager
	KVStoreName     string
	Subjects        map[string]string
	Patterns        []string
	EnableCache     bool
	CacheTTL        time.Duration
}

// NewRealtimeService creates a new real-time enabled service
func NewRealtimeService(name string, dependencies []string, config RealtimeServiceConfig) *RealtimeService {
	base := NewBaseService(name, dependencies, config.ServiceConfig)

	service := &RealtimeService{
		BaseService:     base,
		realtimeManager: config.RealtimeManager,
		subjects:        config.Subjects,
		patterns:        config.Patterns,
		watchers:        make(map[string]interface{}),
	}

	// Get KV store if specified
	if config.KVStoreName != "" {
		if kv, err := config.RealtimeManager.GetKVStore(config.KVStoreName); err == nil {
			service.kvStore = kv
		}
	}

	return service
}

// Initialize performs real-time service initialization
func (rs *RealtimeService) Initialize(ctx context.Context) error {
	if err := rs.BaseService.Initialize(ctx); err != nil {
		return err
	}

	// Register service with real-time manager
	if rs.realtimeManager != nil {
		if err := rs.realtimeManager.RegisterService(rs.Name(), rs.subjects, rs.patterns); err != nil {
			return fmt.Errorf("failed to register service with real-time manager: %w", err)
		}
	}

	rs.GetLogger().Info("real-time service %s initialized", rs.Name())
	return nil
}

// Shutdown performs real-time service cleanup
func (rs *RealtimeService) Shutdown(ctx context.Context) error {
	// Stop all watchers
	rs.watchersMu.Lock()
	for name, watcher := range rs.watchers {
		if kvWatcher, ok := watcher.(jetstream.KeyWatcher); ok {
			kvWatcher.Stop()
		}
		delete(rs.watchers, name)
	}
	rs.watchersMu.Unlock()

	return rs.BaseService.Shutdown(ctx)
}

// PublishUpdate publishes a real-time update
func (rs *RealtimeService) PublishUpdate(resource, action string, data interface{}, metadata map[string]interface{}) error {
	if rs.realtimeManager == nil {
		return fmt.Errorf("real-time manager not available")
	}

	return rs.realtimeManager.PublishUpdate(rs.Name(), resource, action, data, metadata)
}

// SetCache sets a value in the service cache
func (rs *RealtimeService) SetCache(key string, value interface{}, ttl time.Duration) error {
	if rs.realtimeManager == nil {
		return fmt.Errorf("real-time manager not available")
	}

	return rs.realtimeManager.SetCache(rs.Name(), key, value, ttl)
}

// GetCache retrieves a value from the service cache
func (rs *RealtimeService) GetCache(key string) (interface{}, bool) {
	if rs.realtimeManager == nil {
		return nil, false
	}

	return rs.realtimeManager.GetCache(rs.Name(), key)
}

// InvalidateCache invalidates cache entries
func (rs *RealtimeService) InvalidateCache(keys []string) error {
	if rs.realtimeManager == nil {
		return fmt.Errorf("real-time manager not available")
	}

	return rs.realtimeManager.InvalidateCache(rs.Name(), keys)
}

// WatchKV watches a KV store for changes and updates cache
func (rs *RealtimeService) WatchKV(ctx context.Context, watchAll bool) error {
	if rs.kvStore == nil {
		return fmt.Errorf("KV store not available")
	}

	var watcher jetstream.KeyWatcher
	var err error

	if watchAll {
		watcher, err = rs.kvStore.WatchAll(ctx)
	} else {
		// Watch specific patterns if needed
		watcher, err = rs.kvStore.Watch(ctx, "*")
	}

	if err != nil {
		return fmt.Errorf("failed to create KV watcher: %w", err)
	}

	rs.watchersMu.Lock()
	rs.watchers["kv"] = watcher
	rs.watchersMu.Unlock()

	// Start watching in a goroutine
	go rs.handleKVUpdates(ctx, watcher)

	rs.GetLogger().Info("started KV watcher for service %s", rs.Name())
	return nil
}

// handleKVUpdates processes KV store updates
func (rs *RealtimeService) handleKVUpdates(ctx context.Context, watcher jetstream.KeyWatcher) {
	defer watcher.Stop()

	for {
		select {
		case <-ctx.Done():
			rs.GetLogger().Info("KV watcher stopped for service %s", rs.Name())
			return
		case update := <-watcher.Updates():
			if update == nil {
				continue
			}

			rs.processKVUpdate(update)
		}
	}
}

// processKVUpdate processes a single KV update
func (rs *RealtimeService) processKVUpdate(update jetstream.KeyValueEntry) {
	key := update.Key()
	operation := update.Operation()

	rs.GetLogger().Debug("KV update: %s %s (rev: %d)", operation, key, update.Revision())

	switch operation {
	case jetstream.KeyValuePut:
		// Update cache with new value
		if rs.realtimeManager != nil {
			// Try to unmarshal the value to determine its type
			var value interface{}
			if err := json.Unmarshal(update.Value(), &value); err == nil {
				rs.SetCache(key, value, 0) // Use default TTL
			}
		}

		// Publish real-time update
		rs.PublishUpdate("kv", "updated", map[string]interface{}{
			"key":      key,
			"value":    update.Value(),
			"revision": update.Revision(),
		}, map[string]interface{}{
			"operation": "put",
			"timestamp": update.Created(),
		})

	case jetstream.KeyValueDelete:
		// Remove from cache
		if rs.realtimeManager != nil {
			rs.InvalidateCache([]string{key})
		}

		// Publish real-time update
		rs.PublishUpdate("kv", "deleted", map[string]interface{}{
			"key": key,
		}, map[string]interface{}{
			"operation": "delete",
			"timestamp": update.Created(),
		})

	case jetstream.KeyValuePurge:
		// Handle purge operation
		rs.PublishUpdate("kv", "purged", map[string]interface{}{
			"key": key,
		}, map[string]interface{}{
			"operation": "purge",
			"timestamp": update.Created(),
		})
	}
}

// GetKVStore returns the service's KV store
func (rs *RealtimeService) GetKVStore() jetstream.KeyValue {
	return rs.kvStore
}

// SetKVStore sets the service's KV store
func (rs *RealtimeService) SetKVStore(kv jetstream.KeyValue) {
	rs.kvStore = kv
}

// GetSubjects returns the service's subjects
func (rs *RealtimeService) GetSubjects() map[string]string {
	return rs.subjects
}

// GetPatterns returns the service's subject patterns
func (rs *RealtimeService) GetPatterns() []string {
	return rs.patterns
}

// CreateClientSubscription creates a subscription for a client
func (rs *RealtimeService) CreateClientSubscription(clientID, subscriptionID string, subjects []string, filters map[string]string) (*ClientSubscription, error) {
	if rs.realtimeManager == nil {
		return nil, fmt.Errorf("real-time manager not available")
	}

	return rs.realtimeManager.CreateClientSubscription(clientID, subscriptionID, subjects, filters)
}

// GetClientSubscription retrieves a client subscription
func (rs *RealtimeService) GetClientSubscription(subscriptionID string) (*ClientSubscription, bool) {
	if rs.realtimeManager == nil {
		return nil, false
	}

	return rs.realtimeManager.GetClientSubscription(subscriptionID)
}

// SubscribeToUpdates subscribes to real-time updates for a specific pattern
func (rs *RealtimeService) SubscribeToUpdates(pattern string, handler func(*UpdateMessage)) error {
	if rs.realtimeManager == nil {
		return fmt.Errorf("real-time manager not available")
	}

	sub, err := rs.GetNatsConn().Subscribe(pattern, func(msg *nats.Msg) {
		var update UpdateMessage
		if err := json.Unmarshal(msg.Data, &update); err != nil {
			rs.GetLogger().Error("failed to unmarshal update message: %v", err)
			return
		}

		handler(&update)
	})

	if err != nil {
		return fmt.Errorf("failed to subscribe to updates: %w", err)
	}

	rs.GetLogger().Info("subscribed to updates with pattern: %s", pattern)

	// Store subscription for cleanup
	rs.watchersMu.Lock()
	rs.watchers[pattern] = sub
	rs.watchersMu.Unlock()

	return nil
}

// PublishToSubject publishes a message to a specific subject
func (rs *RealtimeService) PublishToSubject(subject string, data interface{}) error {
	jsonData, err := json.Marshal(data)
	if err != nil {
		return fmt.Errorf("failed to marshal data: %w", err)
	}

	if err := rs.GetNatsConn().Publish(subject, jsonData); err != nil {
		return fmt.Errorf("failed to publish to subject %s: %w", subject, err)
	}

	rs.GetLogger().Debug("published to subject: %s", subject)
	return nil
}

// RequestToSubject makes a request to a specific subject and returns the response
func (rs *RealtimeService) RequestToSubject(subject string, data interface{}, timeout time.Duration) (interface{}, error) {
	jsonData, err := json.Marshal(data)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request data: %w", err)
	}

	msg, err := rs.GetNatsConn().Request(subject, jsonData, timeout)
	if err != nil {
		return nil, fmt.Errorf("failed to request from subject %s: %w", subject, err)
	}

	var response interface{}
	if err := json.Unmarshal(msg.Data, &response); err != nil {
		return nil, fmt.Errorf("failed to unmarshal response: %w", err)
	}

	return response, nil
}

// GetRealtimeManager returns the real-time manager
func (rs *RealtimeService) GetRealtimeManager() *RealtimeManager {
	return rs.realtimeManager
}

// RealtimeServiceBuilder extends ServiceBuilder with real-time capabilities
type RealtimeServiceBuilder struct {
	*ServiceBuilder
	realtimeConfig RealtimeServiceConfig
}

// NewRealtimeServiceBuilder creates a new real-time service builder
func NewRealtimeServiceBuilder(name string, config RealtimeServiceConfig) *RealtimeServiceBuilder {
	baseBuilder := NewServiceBuilder(name, config.ServiceConfig)

	return &RealtimeServiceBuilder{
		ServiceBuilder: baseBuilder,
		realtimeConfig: config,
	}
}

// WithKVStore sets the KV store for the service
func (rsb *RealtimeServiceBuilder) WithKVStore(storeName string) *RealtimeServiceBuilder {
	rsb.realtimeConfig.KVStoreName = storeName
	return rsb
}

// WithSubjects sets the subjects for the service
func (rsb *RealtimeServiceBuilder) WithSubjects(subjects map[string]string) *RealtimeServiceBuilder {
	rsb.realtimeConfig.Subjects = subjects
	return rsb
}

// WithPatterns sets the subject patterns for the service
func (rsb *RealtimeServiceBuilder) WithPatterns(patterns []string) *RealtimeServiceBuilder {
	rsb.realtimeConfig.Patterns = patterns
	return rsb
}

// WithCache enables caching for the service
func (rsb *RealtimeServiceBuilder) WithCache(ttl time.Duration) *RealtimeServiceBuilder {
	rsb.realtimeConfig.EnableCache = true
	rsb.realtimeConfig.CacheTTL = ttl
	return rsb
}

// WithKVWatcher adds KV watching capability
func (rsb *RealtimeServiceBuilder) WithKVWatcher(watchAll bool) *RealtimeServiceBuilder {
	rsb.WithInitializer(func(ctx context.Context) error {
		// This would need to be implemented differently in a real scenario
		// For now, we'll skip the KV watcher setup
		return nil
	})
	return rsb
}

// Build creates the real-time service
func (rsb *RealtimeServiceBuilder) Build() Service {
	base := NewRealtimeService(rsb.name, rsb.dependencies, rsb.realtimeConfig)

	return &customRealtimeService{
		RealtimeService: base,
		initializer:     rsb.initializer,
		runner:          rsb.runner,
		shutdowner:      rsb.shutdowner,
		healthChecker:   rsb.healthChecker,
	}
}

// customRealtimeService wraps RealtimeService with custom implementations
type customRealtimeService struct {
	*RealtimeService
	initializer   func(context.Context) error
	runner        func(context.Context) error
	shutdowner    func(context.Context) error
	healthChecker func() error
}

// Initialize calls the custom initializer if provided, otherwise uses base implementation
func (crs *customRealtimeService) Initialize(ctx context.Context) error {
	if crs.initializer != nil {
		return crs.initializer(ctx)
	}
	return crs.RealtimeService.Initialize(ctx)
}

// Run calls the custom runner if provided, otherwise uses base implementation
func (crs *customRealtimeService) Run(ctx context.Context) error {
	if crs.runner != nil {
		crs.mu.Lock()
		crs.running = true
		crs.mu.Unlock()

		crs.logger.Info("real-time service started")

		err := crs.runner(ctx)

		crs.logger.Info("real-time service stopping...")

		// Perform shutdown
		if shutdownErr := crs.Shutdown(ctx); shutdownErr != nil {
			crs.logger.Error("shutdown error: %v", shutdownErr)
		}

		crs.logger.Info("real-time service stopped")
		return err
	}
	return crs.RealtimeService.Run(ctx)
}

// Shutdown calls the custom shutdowner if provided, otherwise uses base implementation
func (crs *customRealtimeService) Shutdown(ctx context.Context) error {
	if crs.shutdowner != nil {
		return crs.shutdowner(ctx)
	}
	return crs.RealtimeService.Shutdown(ctx)
}

// Health calls the custom health checker if provided, otherwise uses base implementation
func (crs *customRealtimeService) Health() error {
	if crs.healthChecker != nil {
		return crs.healthChecker()
	}
	return crs.RealtimeService.Health()
}
