package core

import (
	"context"
	"fmt"
	"sync"
	"time"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go/jetstream"
)

// RepositoryFactory creates and manages KV repositories
type RepositoryFactory struct {
	realtimeManager *RealtimeManager
	repositories    map[string]*KVRepository
	repositoriesMu  sync.RWMutex
}

// NewRepositoryFactory creates a new repository factory
func NewRepositoryFactory(realtimeManager *RealtimeManager) *RepositoryFactory {
	return &RepositoryFactory{
		realtimeManager: realtimeManager,
		repositories:    make(map[string]*KVRepository),
	}
}

// CreateRepository creates a new KV repository for a service
func (rf *RepositoryFactory) CreateRepository(serviceName string, config RepositoryConfig) (*KVRepository, error) {
	rf.repositoriesMu.Lock()
	defer rf.repositoriesMu.Unlock()

	// Check if repository already exists
	if repo, exists := rf.repositories[serviceName]; exists {
		return repo, nil
	}

	// Get or create KV store
	kvStore, err := rf.getOrCreateKVStore(serviceName, config.KVStoreName)
	if err != nil {
		return nil, fmt.Errorf("failed to get KV store: %w", err)
	}

	// Set default logger if not provided
	if config.Logger == nil {
		config.Logger = rf.realtimeManager.logger.WithBreadcrumb(serviceName)
	}

	// Create repository
	repo := NewKVRepository(kvStore, config)

	// Start the repository
	if err := repo.Start(); err != nil {
		return nil, fmt.Errorf("failed to start repository: %w", err)
	}

	// Store repository
	rf.repositories[serviceName] = repo

	rf.realtimeManager.logger.Info("created repository for service %s", serviceName)
	return repo, nil
}

// GetRepository retrieves an existing repository
func (rf *RepositoryFactory) GetRepository(serviceName string) (*KVRepository, bool) {
	rf.repositoriesMu.RLock()
	defer rf.repositoriesMu.RUnlock()

	repo, exists := rf.repositories[serviceName]
	return repo, exists
}

// RemoveRepository removes a repository
func (rf *RepositoryFactory) RemoveRepository(serviceName string) error {
	rf.repositoriesMu.Lock()
	defer rf.repositoriesMu.Unlock()

	repo, exists := rf.repositories[serviceName]
	if !exists {
		return fmt.Errorf("repository for service %s not found", serviceName)
	}

	// Stop the repository
	if err := repo.Stop(); err != nil {
		rf.realtimeManager.logger.Error("failed to stop repository %s: %v", serviceName, err)
	}

	// Remove from map
	delete(rf.repositories, serviceName)

	rf.realtimeManager.logger.Info("removed repository for service %s", serviceName)
	return nil
}

// ListRepositories returns all repository names
func (rf *RepositoryFactory) ListRepositories() []string {
	rf.repositoriesMu.RLock()
	defer rf.repositoriesMu.RUnlock()

	names := make([]string, 0, len(rf.repositories))
	for name := range rf.repositories {
		names = append(names, name)
	}

	return names
}

// GetStats returns statistics for all repositories
func (rf *RepositoryFactory) GetStats() map[string]interface{} {
	rf.repositoriesMu.RLock()
	defer rf.repositoriesMu.RUnlock()

	stats := make(map[string]interface{})
	for name, repo := range rf.repositories {
		stats[name] = repo.GetStats()
	}

	return stats
}

// getOrCreateKVStore gets an existing KV store or creates a new one
func (rf *RepositoryFactory) getOrCreateKVStore(serviceName, storeName string) (jetstream.KeyValue, error) {
	// Use service name as store name if not provided
	if storeName == "" {
		storeName = serviceName + "_kv"
	}

	// Try to get existing store
	if kv, err := rf.realtimeManager.GetKVStore(storeName); err == nil {
		return kv, nil
	}

	// Create new store
	config := jetstream.KeyValueConfig{
		Bucket:       storeName,
		Description:  fmt.Sprintf("KV store for %s service", serviceName),
		Storage:      jetstream.FileStorage,
		MaxValueSize: 1024 * 1024,       // 1MB
		MaxBytes:     1024 * 1024 * 100, // 100MB
		History:      64,
		Compression:  true,
	}

	kv, err := rf.realtimeManager.CreateKVStore(storeName, config)
	if err != nil {
		return nil, fmt.Errorf("failed to create KV store %s: %w", storeName, err)
	}

	return kv, nil
}

// RepositoryBuilder provides a fluent interface for building repositories
type RepositoryBuilder struct {
	serviceName string
	config      RepositoryConfig
	factory     *RepositoryFactory
}

// NewRepositoryBuilder creates a new repository builder
func NewRepositoryBuilder(serviceName string, factory *RepositoryFactory) *RepositoryBuilder {
	return &RepositoryBuilder{
		serviceName: serviceName,
		config: RepositoryConfig{
			CacheConfig: CacheConfig{
				DefaultTTL: 5 * time.Minute,
				MaxSize:    1000,
			},
			SyncConfig: SyncConfig{
				BatchSize: 100,
			},
		},
		factory: factory,
	}
}

// WithKVStore sets the KV store name
func (rb *RepositoryBuilder) WithKVStore(storeName string) *RepositoryBuilder {
	rb.config.KVStoreName = storeName
	return rb
}

// WithCache sets cache configuration
func (rb *RepositoryBuilder) WithCache(ttl time.Duration, maxSize int) *RepositoryBuilder {
	rb.config.CacheConfig.DefaultTTL = ttl
	rb.config.CacheConfig.MaxSize = maxSize
	return rb
}

// WithBatchSize sets batch size for bulk operations
func (rb *RepositoryBuilder) WithBatchSize(batchSize int) *RepositoryBuilder {
	rb.config.SyncConfig.BatchSize = batchSize
	return rb
}

// WithLogger sets the logger
func (rb *RepositoryBuilder) WithLogger(logger *jst_log.Logger) *RepositoryBuilder {
	rb.config.Logger = logger
	return rb
}

// Build creates the repository
func (rb *RepositoryBuilder) Build() (*KVRepository, error) {
	return rb.factory.CreateRepository(rb.serviceName, rb.config)
}

// GenericRepository provides a generic interface for any repository
type GenericRepository[T any] struct {
	*KVRepository
	unmarshalFunc func([]byte) (T, error)
	marshalFunc   func(T) ([]byte, error)
}

// NewGenericRepository creates a generic repository for a specific type
func NewGenericRepository[T any](
	kvStore jetstream.KeyValue,
	config RepositoryConfig,
	unmarshalFunc func([]byte) (T, error),
	marshalFunc func(T) ([]byte, error),
) *GenericRepository[T] {
	baseRepo := NewKVRepository(kvStore, config)

	return &GenericRepository[T]{
		KVRepository:  baseRepo,
		unmarshalFunc: unmarshalFunc,
		marshalFunc:   marshalFunc,
	}
}

// GetTyped retrieves a typed value by key
func (gr *GenericRepository[T]) GetTyped(key string) (T, bool) {
	value, exists := gr.Get(key)
	if !exists {
		var zero T
		return zero, false
	}

	if typedValue, ok := value.(T); ok {
		return typedValue, true
	}

	var zero T
	return zero, false
}

// SetTyped sets a typed value by key
func (gr *GenericRepository[T]) SetTyped(key string, value T) error {
	return gr.Set(key, value)
}

// ListTyped returns all typed values
func (gr *GenericRepository[T]) ListTyped() map[string]T {
	values := gr.ListWithValues()
	result := make(map[string]T)

	for key, value := range values {
		if typedValue, ok := value.(T); ok {
			result[key] = typedValue
		}
	}

	return result
}

// OnTypedEvent registers a typed event handler
func (gr *GenericRepository[T]) OnTypedEvent(eventType string, handler func(string, T, T)) {
	gr.OnEvent(eventType, func(key string, oldValue, newValue interface{}) {
		var oldTyped, newTyped T

		if oldValue != nil {
			if ov, ok := oldValue.(T); ok {
				oldTyped = ov
			}
		}

		if newValue != nil {
			if nv, ok := newValue.(T); ok {
				newTyped = nv
			}
		}

		handler(key, oldTyped, newTyped)
	})
}

// RepositoryService integrates repository with real-time service
type RepositoryService struct {
	*RealtimeService
	repository *KVRepository
}

// NewRepositoryService creates a service with integrated repository
func NewRepositoryService(
	serviceName string,
	dependencies []string,
	config RealtimeServiceConfig,
	repositoryConfig RepositoryConfig,
) (*RepositoryService, error) {
	// Create base real-time service
	baseService := NewRealtimeService(serviceName, dependencies, config)

	// Get KV store
	kvStore, err := config.RealtimeManager.GetKVStore(repositoryConfig.KVStoreName)
	if err != nil {
		return nil, fmt.Errorf("failed to get KV store: %w", err)
	}

	// Create repository
	repo := NewKVRepository(kvStore, repositoryConfig)

	// Start repository
	if err := repo.Start(); err != nil {
		return nil, fmt.Errorf("failed to start repository: %w", err)
	}

	return &RepositoryService{
		RealtimeService: baseService,
		repository:      repo,
	}, nil
}

// GetRepository returns the integrated repository
func (rs *RepositoryService) GetRepository() *KVRepository {
	return rs.repository
}

// Shutdown stops the service and repository
func (rs *RepositoryService) Shutdown(ctx context.Context) error {
	// Stop repository first
	if err := rs.repository.Stop(); err != nil {
		rs.GetLogger().Error("failed to stop repository: %v", err)
	}

	// Then stop base service
	return rs.RealtimeService.Shutdown(ctx)
}

// RepositoryServiceBuilder provides a fluent interface for building repository services
type RepositoryServiceBuilder struct {
	*RealtimeServiceBuilder
	repositoryConfig RepositoryConfig
}

// NewRepositoryServiceBuilder creates a new repository service builder
func NewRepositoryServiceBuilder(name string, config RealtimeServiceConfig) *RepositoryServiceBuilder {
	return &RepositoryServiceBuilder{
		RealtimeServiceBuilder: NewRealtimeServiceBuilder(name, config),
		repositoryConfig: RepositoryConfig{
			KVStoreName: name + "_kv",
			CacheConfig: CacheConfig{
				DefaultTTL: 5 * time.Minute,
				MaxSize:    1000,
			},
			SyncConfig: SyncConfig{
				BatchSize: 100,
			},
		},
	}
}

// WithRepositoryKVStore sets the repository KV store name
func (rsb *RepositoryServiceBuilder) WithRepositoryKVStore(storeName string) *RepositoryServiceBuilder {
	rsb.repositoryConfig.KVStoreName = storeName
	return rsb
}

// WithRepositoryCache sets the repository cache configuration
func (rsb *RepositoryServiceBuilder) WithRepositoryCache(ttl time.Duration, maxSize int) *RepositoryServiceBuilder {
	rsb.repositoryConfig.CacheConfig.DefaultTTL = ttl
	rsb.repositoryConfig.CacheConfig.MaxSize = maxSize
	return rsb
}

// WithRepositoryBatchSize sets the repository batch size
func (rsb *RepositoryServiceBuilder) WithRepositoryBatchSize(batchSize int) *RepositoryServiceBuilder {
	rsb.repositoryConfig.SyncConfig.BatchSize = batchSize
	return rsb
}

// Build creates the repository service
func (rsb *RepositoryServiceBuilder) Build() (Service, error) {
	// Create the base real-time service
	_ = rsb.RealtimeServiceBuilder.Build()

	// Create repository service
	repoService, err := NewRepositoryService(
		rsb.name,
		rsb.dependencies,
		rsb.realtimeConfig,
		rsb.repositoryConfig,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create repository service: %w", err)
	}

	// Wrap with custom implementations if provided
	return &customRepositoryService{
		RepositoryService: repoService,
		initializer:       rsb.initializer,
		runner:            rsb.runner,
		shutdowner:        rsb.shutdowner,
		healthChecker:     rsb.healthChecker,
	}, nil
}

// customRepositoryService wraps RepositoryService with custom implementations
type customRepositoryService struct {
	*RepositoryService
	initializer   func(context.Context) error
	runner        func(context.Context) error
	shutdowner    func(context.Context) error
	healthChecker func() error
}

// Initialize calls the custom initializer if provided, otherwise uses base implementation
func (crs *customRepositoryService) Initialize(ctx context.Context) error {
	if crs.initializer != nil {
		return crs.initializer(ctx)
	}
	return crs.RepositoryService.Initialize(ctx)
}

// Run calls the custom runner if provided, otherwise uses base implementation
func (crs *customRepositoryService) Run(ctx context.Context) error {
	if crs.runner != nil {
		crs.mu.Lock()
		crs.running = true
		crs.mu.Unlock()

		crs.logger.Info("repository service started")

		err := crs.runner(ctx)

		crs.logger.Info("repository service stopping...")

		// Perform shutdown
		if shutdownErr := crs.Shutdown(ctx); shutdownErr != nil {
			crs.logger.Error("shutdown error: %v", shutdownErr)
		}

		crs.logger.Info("repository service stopped")
		return err
	}
	return crs.RepositoryService.Run(ctx)
}

// Shutdown calls the custom shutdowner if provided, otherwise uses base implementation
func (crs *customRepositoryService) Shutdown(ctx context.Context) error {
	if crs.shutdowner != nil {
		return crs.shutdowner(ctx)
	}
	return crs.RepositoryService.Shutdown(ctx)
}

// Health calls the custom health checker if provided, otherwise uses base implementation
func (crs *customRepositoryService) Health() error {
	if crs.healthChecker != nil {
		return crs.healthChecker()
	}
	return crs.RepositoryService.Health()
}
