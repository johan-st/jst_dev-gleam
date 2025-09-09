package core

import (
	"context"
	"fmt"
	"sync"
	"time"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
)

// ServiceState represents the current state of a service
type ServiceState int

const (
	ServiceStateStopped ServiceState = iota
	ServiceStateInitializing
	ServiceStateRunning
	ServiceStateStopping
	ServiceStateError
)

func (s ServiceState) String() string {
	switch s {
	case ServiceStateStopped:
		return "stopped"
	case ServiceStateInitializing:
		return "initializing"
	case ServiceStateRunning:
		return "running"
	case ServiceStateStopping:
		return "stopping"
	case ServiceStateError:
		return "error"
	default:
		return "unknown"
	}
}

// Service represents a unified service interface that all services must implement
type Service interface {
	// Name returns the service name for identification
	Name() string

	// Run starts the service and blocks until the context is cancelled
	Run(ctx context.Context) error

	// Health checks if the service is healthy
	Health() error

	// Dependencies returns a list of service names this service depends on
	Dependencies() []string

	// Initialize performs any setup required before Run is called
	Initialize(ctx context.Context) error

	// Shutdown performs cleanup when the service is being stopped
	Shutdown(ctx context.Context) error
}

// ServiceConfig represents common configuration for all services
type ServiceConfig struct {
	Logger   *jst_log.Logger
	NatsConn *nats.Conn
	Timeout  time.Duration
}

// ServiceInfo holds metadata about a registered service
type ServiceInfo struct {
	Service Service
	Config  ServiceConfig
	State   ServiceState
	Error   error
	mu      sync.RWMutex
}

// SetState safely updates the service state
func (si *ServiceInfo) SetState(state ServiceState) {
	si.mu.Lock()
	defer si.mu.Unlock()
	si.State = state
}

// GetState safely retrieves the service state
func (si *ServiceInfo) GetState() ServiceState {
	si.mu.RLock()
	defer si.mu.RUnlock()
	return si.State
}

// SetError safely sets the service error
func (si *ServiceInfo) SetError(err error) {
	si.mu.Lock()
	defer si.mu.Unlock()
	si.Error = err
	if err != nil {
		si.State = ServiceStateError
	}
}

// GetError safely retrieves the service error
func (si *ServiceInfo) GetError() error {
	si.mu.RLock()
	defer si.mu.RUnlock()
	return si.Error
}

// ServiceRegistry manages service lifecycle and dependencies
type ServiceRegistry struct {
	services     map[string]*ServiceInfo
	dependencies map[string][]string
	startOrder   []string // Cached topological sort result
	mu           sync.RWMutex
	initialized  bool
}

// NewServiceRegistry creates a new service registry
func NewServiceRegistry() *ServiceRegistry {
	return &ServiceRegistry{
		services:     make(map[string]*ServiceInfo),
		dependencies: make(map[string][]string),
		startOrder:   nil,
		initialized:  false,
	}
}

// Register adds a service to the registry
func (r *ServiceRegistry) Register(name string, service Service, config ServiceConfig) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.initialized {
		return fmt.Errorf("cannot register service %s: registry already initialized", name)
	}

	if _, exists := r.services[name]; exists {
		return fmt.Errorf("service %s already registered", name)
	}

	// Validate service name matches
	if service.Name() != name {
		return fmt.Errorf("service name mismatch: expected %s, got %s", name, service.Name())
	}

	r.services[name] = &ServiceInfo{
		Service: service,
		Config:  config,
		State:   ServiceStateStopped,
		Error:   nil,
	}
	r.dependencies[name] = service.Dependencies()

	// Invalidate cached start order
	r.startOrder = nil

	return nil
}

// Get retrieves a service by name
func (r *ServiceRegistry) Get(name string) (Service, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	info, exists := r.services[name]
	if !exists {
		return nil, false
	}
	return info.Service, true
}

// GetInfo retrieves service info by name
func (r *ServiceRegistry) GetInfo(name string) (*ServiceInfo, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	info, exists := r.services[name]
	return info, exists
}

// GetConfig retrieves service configuration by name
func (r *ServiceRegistry) GetConfig(name string) (ServiceConfig, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	info, exists := r.services[name]
	if !exists {
		return ServiceConfig{}, false
	}
	return info.Config, true
}

// InitializeAll initializes all registered services in dependency order
func (r *ServiceRegistry) InitializeAll(ctx context.Context) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.initialized {
		return fmt.Errorf("registry already initialized")
	}

	// Calculate start order once
	startOrder, err := r.calculateStartOrder()
	if err != nil {
		return fmt.Errorf("failed to resolve service dependencies: %w", err)
	}
	r.startOrder = startOrder
	r.initialized = true

	// Initialize all services
	for _, serviceName := range startOrder {
		info := r.services[serviceName]
		info.SetState(ServiceStateInitializing)

		// Create context with timeout for initialization
		initCtx, cancel := context.WithTimeout(ctx, info.Config.Timeout)

		if err := info.Service.Initialize(initCtx); err != nil {
			cancel()
			info.SetError(fmt.Errorf("failed to initialize service %s: %w", serviceName, err))
			return info.GetError()
		}
		cancel()
	}

	return nil
}

// StartAll starts all registered services in dependency order
func (r *ServiceRegistry) StartAll(ctx context.Context, waitGroup *sync.WaitGroup) error {
	r.mu.RLock()
	defer r.mu.RUnlock()

	if !r.initialized {
		return fmt.Errorf("registry not initialized, call InitializeAll first")
	}

	if r.startOrder == nil {
		return fmt.Errorf("start order not calculated")
	}

	// Start all services
	for _, serviceName := range r.startOrder {
		info := r.services[serviceName]
		waitGroup.Add(1)

		go func(svcInfo *ServiceInfo, name string) {
			defer waitGroup.Done()

			svcInfo.SetState(ServiceStateRunning)
			if err := svcInfo.Service.Run(ctx); err != nil {
				svcInfo.SetError(fmt.Errorf("service %s failed: %w", name, err))
			} else {
				svcInfo.SetState(ServiceStateStopped)
			}
		}(info, serviceName)
	}

	return nil
}

// ShutdownAll gracefully shuts down all services in reverse dependency order
func (r *ServiceRegistry) ShutdownAll(ctx context.Context) error {
	r.mu.RLock()
	defer r.mu.RUnlock()

	if r.startOrder == nil {
		return nil // Nothing to shutdown
	}

	// Shutdown in reverse order
	for i := len(r.startOrder) - 1; i >= 0; i-- {
		serviceName := r.startOrder[i]
		info := r.services[serviceName]

		if info.GetState() == ServiceStateRunning {
			info.SetState(ServiceStateStopping)

			// Create context with timeout for shutdown
			shutdownCtx, cancel := context.WithTimeout(ctx, info.Config.Timeout)

			if err := info.Service.Shutdown(shutdownCtx); err != nil {
				cancel()
				info.SetError(fmt.Errorf("failed to shutdown service %s: %w", serviceName, err))
			}
			cancel()

			info.SetState(ServiceStateStopped)
		}
	}

	return nil
}

// HealthCheck performs health checks on all services
func (r *ServiceRegistry) HealthCheck() map[string]error {
	r.mu.RLock()
	defer r.mu.RUnlock()

	results := make(map[string]error)
	for name, info := range r.services {
		if info.GetState() != ServiceStateRunning {
			results[name] = fmt.Errorf("service not running (state: %s)", info.GetState())
			continue
		}

		if err := info.Service.Health(); err != nil {
			results[name] = err
		}
	}

	return results
}

// GetServiceStates returns the current state of all services
func (r *ServiceRegistry) GetServiceStates() map[string]ServiceState {
	r.mu.RLock()
	defer r.mu.RUnlock()

	states := make(map[string]ServiceState)
	for name, info := range r.services {
		states[name] = info.GetState()
	}

	return states
}

// calculateStartOrder performs a topological sort of services based on dependencies
func (r *ServiceRegistry) calculateStartOrder() ([]string, error) {
	visited := make(map[string]bool)
	tempVisited := make(map[string]bool)
	result := make([]string, 0, len(r.services))

	var visit func(string) error
	visit = func(serviceName string) error {
		if tempVisited[serviceName] {
			return fmt.Errorf("circular dependency detected involving service %s", serviceName)
		}
		if visited[serviceName] {
			return nil
		}

		tempVisited[serviceName] = true

		// Visit dependencies first
		for _, dep := range r.dependencies[serviceName] {
			if _, exists := r.services[dep]; !exists {
				return fmt.Errorf("service %s depends on unknown service %s", serviceName, dep)
			}
			if err := visit(dep); err != nil {
				return err
			}
		}

		tempVisited[serviceName] = false
		visited[serviceName] = true
		result = append(result, serviceName)

		return nil
	}

	// Visit all services
	for serviceName := range r.services {
		if !visited[serviceName] {
			if err := visit(serviceName); err != nil {
				return nil, err
			}
		}
	}

	return result, nil
}

// ServiceFactory creates services with consistent configuration
type ServiceFactory struct {
	registry *ServiceRegistry
	config   *GlobalConfig
}

// NewServiceFactory creates a new service factory
func NewServiceFactory(config *GlobalConfig) *ServiceFactory {
	return &ServiceFactory{
		registry: NewServiceRegistry(),
		config:   config,
	}
}

// CreateAllServices creates and registers all services
func (f *ServiceFactory) CreateAllServices(ctx context.Context) error {
	// Create services in dependency order
	services := []struct {
		name    string
		factory func(ServiceConfig) (Service, error)
	}{
		{"who", f.createWhoService},
		{"articles", f.createArticlesService},
		{"convo", f.createConvoService},
		{"urlshort", f.createUrlShortService},
		{"ntfy", f.createNtfyService},
		{"web", f.createWebService},
	}

	for _, svc := range services {
		config := ServiceConfig{
			Logger:   f.config.Logger.WithBreadcrumb(svc.name),
			NatsConn: f.config.NatsConn,
			Timeout:  f.config.ServiceTimeout,
		}

		service, err := svc.factory(config)
		if err != nil {
			return fmt.Errorf("failed to create service %s: %w", svc.name, err)
		}

		if err := f.registry.Register(svc.name, service, config); err != nil {
			return fmt.Errorf("failed to register service %s: %w", svc.name, err)
		}
	}

	return nil
}

// GetRegistry returns the service registry
func (f *ServiceFactory) GetRegistry() *ServiceRegistry {
	return f.registry
}

// Service factory methods - these will be implemented when we convert each service
func (f *ServiceFactory) createWhoService(config ServiceConfig) (Service, error) {
	// TODO: Implement when converting who service
	return nil, fmt.Errorf("not implemented yet")
}

func (f *ServiceFactory) createArticlesService(config ServiceConfig) (Service, error) {
	// Import the articles service package
	// Note: This would need to be imported at the top of the file
	// For now, we'll return an error indicating the import is needed
	return nil, fmt.Errorf("articles service import needed - add 'jst_dev/server/articles' import")
}

func (f *ServiceFactory) createConvoService(config ServiceConfig) (Service, error) {
	// TODO: Implement when converting convo service
	return nil, fmt.Errorf("not implemented yet")
}

func (f *ServiceFactory) createUrlShortService(config ServiceConfig) (Service, error) {
	// TODO: Implement when converting urlshort service
	return nil, fmt.Errorf("not implemented yet")
}

func (f *ServiceFactory) createNtfyService(config ServiceConfig) (Service, error) {
	// TODO: Implement when converting ntfy service
	return nil, fmt.Errorf("not implemented yet")
}

func (f *ServiceFactory) createWebService(config ServiceConfig) (Service, error) {
	// TODO: Implement when converting web service
	return nil, fmt.Errorf("not implemented yet")
}
