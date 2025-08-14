# NATS Connection Handling

This document describes how the server handles NATS connection failures and connection loss scenarios.

## Initial Connection Behavior

### Panic on Initial Connection Failure

The server will **panic** if it cannot establish an initial connection to the NATS cluster. This is intentional because:

1. **Core Dependency**: NATS is a core infrastructure component that the server cannot function without
2. **Fail Fast**: Better to fail immediately than to start in a broken state
3. **Operational Clarity**: Clear indication that the server environment is not properly configured

```go
if err != nil {
    // Panic on initial connection failure - server cannot function without NATS
    l.Fatal("Failed to connect to NATS cluster: %v", err)
    panic(fmt.Sprintf("Failed to connect to NATS cluster: %v", err))
}

// Verify connection is established
if nc.Status() != nats.CONNECTED {
    l.Fatal("NATS connection not in CONNECTED state: %s", nc.Status())
    panic(fmt.Sprintf("NATS connection not in CONNECTED state: %s", nc.Status()))
}
```

### Connection Verification

After connection establishment, the server verifies the connection is in the `CONNECTED` state before proceeding. This ensures the NATS client is fully ready for operations.

## Connection Loss Handling

### During Operation

Once the server is running and the initial connection is established, the server handles connection loss gracefully:

1. **No Panic**: The server continues running even if the NATS connection is lost
2. **Automatic Reconnection**: NATS client automatically attempts to reconnect
3. **Status Monitoring**: Background goroutine monitors connection status every 5 seconds
4. **Graceful Degradation**: Services become unavailable but the server remains operational

### Connection Event Handlers

The server registers several connection event handlers:

```go
nats.DisconnectHandler(func(nc *nats.Conn) {
    l.Error("NATS connection disconnected")
}),
nats.ReconnectHandler(func(nc *nats.Conn) {
    l.Info("NATS connection reconnected")
}),
nats.ClosedHandler(func(nc *nats.Conn) {
    l.Error("NATS connection closed")
}),
nats.ErrorHandler(func(nc *nats.Conn, sub *nats.Subscription, err error) {
    l.Error("NATS error: %v", err)
}),
```

### Connection Resilience Options

The server configures NATS with resilience options:

```go
nats.MaxReconnects(-1),                    // Unlimited reconnection attempts
nats.ReconnectWait(1*time.Second),         // Wait 1 second between attempts
nats.ReconnectJitter(100*time.Millisecond, 1*time.Second), // Add jitter
nats.Timeout(10*time.Second),              // Connection timeout
nats.PingInterval(30*time.Second),         // Send ping every 30 seconds
nats.MaxPingsOutstanding(3),               // Allow 3 missed pings
```

### Built-in NATS Monitoring

NATS provides built-in connection monitoring and event handling. The server relies on these mechanisms:

- **Automatic Status Tracking**: NATS client internally tracks connection status
- **Event Handlers**: Connection events are automatically triggered and logged
- **Reconnection Logic**: NATS handles reconnection attempts automatically
- **Health Checks**: Built-in ping/pong mechanism detects connection issues

No additional monitoring goroutine is needed as NATS handles all connection state management internally.

## Service Behavior During Connection Loss

### Microservices
- **who**, **urlShort**, **ntfy** services check connection status on startup
- If connection is lost, these services will log errors but continue running
- NATS microservice endpoints become unavailable until reconnection

### WebSocket Connections
- Existing WebSocket connections remain open
- New subscriptions and commands will fail until NATS reconnects
- Clients receive error messages for failed operations

### Logging
- Logger continues to function (messages are queued when NATS is unavailable)
- Queued messages are published once NATS reconnects

## Recovery Scenarios

### Automatic Recovery
1. **Network Issues**: NATS client automatically reconnects when network is restored
2. **Server Restart**: NATS client reconnects when NATS server comes back online
3. **Temporary Outages**: Services resume normal operation after reconnection

### Manual Recovery
1. **Configuration Issues**: Fix NATS configuration and restart server
2. **Authentication Issues**: Verify JWT and NKEY credentials
3. **Network Configuration**: Check firewall and DNS settings

## Operational Recommendations

### Monitoring
- Monitor NATS connection status in logs
- Set up alerts for connection loss events
- Track reconnection frequency and success rate

### Deployment
- Ensure NATS cluster is available before deploying the server
- Use health checks to verify NATS connectivity
- Consider using embedded NATS for development/testing

### Troubleshooting
- Check NATS server logs for connection issues
- Verify network connectivity to NATS endpoints
- Validate authentication credentials
- Review NATS server configuration

## Error Messages

### Initial Connection Failures
```
FATAL Failed to connect to NATS cluster: dial tcp: lookup connect.ngs.global: i/o timeout
panic: Failed to connect to NATS cluster: dial tcp: lookup connect.ngs.global: i/o timeout
```

### Connection Status Changes
```
ERROR NATS connection disconnected
ERROR NATS connection status changed to: DISCONNECTED
ERROR NATS connection permanently closed - server will continue but messaging will be unavailable
```

### Recovery Events
```
INFO NATS connection reconnected
INFO Successfully connected to NATS cluster
```

## Summary

- **Initial Failure**: Server panics if it cannot connect to NATS (fail-fast behavior)
- **Connection Loss**: Server continues running, NATS client attempts automatic reconnection
- **Graceful Degradation**: Services become unavailable but server remains operational
- **Automatic Recovery**: Full functionality restored when NATS reconnects
- **Built-in Monitoring**: NATS handles all connection state management and event handling internally

This approach ensures the server fails fast on configuration issues while providing resilience during operational network problems, leveraging NATS's robust built-in connection management capabilities.
