# NTFY Services Setup Guide

This guide explains how to set up and use the enhanced ntfy notification services for machine events, NATS connection monitoring, and error logging.

## Overview

The enhanced ntfy system provides three main services:

1. **Machine Event Notifier** - Monitors machine lifecycle events (startup, shutdown, scaling, health)
2. **NATS Event Notifier** - Monitors NATS connection status and events
3. **Error Logger** - Handles error logging with automatic notifications

## Prerequisites

- Go 1.19+
- NATS server/cluster access
- ntfy.sh account (or self-hosted instance)
- Environment variables configured

## Environment Variables

```bash
# Required
NTFY_TOKEN=your_ntfy_token_here
NATS_JWT=your_nats_jwt
NATS_NKEY=your_nats_nkey
JWT_SECRET=your_jwt_secret
WEB_HASH_SALT=your_hash_salt
PORT=8080

# Fly.io specific (optional)
FLY_APP_NAME=your-app-name
FLY_REGION=iad
PRIMARY_REGION=iad
```

## Service Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Machine       │    │   NATS Event    │    │   Error Logger  │
│   Events        │    │   Notifier      │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                    ┌─────────────────┐
                    │   NTFY Service  │
                    │   (Core)        │
                    └─────────────────┘
                                 │
                    ┌─────────────────┐
                    │   ntfy.sh       │
                    │   (Push)        │
                    └─────────────────┘
```

## 1. Machine Event Notifier

### Purpose
Monitors and notifies on machine lifecycle events in cloud environments (Fly.io, AWS, GCP, etc.).

### Events Supported
- **Startup**: Machine starting up
- **Shutdown**: Machine shutting down
- **Restart**: Machine restarting
- **Scale Up/Down**: Auto-scaling events
- **Health Check**: Health status changes
- **Error**: Machine errors

### Usage Examples

#### Machine Startup
```go
machineEvent := ntfy.MachineEvent{
    ID:        "machine-startup-123",
    MachineID: "fly-app-456",
    EventType: ntfy.MachineEventStartup,
    Status:    ntfy.MachineStatusStarting,
    Region:    "iad",
    AppName:   "my-app",
    UserID:    "user123",
    Metadata: map[string]interface{}{
        "instance_type": "shared-cpu-1x",
        "memory":        "256 MB",
        "reason":        "deployment",
    },
}

// Publish to machine events
eventData, _ := json.Marshal(machineEvent)
nc.Publish("machine.startup", eventData)
```

#### Machine Health Check
```go
healthEvent := ntfy.MachineEvent{
    ID:        "health-check-123",
    MachineID: "fly-app-456",
    EventType: ntfy.MachineEventHealthCheck,
    Status:    ntfy.MachineStatusUnhealthy,
    Region:    "iad",
    AppName:   "my-app",
    Metadata: map[string]interface{}{
        "health_check": "http",
        "endpoint":     "/health",
        "response_time": 5000,
        "status_code":  500,
    },
}

nc.Publish("machine.health", eventData)
```

### NATS Subjects
- `machine.startup` - Machine startup events
- `machine.shutdown` - Machine shutdown events
- `machine.restart` - Machine restart events
- `machine.scale` - Machine scaling events
- `machine.health` - Machine health events
- `machine.error` - Machine error events
- `machine.*` - All machine events (wildcard)

## 2. NATS Event Notifier

### Purpose
Monitors NATS connection status and automatically notifies on connection changes.

### Events Supported
- **Connect**: Initial connection established
- **Disconnect**: Connection lost
- **Reconnect**: Connection restored
- **Close**: Connection permanently closed
- **Error**: Connection or subscription errors
- **Status Change**: Connection status changes

### Automatic Monitoring
The service automatically sets up NATS connection event handlers:
- `SetDisconnectHandler`
- `SetReconnectHandler`
- `SetClosedHandler`
- `SetErrorHandler`

### Usage Examples

#### Manual NATS Event
```go
natsEvent := ntfy.NATSEvent{
    ID:        "nats-connect-123",
    EventType: ntfy.NATSEventConnect,
    Status:    ntfy.NATSStatusConnected,
    Server:    "tls://connect.ngs.global",
    Region:    "iad",
    AppName:   "my-app",
    Metadata: map[string]interface{}{
        "connection_id": "conn-456",
        "reconnects":    0,
    },
}

nc.Publish("nats.connect", eventData)
```

### NATS Subjects
- `nats.connect` - Connection established
- `nats.disconnect` - Connection lost
- `nats.reconnect` - Connection restored
- `nats.close` - Connection closed
- `nats.error` - Connection errors
- `nats.*` - All NATS events (wildcard)

## 3. Error Logger

### Purpose
Centralized error logging with automatic notifications for critical errors.

### Error Levels
- **Debug**: Low priority, no notifications
- **Info**: Low priority, no notifications
- **Warning**: Normal priority, optional notifications
- **Error**: High priority, automatic notifications
- **Fatal**: Urgent priority, automatic notifications

### Usage Examples

#### Log Error
```go
errorLog := ntfy.ErrorLog{
    ID:        "error-123",
    Level:     ntfy.ErrorLevelError,
    Message:   "Database connection failed",
    Error:     "connection timeout after 30 seconds",
    Service:   "user-service",
    Component: "database",
    UserID:    "user123",
    RequestID: "req-789",
    Metadata: map[string]interface{}{
        "database_host": "db.example.com",
        "retry_count":   3,
        "timeout":       30,
    },
}

nc.Publish("error.log", errorData)
```

#### Log Fatal Error
```go
fatalError := ntfy.ErrorLog{
    ID:        "fatal-123",
    Level:     ntfy.ErrorLevelFatal,
    Message:   "Critical system failure",
    Error:     "out of memory: cannot allocate 1GB",
    Service:   "system-service",
    Component: "memory-manager",
    Metadata: map[string]interface{}{
        "memory_usage": "95%",
        "available_mb": 512,
        "process_count": 150,
    },
}

nc.Publish("error.fatal", errorData)
```

### NATS Subjects
- `error.log` - Error level logs
- `error.warning` - Warning level logs
- `error.fatal` - Fatal level logs
- `error.custom` - Custom error logs
- `error.*` - All error logs (wildcard)

## 4. Notification Topics

### Default Topics
- **Machine Events**: `machine-events`
- **NATS Events**: `nats-events`
- **Error Logs**: `error-logs`

### Custom Topics
Users can set custom topics in their preferences:
```go
notification := ntfy.Notification{
    ID:        "custom-123",
    UserID:    "user123",
    Title:     "Custom Alert",
    Message:   "Custom message",
    Category:  "custom",
    Priority:  ntfy.PriorityHigh,
    NtfyTopic: "my-custom-topic", // User's custom topic
    Data:      map[string]interface{}{},
}
```

## 5. Priority Levels

### Priority Mapping
- **Low (1)**: Debug, info, normal operations
- **Normal (3)**: Warnings, routine events
- **High (4)**: Errors, important events
- **Urgent (5)**: Fatal errors, critical events

### Priority Determination
- **Machine Events**: Based on event type and status
- **NATS Events**: Based on event type
- **Error Logs**: Based on error level

## 6. Integration with Existing Services

### In Main Server
```go
// Initialize ntfy service
ntfyService, err := ntfy.New(ctx, nc, logger)
if err != nil {
    return fmt.Errorf("new ntfy: %w", err)
}

// Start machine event notifier
machineEventNotifier := ntfy.NewMachineEventNotifier(&ntfyService, nc, logger)
err = machineEventNotifier.Start(ctx)

// Start NATS event notifier
natsEventNotifier := ntfy.NewNATSEventNotifier(&ntfyService, nc, logger, appName, region)
err = natsEventNotifier.Start(ctx)

// Start error logger
errorLogger := ntfy.NewErrorLogger(&ntfyService, nc, logger, appName, region)
err = errorLogger.Start(ctx)
```

### In Other Services
```go
// Use error logger in any service
func (s *MyService) handleRequest() error {
    if err := s.processRequest(); err != nil {
        // Log error with notification
        s.errorLogger.LogError(
            "my-service",
            "request-handler",
            "Failed to process request",
            err.Error(),
            map[string]interface{}{
                "user_id": "user123",
                "request_id": "req-456",
            },
        )
        return err
    }
    return nil
}
```

## 7. Monitoring and Debugging

### Service Status
Check service status via NATS microservice discovery:
```bash
# List all services
nats micro list

# Check specific service
nats micro info ntfy
nats micro info machine-events
nats micro info nats-events
nats micro info error-logger
```

### Log Monitoring
Monitor notifications in real-time:
```bash
# Subscribe to ntfy.sh topics
ntfy subscribe machine-events
ntfy subscribe nats-events
ntfy subscribe error-logs

# Or use web interface
# https://ntfy.sh/machine-events
# https://ntfy.sh/nats-events
# https://ntfy.sh/error-logs
```

### Debug Mode
Enable debug logging for troubleshooting:
```bash
# Set log level to debug
./server -log=debug
```

## 8. Testing

### Test Notifications
Use the examples in `examples.go`:
```go
// Run all examples
ntfy.ExampleUsage(nc)

// Or run specific examples
exampleMachineStartup(nc)
exampleNATSEvent(nc)
exampleErrorLogging(nc)
```

### Test Endpoints
Test microservice endpoints:
```bash
# Test machine startup
echo '{"machine_id":"test-123","region":"test"}' | nats request machine.startup

# Test error logging
echo '{"service":"test","component":"test","message":"test error"}' | nats request error.log

# Test NATS event
echo '{"server":"test","region":"test"}' | nats request nats.connect
```

## 9. Production Considerations

### Scaling
- Multiple service instances can run simultaneously
- NATS handles load balancing automatically
- Each instance processes events independently

### Reliability
- Notifications are sent via NATS (reliable)
- ntfy.sh handles delivery retries
- Failed notifications are logged

### Security
- User isolation through user_id filtering
- Channel-specific credentials
- Rate limiting per user/channel

### Monitoring
- Track notification delivery through acknowledgments
- Monitor service health via NATS microservices
- Set up alerts for service failures

## 10. Troubleshooting

### Common Issues

#### Service Not Starting
- Check NATS connection
- Verify environment variables
- Check service logs

#### Notifications Not Delivered
- Verify ntfy.sh topic subscription
- Check ntfy.sh server status
- Verify NTFY_TOKEN configuration

#### High Memory Usage
- Check subscription limits
- Monitor pending message counts
- Adjust buffer sizes if needed

### Debug Commands
```bash
# Check NATS connection
nats server check

# Monitor subjects
nats sub ">" --count 100

# Check service status
nats micro list
nats micro info ntfy
```

## 11. Advanced Configuration

### Custom ntfy.sh Server
```go
// Use custom server
ntfyService, err := ntfy.NewWithConfig(ctx, nc, logger, "https://ntfy.yourdomain.com", "your-token")
```

### Custom Notification Topics
```go
// Set custom topics per service
machineEventNotifier.SetDefaultTopic("my-machine-events")
natsEventNotifier.SetDefaultTopic("my-nats-events")
errorLogger.SetDefaultTopic("my-error-logs")
```

### Custom Priority Mapping
```go
// Override priority determination
machineEventNotifier.SetPriorityMapper(customPriorityMapper)
```

## 12. Migration from Existing System

### Step-by-Step Migration
1. **Deploy new services** alongside existing system
2. **Test notifications** with new services
3. **Gradually migrate** event publishing to new subjects
4. **Monitor** notification delivery
5. **Remove** old notification code
6. **Clean up** old subjects and handlers

### Backward Compatibility
- Old notification endpoints remain functional
- New services can handle old event formats
- Gradual migration supported

## Support

For issues or questions:
- Check service logs
- Monitor NATS microservice status
- Review notification delivery in ntfy.sh
- Check environment variable configuration