# NATS Real-Time Architecture

## Overview
A comprehensive real-time system using NATS subjects, streams, KV stores, and blob storage with server-side caching and WebSocket support.

## Core Components

### 1. RealtimeManager (`core/realtime.go`)
- **Purpose**: Central hub for real-time features
- **Features**:
  - Service registration with subject patterns
  - Server-side caching with TTL and invalidation
  - JetStream streams for persistence
  - KV stores for data storage
  - Client subscription management

### 2. RealtimeService (`core/realtime_service.go`)
- **Purpose**: Base service with real-time capabilities
- **Features**:
  - KV store watching and cache synchronization
  - Real-time update publishing
  - Service discovery integration
  - Builder pattern for easy service creation

### 3. WebSocketHandler (`core/websocket_handler.go`)
- **Purpose**: WebSocket connections for client real-time updates
- **Features**:
  - Client subscription management
  - Message routing to NATS subjects
  - Automatic cleanup and health monitoring

## Key Features

### Real-Time Updates
```go
// Publish updates
realtimeManager.PublishUpdate("articles", "article", "created", data, metadata)

// Subscribe to updates
service.SubscribeToUpdates("articles.*", handler)
```

### Server-Side Caching
```go
// Set cache with TTL
service.SetCache("key", value, 5*time.Minute)

// Get from cache
if value, found := service.GetCache("key"); found {
    // Use cached value
}

// Invalidate cache
service.InvalidateCache([]string{"key1", "key2"})
```

### KV Store Integration
```go
// Watch KV changes and update cache
service.WatchKV(ctx, true) // watch all keys

// KV changes automatically update cache and publish real-time updates
```

### WebSocket Client Integration
```javascript
// Client subscribes to real-time updates
ws.send(JSON.stringify({
    type: 'subscribe',
    data: 'updates.articles.article.*'
}));

// Client receives real-time updates
ws.onmessage = function(event) {
    const update = JSON.parse(event.data);
    // Handle real-time update
};
```

## Subject Patterns

### Update Subjects
- `updates.{service}.{resource}.{action}`
- Examples: `updates.articles.article.created`, `updates.users.user.updated`

### Cache Invalidation
- `cache.{service}.{resource}`
- Examples: `cache.articles.all`, `cache.users.123`

### Service Discovery
- `service.{service}.{endpoint}`
- Examples: `service.articles.subjects`, `service.users.endpoints`

### Client Subscriptions
- `client.{client_id}.{subscription_id}`
- Examples: `client.abc123.sub1`

## Usage Example

### 1. Create Real-Time Manager
```go
realtimeManager, err := core.NewRealtimeManager(nc, logger, config)
```

### 2. Register Service
```go
subjects := map[string]string{
    "created": "articles.created",
    "updated": "articles.updated",
}
patterns := []string{"articles.*"}

realtimeManager.RegisterService("articles", subjects, patterns)
```

### 3. Create Real-Time Service
```go
service := core.NewRealtimeServiceBuilder("articles", config).
    WithKVStore("articles").
    WithSubjects(subjects).
    WithCache(5*time.Minute).
    WithKVWatcher(true).
    Build()
```

### 4. Publish Updates
```go
service.PublishUpdate("article", "created", articleData, metadata)
```

### 5. Handle WebSocket Connections
```go
http.HandleFunc("/ws", wsHandler.HandleWebSocket)
```

## Benefits

1. **Real-Time**: Instant updates to all connected clients
2. **Caching**: Server-side cache with automatic invalidation
3. **Scalable**: NATS handles high-throughput message delivery
4. **Persistent**: JetStream streams and KV stores for durability
5. **Flexible**: Subject patterns allow fine-grained subscriptions
6. **Efficient**: Cache reduces database load, KV watching keeps cache in sync

## Architecture Flow

1. **Service** updates data in KV store
2. **KV Watcher** detects change and updates cache
3. **Real-Time Manager** publishes update to NATS subject
4. **WebSocket Handler** forwards update to subscribed clients
5. **Clients** receive real-time updates instantly

This architecture provides a complete real-time solution with caching, persistence, and client connectivity using NATS as the backbone.
