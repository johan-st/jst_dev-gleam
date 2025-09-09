# Minimal vs Complex Repository Pattern

## Current Complex Implementation

### Files: 6 core files + examples
- `kv_repository.go` (510 lines)
- `repository_factory.go` (462 lines) 
- `realtime_service.go` (457 lines)
- `realtime.go` (673 lines)
- `websocket_handler.go` (454 lines)
- `base_service.go` (276 lines)
- **Total: ~2,800 lines**

### Features:
- Complex service registry with dependency resolution
- Multiple configuration structs
- Event handlers and callbacks
- WebSocket management
- Service discovery
- Health checking
- Generic type support
- Builder patterns
- Multiple sync strategies

## Minimal Implementation

### Files: 2 core files + example
- `simple_repository.go` (85 lines)
- `minimal_service.go` (120 lines)
- **Total: ~205 lines**

### Features:
- Direct KV store access
- Automatic sync via NATS `WatchAll()`
- Basic CRUD operations
- NATS microservice endpoints
- Real-time updates
- Simple caching

## Code Comparison

### Complex Repository Creation:
```go
// 1. Create real-time manager
realtimeManager, err := core.NewRealtimeManager(nc, logger, config)

// 2. Create repository factory
repoFactory := core.NewRepositoryFactory(realtimeManager)

// 3. Create repository with complex config
repo, err := repoFactory.CreateRepository("articles", core.RepositoryConfig{
    KVStoreName: "articles",
    CacheConfig: core.CacheConfig{
        DefaultTTL: 5 * time.Minute,
        MaxSize:    1000,
    },
    SyncConfig: core.SyncConfig{
        BatchSize: 100,
    },
    Logger: logger,
})

// 4. Create service with builder pattern
service := core.NewRealtimeServiceBuilder("articles", config).
    WithKVStore("articles").
    WithSubjects(subjects).
    WithCache(5*time.Minute).
    WithKVWatcher(true).
    Build()
```

### Minimal Repository Creation:
```go
// 1. Create KV store
kv, err := js.CreateOrUpdateKeyValue(ctx, config)

// 2. Create minimal service
service := core.NewMinimalService("articles", nc, kv, logger)

// 3. Start service
service.Start()

// 4. Use repository
repo := service.GetRepository()
```

## Usage Comparison

### Complex Usage:
```go
// Set with TTL
repo.SetWithTTL("key", value, 5*time.Minute)

// Get with revision
value, rev, found := repo.GetWithRevision("key")

// Event handlers
repo.OnEvent("created", func(key string, old, new interface{}) {
    // Handle event
})

// Generic operations
genericRepo := core.NewGenericRepository[Article](kv, config, marshal, unmarshal)
article, found := genericRepo.GetTyped("article-1")
```

### Minimal Usage:
```go
// Simple operations
repo.Set("key", value)
value, found := repo.Get("key")
repo.Delete("key")
keys := repo.List()

// Real-time updates
service.PublishUpdate("article", "created", data)
```

## Benefits of Minimal Approach

### ✅ **Simplicity**
- 85% less code
- Easy to understand and maintain
- Fewer abstractions

### ✅ **Performance**
- Direct KV access
- No complex event system overhead
- Minimal memory footprint

### ✅ **NATS Native**
- Leverages NATS `WatchAll()` directly
- No custom sync logic needed
- Uses NATS microservices naturally

### ✅ **Flexibility**
- Easy to extend for specific needs
- No complex configuration
- Direct access to underlying KV store

## When to Use Each

### Use Minimal When:
- You want simple, fast development
- You don't need complex event handling
- You prefer direct control
- You're building prototypes or simple services

### Use Complex When:
- You need advanced features (health checks, service discovery)
- You have complex dependency requirements
- You need WebSocket support
- You're building a large, distributed system

## Migration Path

You can easily migrate from minimal to complex as your needs grow:

1. **Start with minimal** for rapid development
2. **Add features incrementally** as needed
3. **Migrate to complex** only when necessary

The minimal implementation provides 80% of the functionality with 20% of the complexity!
