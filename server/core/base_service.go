package core

import (
	"context"
	"fmt"
	"sync"
	"time"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
)

// BaseService provides common functionality for all services
type BaseService struct {
	name         string
	dependencies []string
	logger       *jst_log.Logger
	nc           *nats.Conn
	timeout      time.Duration
	mu           sync.RWMutex
	initialized  bool
	running      bool
}

// NewBaseService creates a new base service
func NewBaseService(name string, dependencies []string, config ServiceConfig) *BaseService {
	return &BaseService{
		name:         name,
		dependencies: dependencies,
		logger:       config.Logger,
		nc:           config.NatsConn,
		timeout:      config.Timeout,
		initialized:  false,
		running:      false,
	}
}

// Name returns the service name
func (bs *BaseService) Name() string {
	return bs.name
}

// Dependencies returns the service dependencies
func (bs *BaseService) Dependencies() []string {
	return bs.dependencies
}

// Health performs a basic health check
func (bs *BaseService) Health() error {
	bs.mu.RLock()
	defer bs.mu.RUnlock()

	if !bs.initialized {
		return fmt.Errorf("service not initialized")
	}

	if !bs.running {
		return fmt.Errorf("service not running")
	}

	// Check NATS connection
	if bs.nc.Status() != nats.CONNECTED {
		return fmt.Errorf("NATS connection not connected: %s", bs.nc.Status())
	}

	return nil
}

// Initialize performs basic initialization
func (bs *BaseService) Initialize(ctx context.Context) error {
	bs.mu.Lock()
	defer bs.mu.Unlock()

	if bs.initialized {
		return fmt.Errorf("service already initialized")
	}

	// Validate NATS connection
	if bs.nc.Status() != nats.CONNECTED {
		return fmt.Errorf("NATS connection not connected: %s", bs.nc.Status())
	}

	bs.initialized = true
	bs.logger.Info("service initialized")

	return nil
}

// Shutdown performs basic cleanup
func (bs *BaseService) Shutdown(ctx context.Context) error {
	bs.mu.Lock()
	defer bs.mu.Unlock()

	if !bs.initialized {
		return nil // Nothing to shutdown
	}

	bs.running = false
	bs.logger.Info("service shutdown")

	return nil
}

// Run provides a basic run implementation that can be overridden
func (bs *BaseService) Run(ctx context.Context) error {
	bs.mu.Lock()
	bs.running = true
	bs.mu.Unlock()

	bs.logger.Info("service started")

	// Wait for context cancellation
	<-ctx.Done()

	bs.logger.Info("service stopping...")

	// Perform shutdown
	if err := bs.Shutdown(ctx); err != nil {
		bs.logger.Error("shutdown error: %v", err)
		return err
	}

	bs.logger.Info("service stopped")
	return nil
}

// IsInitialized returns whether the service is initialized
func (bs *BaseService) IsInitialized() bool {
	bs.mu.RLock()
	defer bs.mu.RUnlock()
	return bs.initialized
}

// IsRunning returns whether the service is running
func (bs *BaseService) IsRunning() bool {
	bs.mu.RLock()
	defer bs.mu.RUnlock()
	return bs.running
}

// GetLogger returns the service logger
func (bs *BaseService) GetLogger() *jst_log.Logger {
	return bs.logger
}

// GetNatsConn returns the NATS connection
func (bs *BaseService) GetNatsConn() *nats.Conn {
	return bs.nc
}

// GetTimeout returns the service timeout
func (bs *BaseService) GetTimeout() time.Duration {
	return bs.timeout
}

// ServiceBuilder provides a fluent interface for building services
type ServiceBuilder struct {
	name          string
	dependencies  []string
	config        ServiceConfig
	initializer   func(context.Context) error
	runner        func(context.Context) error
	shutdowner    func(context.Context) error
	healthChecker func() error
}

// NewServiceBuilder creates a new service builder
func NewServiceBuilder(name string, config ServiceConfig) *ServiceBuilder {
	return &ServiceBuilder{
		name:         name,
		dependencies: []string{},
		config:       config,
	}
}

// WithDependencies sets the service dependencies
func (sb *ServiceBuilder) WithDependencies(deps ...string) *ServiceBuilder {
	sb.dependencies = deps
	return sb
}

// WithInitializer sets a custom initializer
func (sb *ServiceBuilder) WithInitializer(init func(context.Context) error) *ServiceBuilder {
	sb.initializer = init
	return sb
}

// WithRunner sets a custom runner
func (sb *ServiceBuilder) WithRunner(run func(context.Context) error) *ServiceBuilder {
	sb.runner = run
	return sb
}

// WithShutdowner sets a custom shutdown function
func (sb *ServiceBuilder) WithShutdowner(shutdown func(context.Context) error) *ServiceBuilder {
	sb.shutdowner = shutdown
	return sb
}

// WithHealthChecker sets a custom health checker
func (sb *ServiceBuilder) WithHealthChecker(health func() error) *ServiceBuilder {
	sb.healthChecker = health
	return sb
}

// Build creates the service
func (sb *ServiceBuilder) Build() Service {
	base := NewBaseService(sb.name, sb.dependencies, sb.config)

	return &customService{
		BaseService:   base,
		initializer:   sb.initializer,
		runner:        sb.runner,
		shutdowner:    sb.shutdowner,
		healthChecker: sb.healthChecker,
	}
}

// customService wraps BaseService with custom implementations
type customService struct {
	*BaseService
	initializer   func(context.Context) error
	runner        func(context.Context) error
	shutdowner    func(context.Context) error
	healthChecker func() error
}

// Initialize calls the custom initializer if provided, otherwise uses base implementation
func (cs *customService) Initialize(ctx context.Context) error {
	if cs.initializer != nil {
		return cs.initializer(ctx)
	}
	return cs.BaseService.Initialize(ctx)
}

// Run calls the custom runner if provided, otherwise uses base implementation
func (cs *customService) Run(ctx context.Context) error {
	if cs.runner != nil {
		cs.mu.Lock()
		cs.running = true
		cs.mu.Unlock()

		cs.logger.Info("service started")

		err := cs.runner(ctx)

		cs.logger.Info("service stopping...")

		// Perform shutdown
		if shutdownErr := cs.Shutdown(ctx); shutdownErr != nil {
			cs.logger.Error("shutdown error: %v", shutdownErr)
		}

		cs.logger.Info("service stopped")
		return err
	}
	return cs.BaseService.Run(ctx)
}

// Shutdown calls the custom shutdowner if provided, otherwise uses base implementation
func (cs *customService) Shutdown(ctx context.Context) error {
	if cs.shutdowner != nil {
		return cs.shutdowner(ctx)
	}
	return cs.BaseService.Shutdown(ctx)
}

// Health calls the custom health checker if provided, otherwise uses base implementation
func (cs *customService) Health() error {
	if cs.healthChecker != nil {
		return cs.healthChecker()
	}
	return cs.BaseService.Health()
}
