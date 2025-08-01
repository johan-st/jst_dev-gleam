# Data Sync Server

This directory contains the data synchronization server implementation that provides real-time data synchronization capabilities using WebSockets and NATS messaging.

## Features

- **Real-time WebSocket connections** for instant data updates
- **NATS integration** for scalable message distribution
- **Topic-based subscriptions** for targeted data delivery
- **User-specific messaging** for personalized data sync
- **REST API endpoints** for server-initiated data publishing
- **Authentication support** with JWT integration
- **Connection management** with automatic cleanup

## Architecture

```
┌─────────────────┐    WebSocket    ┌─────────────────┐
│   Web Client    │ ◄─────────────► │   Sync Server   │
└─────────────────┘                 └─────────────────┘
                                              │
                                              │ NATS
                                              ▼
                                    ┌─────────────────┐
                                    │   NATS Server   │
                                    └─────────────────┘
```

## Message Types

- `connect` - Client connection established
- `disconnect` - Client disconnected
- `subscribe` - Subscribe to a topic
- `unsubscribe` - Unsubscribe from a topic
- `data` - Data update message
- `error` - Error message
- `auth` - Authentication message
- `sync` - Data synchronization message

## Integration Example

### 1. Initialize Sync Service in main.go

```go
// In your main.go file
import (
    "jst_dev/server/web"
)

func run(ctx context.Context) error {
    // ... existing setup code ...
    
    // Initialize sync service
    syncService := web.NewSyncService(nc, lRoot.WithBreadcrumb("sync"), ctx)
    
    // Set up HTTP server with sync routes
    httpServer := web.New(ctx, nc, conf.WebJwtSecret, lRoot.WithBreadcrumb("http"), articleRepo, conf.Flags.ProxyFrontend)
    
    // Add sync routes
    web.SetupSyncRoutes(httpServer.GetMux(), syncService, lRoot.WithBreadcrumb("sync-routes"))
    
    // ... rest of your setup ...
}
```

### 2. WebSocket Client Example (JavaScript)

```javascript
// Connect to WebSocket
const ws = new WebSocket('ws://localhost:8080/ws/sync?user_id=user123');

ws.onopen = function() {
    console.log('Connected to sync server');
    
    // Subscribe to a topic
    ws.send(JSON.stringify({
        type: 'subscribe',
        topic: 'user.notifications'
    }));
};

ws.onmessage = function(event) {
    const message = JSON.parse(event.data);
    
    switch(message.type) {
        case 'connect':
            console.log('Connected:', message.data);
            break;
        case 'data':
            console.log('Data update:', message.data);
            // Handle data update
            break;
        case 'error':
            console.error('Error:', message.error);
            break;
    }
};

// Send data to sync
function syncData(topic, data) {
    ws.send(JSON.stringify({
        type: 'sync',
        topic: topic,
        data: data
    }));
}
```

### 3. Server-Side Data Publishing

```go
// Publish data to a specific topic
err := syncService.PublishData("user.notifications", map[string]interface{}{
    "type": "alert",
    "message": "New message received",
    "timestamp": time.Now().Unix(),
})

// Publish data to a specific user
err = syncService.PublishToUser("user123", map[string]interface{}{
    "type": "personal",
    "data": "Your personal data",
})
```

### 4. REST API Usage

```bash
# Publish data to a topic
curl -X POST http://localhost:8080/api/sync/publish \
  -H "Content-Type: application/json" \
  -d '{"topic": "updates", "data": {"message": "Hello World"}}'

# Broadcast to all clients
curl -X POST http://localhost:8080/api/sync/broadcast \
  -H "Content-Type: application/json" \
  -d '{"data": {"announcement": "Server maintenance"}}'

# Get sync status
curl http://localhost:8080/api/sync/status
```

## Configuration

### Environment Variables

```bash
# WebSocket configuration
WS_READ_BUFFER_SIZE=1024
WS_WRITE_BUFFER_SIZE=1024
WS_PING_INTERVAL=54s
WS_PONG_WAIT=60s

# NATS configuration (already configured in your app)
NATS_URL=nats://localhost:4222
```

### JWT Integration

The sync server integrates with your existing JWT authentication:

```go
// Extract user ID from JWT token
func extractUserIDFromJWT(tokenString string) (string, error) {
    // Use your existing JWT parsing logic
    // Return user ID from token claims
}
```

## Use Cases

1. **Real-time Notifications** - Push notifications to users
2. **Live Data Updates** - Sync data changes across clients
3. **Collaborative Editing** - Real-time document collaboration
4. **Chat Applications** - Instant messaging
5. **Dashboard Updates** - Live metrics and status updates
6. **Game State Sync** - Multiplayer game state synchronization

## Performance Considerations

- **Connection Limits**: Monitor active WebSocket connections
- **Message Size**: Keep messages small for better performance
- **Topic Management**: Use specific topics to avoid unnecessary broadcasts
- **Error Handling**: Implement proper error handling and reconnection logic
- **Load Balancing**: Use NATS clustering for horizontal scaling

## Security

- **Origin Checking**: Implement proper CORS policies
- **Authentication**: Use JWT tokens for user identification
- **Rate Limiting**: Implement rate limiting for WebSocket connections
- **Input Validation**: Validate all incoming messages
- **TLS**: Use WSS (WebSocket Secure) in production

## Monitoring

Monitor the sync service using the status endpoint:

```bash
curl http://localhost:8080/api/sync/status
```

Response:
```json
{
  "status": "running",
  "clients": 5,
  "connections": 5,
  "timestamp": 1640995200
}
```

## Troubleshooting

### Common Issues

1. **Connection Drops**: Check network stability and implement reconnection logic
2. **High Memory Usage**: Monitor client connections and implement proper cleanup
3. **Message Loss**: Use NATS persistence for critical messages
4. **Authentication Failures**: Verify JWT token format and expiration

### Debug Logging

Enable debug logging to troubleshoot issues:

```go
logger.SetLevel(jst_log.DebugLevel)
``` 