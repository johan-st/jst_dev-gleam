package core

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// RealtimeConfig holds configuration for real-time features
type RealtimeConfig struct {
	// Subject patterns for different types of updates
	SubjectPatterns SubjectPatterns

	// Cache configuration
	CacheConfig CacheConfig

	// Stream configuration
	StreamConfig StreamConfig

	// KV store configuration
	KVConfig KVConfig
}

// SubjectPatterns defines the subject naming conventions
type SubjectPatterns struct {
	// Real-time updates: {service}.{resource}.{action}
	// Examples: articles.created, articles.updated, users.deleted
	Updates string `json:"updates"`

	// Cache invalidation: cache.{service}.{resource}
	// Examples: cache.articles.all, cache.users.123
	CacheInvalidation string `json:"cache_invalidation"`

	// Service discovery: service.{service}.{endpoint}
	// Examples: service.articles.subjects, service.users.endpoints
	ServiceDiscovery string `json:"service_discovery"`

	// Client subscriptions: client.{client_id}.{subscription_id}
	// Examples: client.abc123.sub1, client.abc123.articles
	ClientSubscriptions string `json:"client_subscriptions"`
}

// CacheConfig holds cache-related configuration
type CacheConfig struct {
	// Default TTL for cached data
	DefaultTTL time.Duration `json:"default_ttl"`

	// Maximum cache size per service
	MaxSize int `json:"max_size"`

	// Cache invalidation patterns
	InvalidationPatterns []string `json:"invalidation_patterns"`
}

// StreamConfig holds JetStream configuration
type StreamConfig struct {
	// Stream name for real-time updates
	UpdatesStream string `json:"updates_stream"`

	// Stream name for cache events
	CacheStream string `json:"cache_stream"`

	// Retention policy
	Retention jetstream.RetentionPolicy `json:"retention"`

	// Max age for messages
	MaxAge time.Duration `json:"max_age"`
}

// KVConfig holds Key-Value store configuration
type KVConfig struct {
	// KV bucket names for different data types
	Buckets map[string]string `json:"buckets"`

	// Default bucket configuration
	DefaultBucketConfig jetstream.KeyValueConfig `json:"default_bucket_config"`
}

// RealtimeManager manages real-time features across all services
type RealtimeManager struct {
	nc     *nats.Conn
	js     jetstream.JetStream
	logger *jst_log.Logger
	config RealtimeConfig

	// Cache management
	caches  map[string]*ServiceCache
	cacheMu sync.RWMutex

	// Subject management
	subjects   map[string]*ServiceSubjects
	subjectsMu sync.RWMutex

	// Client subscriptions
	clientSubs   map[string]*ClientSubscription
	clientSubsMu sync.RWMutex

	// WebSocket clients
	clients   map[string]*WebSocketClient
	clientsMu sync.RWMutex

	// Streams
	streams map[string]jetstream.Stream

	// KV stores
	kvStores   map[string]jetstream.KeyValue
	kvStoresMu sync.RWMutex
}

// ServiceSubjects holds all subjects for a service
type ServiceSubjects struct {
	ServiceName string            `json:"service_name"`
	Subjects    map[string]string `json:"subjects"`
	Patterns    []string          `json:"patterns"`
	UpdatedAt   time.Time         `json:"updated_at"`
}

// ClientSubscription represents a client's subscription to real-time updates
type ClientSubscription struct {
	ClientID       string             `json:"client_id"`
	SubscriptionID string             `json:"subscription_id"`
	Subjects       []string           `json:"subjects"`
	Filters        map[string]string  `json:"filters"`
	CreatedAt      time.Time          `json:"created_at"`
	LastSeen       time.Time          `json:"last_seen"`
	NatsSub        *nats.Subscription `json:"-"`
}

// CacheEntry represents a cached item
type CacheEntry struct {
	Key       string        `json:"key"`
	Value     interface{}   `json:"value"`
	TTL       time.Duration `json:"ttl"`
	CreatedAt time.Time     `json:"created_at"`
	UpdatedAt time.Time     `json:"updated_at"`
	Version   uint64        `json:"version"`
}

// ServiceCache manages cache for a specific service
type ServiceCache struct {
	ServiceName string                 `json:"service_name"`
	Entries     map[string]*CacheEntry `json:"entries"`
	Size        int                    `json:"size"`
	MaxSize     int                    `json:"max_size"`
}

// UpdateMessage represents a real-time update message
type UpdateMessage struct {
	ID        string                 `json:"id"`
	Service   string                 `json:"service"`
	Resource  string                 `json:"resource"`
	Action    string                 `json:"action"`
	Data      interface{}            `json:"data"`
	Metadata  map[string]interface{} `json:"metadata"`
	Timestamp time.Time              `json:"timestamp"`
	Version   uint64                 `json:"version"`
	ClientID  string                 `json:"client_id,omitempty"`
}

// NewRealtimeManager creates a new real-time manager
func NewRealtimeManager(nc *nats.Conn, logger *jst_log.Logger, config RealtimeConfig) (*RealtimeManager, error) {
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, fmt.Errorf("failed to create JetStream context: %w", err)
	}

	rm := &RealtimeManager{
		nc:         nc,
		js:         js,
		logger:     logger,
		config:     config,
		caches:     make(map[string]*ServiceCache),
		subjects:   make(map[string]*ServiceSubjects),
		clientSubs: make(map[string]*ClientSubscription),
		clients:    make(map[string]*WebSocketClient),
		streams:    make(map[string]jetstream.Stream),
		kvStores:   make(map[string]jetstream.KeyValue),
	}

	// Initialize default configuration
	if err := rm.initializeDefaults(); err != nil {
		return nil, fmt.Errorf("failed to initialize defaults: %w", err)
	}

	// Setup streams
	if err := rm.setupStreams(); err != nil {
		return nil, fmt.Errorf("failed to setup streams: %w", err)
	}

	// Setup KV stores
	if err := rm.setupKVStores(); err != nil {
		return nil, fmt.Errorf("failed to setup KV stores: %w", err)
	}

	// Start cache invalidation listener
	go rm.startCacheInvalidationListener()

	// Start client subscription manager
	go rm.startClientSubscriptionManager()

	return rm, nil
}

// initializeDefaults sets up default configuration
func (rm *RealtimeManager) initializeDefaults() error {
	if rm.config.SubjectPatterns.Updates == "" {
		rm.config.SubjectPatterns.Updates = "updates.{service}.{resource}.{action}"
	}
	if rm.config.SubjectPatterns.CacheInvalidation == "" {
		rm.config.SubjectPatterns.CacheInvalidation = "cache.{service}.{resource}"
	}
	if rm.config.SubjectPatterns.ServiceDiscovery == "" {
		rm.config.SubjectPatterns.ServiceDiscovery = "service.{service}.{endpoint}"
	}
	if rm.config.SubjectPatterns.ClientSubscriptions == "" {
		rm.config.SubjectPatterns.ClientSubscriptions = "client.{client_id}.{subscription_id}"
	}

	if rm.config.CacheConfig.DefaultTTL == 0 {
		rm.config.CacheConfig.DefaultTTL = 5 * time.Minute
	}
	if rm.config.CacheConfig.MaxSize == 0 {
		rm.config.CacheConfig.MaxSize = 1000
	}

	if rm.config.StreamConfig.UpdatesStream == "" {
		rm.config.StreamConfig.UpdatesStream = "updates"
	}
	if rm.config.StreamConfig.CacheStream == "" {
		rm.config.StreamConfig.CacheStream = "cache_events"
	}
	if rm.config.StreamConfig.Retention == 0 {
		rm.config.StreamConfig.Retention = jetstream.LimitsPolicy
	}
	if rm.config.StreamConfig.MaxAge == 0 {
		rm.config.StreamConfig.MaxAge = 24 * time.Hour
	}

	return nil
}

// setupStreams creates the necessary JetStream streams
func (rm *RealtimeManager) setupStreams() error {
	// Updates stream
	updatesStream, err := rm.js.CreateOrUpdateStream(context.Background(), jetstream.StreamConfig{
		Name:        rm.config.StreamConfig.UpdatesStream,
		Description: "Real-time updates stream",
		Subjects:    []string{"updates.*"},
		Retention:   rm.config.StreamConfig.Retention,
		MaxAge:      rm.config.StreamConfig.MaxAge,
		Storage:     jetstream.FileStorage,
	})
	if err != nil {
		return fmt.Errorf("failed to create updates stream: %w", err)
	}
	rm.streams[rm.config.StreamConfig.UpdatesStream] = updatesStream

	// Cache events stream
	cacheStream, err := rm.js.CreateOrUpdateStream(context.Background(), jetstream.StreamConfig{
		Name:        rm.config.StreamConfig.CacheStream,
		Description: "Cache invalidation events stream",
		Subjects:    []string{"cache.*"},
		Retention:   rm.config.StreamConfig.Retention,
		MaxAge:      rm.config.StreamConfig.MaxAge,
		Storage:     jetstream.FileStorage,
	})
	if err != nil {
		return fmt.Errorf("failed to create cache stream: %w", err)
	}
	rm.streams[rm.config.StreamConfig.CacheStream] = cacheStream

	return nil
}

// setupKVStores creates the necessary KV stores
func (rm *RealtimeManager) setupKVStores() error {
	// Default KV stores
	defaultStores := map[string]string{
		"articles": "articles_kv",
		"users":    "users_kv",
		"cache":    "cache_kv",
		"config":   "config_kv",
	}

	for name, bucket := range defaultStores {
		kv, err := rm.js.CreateOrUpdateKeyValue(context.Background(), jetstream.KeyValueConfig{
			Bucket:       bucket,
			Description:  fmt.Sprintf("KV store for %s", name),
			Storage:      jetstream.FileStorage,
			MaxValueSize: 1024 * 1024,       // 1MB
			MaxBytes:     1024 * 1024 * 100, // 100MB
			History:      64,
			Compression:  true,
		})
		if err != nil {
			return fmt.Errorf("failed to create KV store %s: %w", name, err)
		}
		rm.kvStores[name] = kv
	}

	return nil
}

// RegisterService registers a service and its subjects
func (rm *RealtimeManager) RegisterService(serviceName string, subjects map[string]string, patterns []string) error {
	rm.subjectsMu.Lock()
	defer rm.subjectsMu.Unlock()

	rm.subjects[serviceName] = &ServiceSubjects{
		ServiceName: serviceName,
		Subjects:    subjects,
		Patterns:    patterns,
		UpdatedAt:   time.Now(),
	}

	// Create service cache
	rm.cacheMu.Lock()
	rm.caches[serviceName] = &ServiceCache{
		ServiceName: serviceName,
		Entries:     make(map[string]*CacheEntry),
		MaxSize:     rm.config.CacheConfig.MaxSize,
	}
	rm.cacheMu.Unlock()

	// Publish service discovery update
	discoverySubject := rm.formatSubject(rm.config.SubjectPatterns.ServiceDiscovery, map[string]string{
		"service":  serviceName,
		"endpoint": "subjects",
	})

	discoveryData := map[string]interface{}{
		"service":    serviceName,
		"subjects":   subjects,
		"patterns":   patterns,
		"updated_at": time.Now(),
	}

	if err := rm.publishUpdate(discoverySubject, discoveryData); err != nil {
		rm.logger.Error("failed to publish service discovery update: %v", err)
	}

	rm.logger.Info("registered service %s with %d subjects", serviceName, len(subjects))
	return nil
}

// GetServiceSubjects returns all subjects for a service
func (rm *RealtimeManager) GetServiceSubjects(serviceName string) (*ServiceSubjects, error) {
	rm.subjectsMu.RLock()
	defer rm.subjectsMu.RUnlock()

	subjects, exists := rm.subjects[serviceName]
	if !exists {
		return nil, fmt.Errorf("service %s not found", serviceName)
	}

	return subjects, nil
}

// PublishUpdate publishes a real-time update
func (rm *RealtimeManager) PublishUpdate(service, resource, action string, data interface{}, metadata map[string]interface{}) error {
	subject := rm.formatSubject(rm.config.SubjectPatterns.Updates, map[string]string{
		"service":  service,
		"resource": resource,
		"action":   action,
	})

	update := UpdateMessage{
		ID:        fmt.Sprintf("%s-%s-%s-%d", service, resource, action, time.Now().UnixNano()),
		Service:   service,
		Resource:  resource,
		Action:    action,
		Data:      data,
		Metadata:  metadata,
		Timestamp: time.Now(),
		Version:   uint64(time.Now().UnixNano()),
	}

	return rm.publishUpdate(subject, update)
}

// PublishCacheInvalidation publishes a cache invalidation event
func (rm *RealtimeManager) PublishCacheInvalidation(service, resource string, keys []string) error {
	subject := rm.formatSubject(rm.config.SubjectPatterns.CacheInvalidation, map[string]string{
		"service":  service,
		"resource": resource,
	})

	invalidation := map[string]interface{}{
		"service":   service,
		"resource":  resource,
		"keys":      keys,
		"timestamp": time.Now(),
	}

	return rm.publishUpdate(subject, invalidation)
}

// SetCache sets a value in the service cache
func (rm *RealtimeManager) SetCache(serviceName, key string, value interface{}, ttl time.Duration) error {
	rm.cacheMu.Lock()
	defer rm.cacheMu.Unlock()

	cache, exists := rm.caches[serviceName]
	if !exists {
		return fmt.Errorf("service cache %s not found", serviceName)
	}

	if ttl == 0 {
		ttl = rm.config.CacheConfig.DefaultTTL
	}

	entry := &CacheEntry{
		Key:       key,
		Value:     value,
		TTL:       ttl,
		CreatedAt: time.Now(),
		UpdatedAt: time.Now(),
		Version:   uint64(time.Now().UnixNano()),
	}

	cache.Entries[key] = entry
	cache.Size++

	// Evict old entries if cache is full
	if cache.Size > cache.MaxSize {
		rm.evictOldestEntries(cache)
	}

	rm.logger.Debug("cached %s:%s for service %s", serviceName, key, serviceName)
	return nil
}

// GetCache retrieves a value from the service cache
func (rm *RealtimeManager) GetCache(serviceName, key string) (interface{}, bool) {
	rm.cacheMu.RLock()
	defer rm.cacheMu.RUnlock()

	cache, exists := rm.caches[serviceName]
	if !exists {
		return nil, false
	}

	entry, exists := cache.Entries[key]
	if !exists {
		return nil, false
	}

	// Check if entry has expired
	if time.Since(entry.CreatedAt) > entry.TTL {
		delete(cache.Entries, key)
		cache.Size--
		return nil, false
	}

	return entry.Value, true
}

// InvalidateCache invalidates cache entries for a service
func (rm *RealtimeManager) InvalidateCache(serviceName string, keys []string) error {
	rm.cacheMu.Lock()
	defer rm.cacheMu.Unlock()

	cache, exists := rm.caches[serviceName]
	if !exists {
		return fmt.Errorf("service cache %s not found", serviceName)
	}

	for _, key := range keys {
		if _, exists := cache.Entries[key]; exists {
			delete(cache.Entries, key)
			cache.Size--
		}
	}

	// Publish cache invalidation event
	go rm.PublishCacheInvalidation(serviceName, "all", keys)

	rm.logger.Debug("invalidated %d cache entries for service %s", len(keys), serviceName)
	return nil
}

// CreateClientSubscription creates a subscription for a client
func (rm *RealtimeManager) CreateClientSubscription(clientID, subscriptionID string, subjects []string, filters map[string]string) (*ClientSubscription, error) {
	rm.clientSubsMu.Lock()
	defer rm.clientSubsMu.Unlock()

	sub := &ClientSubscription{
		ClientID:       clientID,
		SubscriptionID: subscriptionID,
		Subjects:       subjects,
		Filters:        filters,
		CreatedAt:      time.Now(),
		LastSeen:       time.Now(),
	}

	rm.clientSubs[subscriptionID] = sub

	rm.logger.Info("created client subscription %s for client %s", subscriptionID, clientID)
	return sub, nil
}

// GetClientSubscription retrieves a client subscription
func (rm *RealtimeManager) GetClientSubscription(subscriptionID string) (*ClientSubscription, bool) {
	rm.clientSubsMu.RLock()
	defer rm.clientSubsMu.RUnlock()

	sub, exists := rm.clientSubs[subscriptionID]
	return sub, exists
}

// UpdateClientSubscriptionLastSeen updates the last seen time for a client subscription
func (rm *RealtimeManager) UpdateClientSubscriptionLastSeen(subscriptionID string) {
	rm.clientSubsMu.Lock()
	defer rm.clientSubsMu.Unlock()

	if sub, exists := rm.clientSubs[subscriptionID]; exists {
		sub.LastSeen = time.Now()
	}
}

// startCacheInvalidationListener listens for cache invalidation events
func (rm *RealtimeManager) startCacheInvalidationListener() {
	subject := "cache.*"

	_, err := rm.nc.Subscribe(subject, func(msg *nats.Msg) {
		var invalidation map[string]interface{}
		if err := json.Unmarshal(msg.Data, &invalidation); err != nil {
			rm.logger.Error("failed to unmarshal cache invalidation: %v", err)
			return
		}

		service, ok := invalidation["service"].(string)
		if !ok {
			rm.logger.Error("invalid service in cache invalidation")
			return
		}

		keys, ok := invalidation["keys"].([]interface{})
		if !ok {
			rm.logger.Error("invalid keys in cache invalidation")
			return
		}

		var keyStrings []string
		for _, key := range keys {
			if keyStr, ok := key.(string); ok {
				keyStrings = append(keyStrings, keyStr)
			}
		}

		if err := rm.InvalidateCache(service, keyStrings); err != nil {
			rm.logger.Error("failed to invalidate cache: %v", err)
		}
	})

	if err != nil {
		rm.logger.Error("failed to subscribe to cache invalidation: %v", err)
		return
	}

	rm.logger.Info("started cache invalidation listener on %s", subject)

	// Keep the subscription alive
	select {}
}

// startClientSubscriptionManager manages client subscriptions
func (rm *RealtimeManager) startClientSubscriptionManager() {
	ticker := time.NewTicker(1 * time.Minute)
	defer ticker.Stop()

	for range ticker.C {
		rm.cleanupStaleClientSubscriptions()
	}
}

// cleanupStaleClientSubscriptions removes stale client subscriptions
func (rm *RealtimeManager) cleanupStaleClientSubscriptions() {
	rm.clientSubsMu.Lock()
	defer rm.clientSubsMu.Unlock()

	cutoff := time.Now().Add(-10 * time.Minute) // Remove subscriptions older than 10 minutes

	for id, sub := range rm.clientSubs {
		if sub.LastSeen.Before(cutoff) {
			delete(rm.clientSubs, id)
			rm.logger.Debug("removed stale client subscription %s", id)
		}
	}
}

// evictOldestEntries evicts the oldest cache entries
func (rm *RealtimeManager) evictOldestEntries(cache *ServiceCache) {
	var oldestKey string
	var oldestTime time.Time

	for key, entry := range cache.Entries {
		if oldestKey == "" || entry.CreatedAt.Before(oldestTime) {
			oldestKey = key
			oldestTime = entry.CreatedAt
		}
	}

	if oldestKey != "" {
		delete(cache.Entries, oldestKey)
		cache.Size--
	}
}

// formatSubject formats a subject pattern with variables
func (rm *RealtimeManager) formatSubject(pattern string, vars map[string]string) string {
	subject := pattern
	for _, value := range vars {
		subject = fmt.Sprintf(subject, value)
	}
	return subject
}

// publishUpdate publishes an update message
func (rm *RealtimeManager) publishUpdate(subject string, data interface{}) error {
	jsonData, err := json.Marshal(data)
	if err != nil {
		return fmt.Errorf("failed to marshal update data: %w", err)
	}

	if err := rm.nc.Publish(subject, jsonData); err != nil {
		return fmt.Errorf("failed to publish update: %w", err)
	}

	rm.logger.Debug("published update to %s", subject)
	return nil
}

// GetKVStore returns a KV store by name
func (rm *RealtimeManager) GetKVStore(name string) (jetstream.KeyValue, error) {
	rm.kvStoresMu.RLock()
	defer rm.kvStoresMu.RUnlock()

	kv, exists := rm.kvStores[name]
	if !exists {
		return nil, fmt.Errorf("KV store %s not found", name)
	}

	return kv, nil
}

// CreateKVStore creates a new KV store
func (rm *RealtimeManager) CreateKVStore(name string, config jetstream.KeyValueConfig) (jetstream.KeyValue, error) {
	rm.kvStoresMu.Lock()
	defer rm.kvStoresMu.Unlock()
	
	kv, err := rm.js.CreateOrUpdateKeyValue(context.Background(), config)
	if err != nil {
		return nil, fmt.Errorf("failed to create KV store %s: %w", name, err)
	}
	
	rm.kvStores[name] = kv
	rm.logger.Info("created KV store %s", name)
	return kv, nil
}

// GetNatsConn returns the NATS connection
func (rm *RealtimeManager) GetNatsConn() *nats.Conn {
	return rm.nc
}
