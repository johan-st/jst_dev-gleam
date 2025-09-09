# Server Architecture Improvements

This document outlines the comprehensive improvements made to the server architecture to address inconsistencies, reduce code duplication, and improve maintainability.

## Overview of Improvements

The server architecture has been refactored to provide:
- **Unified service interface** for all services
- **Centralized configuration management**
- **Standardized error handling**
- **Dependency injection and service registry**
- **Consistent NATS client wrapper**
- **Improved service lifecycle management**

## Key Components

### 1. Core Service Framework (`server/core/`)

#### `service.go` - Unified Service Interface
- **Service interface**: Standardized interface that all services must implement
- **ServiceRegistry**: Manages service lifecycle, dependencies, and health checks
- **ServiceFactory**: Creates and configures services consistently
- **ServiceState**: Tracks service states (stopped, initializing, running, stopping, error)

**Key Features:**
- Automatic dependency resolution with topological sorting
- Graceful startup and shutdown in dependency order
- Health check aggregation
- Service state tracking
- Thread-safe operations

#### `base_service.go` - Base Service Implementation
- **BaseService**: Common functionality for all services
- **ServiceBuilder**: Fluent interface for building services
- **customService**: Wrapper for services with custom implementations

**Key Features:**
- Common initialization, health checking, and shutdown logic
- NATS connection validation
- Configurable service implementations
- Builder pattern for easy service creation

#### `config.go` - Centralized Configuration
- **GlobalConfig**: Unified configuration structure
- **Configuration validation**: Ensures all required fields are present
- **Environment-specific settings**: Support for different deployment environments

#### `errors.go` - Standardized Error Handling
- **ServiceError**: Structured error types with codes and context
- **APIError/APIResponse**: Consistent API response format
- **Error code mapping**: Automatic HTTP status code mapping
- **Error chaining**: Support for error cause tracking

#### `nats_client.go` - NATS Client Wrapper
- **NATSClient**: Wrapper around NATS operations
- **Consistent error handling**: Standardized error responses
- **JSON marshaling/unmarshaling**: Built-in JSON support
- **Context support**: Request cancellation and timeouts
- **Connection validation**: Automatic connection health checks

### 2. Service Conversion Example (`server/articles/service.go`)

The articles service has been converted to demonstrate the new architecture:

**Before (Repository Pattern):**
```go
type ArticleRepo interface {
    Get(id uuid.UUID) (Article, error)
    Create(art Article) (Article, error)
    // ... other methods
}
```

**After (Microservice Pattern):**
```go
type ArticlesService struct {
    *core.BaseService
    kv jetstream.KeyValue
}

// Implements core.Service interface
func (s *ArticlesService) Run(ctx context.Context) error {
    // NATS microservice implementation
}
```

**Benefits:**
- Consistent with other services (who, convo, urlshort)
- Built-in health checking and lifecycle management
- Standardized error handling
- NATS microservice endpoints for inter-service communication

### 3. New Main Application (`server/main_new.go`)

The new main application demonstrates:
- **Unified service initialization**: All services created through ServiceFactory
- **Dependency resolution**: Automatic startup order based on dependencies
- **Graceful shutdown**: Proper cleanup of all services
- **Configuration validation**: Early validation of all configuration
- **Health monitoring**: Built-in service health checking

## Architecture Benefits

### 1. **Consistency**
- All services follow the same patterns and interfaces
- Standardized error handling across all services
- Consistent configuration management
- Uniform service lifecycle management

### 2. **Maintainability**
- Reduced code duplication through shared utilities
- Clear separation of concerns
- Easy to add new services using the builder pattern
- Centralized configuration reduces scattered settings

### 3. **Reliability**
- Proper dependency resolution prevents startup issues
- Graceful shutdown ensures clean resource cleanup
- Health checking provides service monitoring
- Standardized error handling improves debugging

### 4. **Testability**
- Dependency injection makes services easier to test
- Service registry allows for service mocking
- Base service provides common test utilities
- Clear interfaces make unit testing straightforward

### 5. **Extensibility**
- Easy to add new services using the ServiceBuilder
- Service registry automatically handles dependencies
- NATS client wrapper simplifies inter-service communication
- Configuration system supports new service types

## Migration Guide

### Converting Existing Services

1. **Implement the Service Interface:**
```go
type MyService struct {
    *core.BaseService
    // service-specific fields
}

func NewMyService(config core.ServiceConfig) (core.Service, error) {
    base := core.NewBaseService("myservice", []string{"dependency"}, config)
    
    service := &MyService{
        BaseService: base,
    }
    
    return core.NewServiceBuilder("myservice", config).
        WithInitializer(service.initialize).
        WithRunner(service.run).
        WithShutdowner(service.shutdown).
        WithHealthChecker(service.health).
        Build(), nil
}
```

2. **Implement Required Methods:**
```go
func (s *MyService) initialize(ctx context.Context) error {
    // Service-specific initialization
    return s.BaseService.Initialize(ctx)
}

func (s *MyService) run(ctx context.Context) error {
    // Service-specific run logic
    // Usually involves setting up NATS microservice endpoints
}

func (s *MyService) shutdown(ctx context.Context) error {
    // Service-specific cleanup
    return s.BaseService.Shutdown(ctx)
}

func (s *MyService) health() error {
    // Service-specific health checks
    return s.BaseService.Health()
}
```

3. **Update Service Factory:**
```go
func (f *ServiceFactory) createMyService(config ServiceConfig) (Service, error) {
    return NewMyService(config)
}
```

### Configuration Updates

1. **Update GlobalConfig** with new service-specific settings
2. **Add validation** for new configuration fields
3. **Update environment variable loading** in main application

### Error Handling Updates

1. **Replace custom errors** with ServiceError types
2. **Use standardized error codes** for consistent API responses
3. **Implement proper error chaining** for debugging

## Performance Considerations

### Startup Time
- **Dependency resolution**: O(V + E) where V is services and E is dependencies
- **Parallel initialization**: Services can initialize in parallel when dependencies allow
- **Cached startup order**: Topological sort is calculated once and cached

### Runtime Performance
- **Service registry**: O(1) service lookup with read locks
- **Health checks**: Parallel health checking with configurable intervals
- **NATS client**: Connection pooling and request batching

### Memory Usage
- **Service state tracking**: Minimal overhead with efficient state management
- **Error handling**: Structured errors with optional details to control memory usage
- **Configuration**: Single configuration instance shared across services

## Future Enhancements

### Phase 2: Configuration Management
- Environment-specific configuration files
- Configuration hot-reloading
- Configuration validation schemas
- Secret management integration

### Phase 3: Advanced Error Handling
- Error aggregation and reporting
- Circuit breaker patterns
- Retry mechanisms with exponential backoff
- Error metrics and monitoring

### Phase 4: Service Discovery
- Dynamic service registration
- Load balancing across service instances
- Service versioning and compatibility
- Health-based routing

### Phase 5: Observability
- Distributed tracing integration
- Metrics collection and export
- Structured logging with correlation IDs
- Performance monitoring and alerting

## Conclusion

These architectural improvements provide a solid foundation for:
- **Scalable service development** with consistent patterns
- **Reliable service operation** with proper lifecycle management
- **Maintainable codebase** with reduced duplication
- **Testable services** with clear interfaces and dependency injection
- **Future extensibility** with flexible service registration and configuration

The new architecture maintains backward compatibility while providing a clear migration path for existing services. The modular design allows for incremental adoption, making it easy to convert services one at a time.
