package ntfy

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/nats-io/nats.go"
)

// ExampleUsage demonstrates how to use the ntfy services
func ExampleUsage(nc *nats.Conn) {
	// Example 1: Machine startup notification
	exampleMachineStartup(nc)

	// Example 2: NATS connection event
	exampleNATSEvent(nc)

	// Example 3: Error logging
	exampleErrorLogging(nc)

	// Example 4: Custom notification
	exampleCustomNotification(nc)
}

// Example 1: Machine startup notification
func exampleMachineStartup(nc *nats.Conn) {
	machineEvent := MachineEvent{
		ID:        fmt.Sprintf("machine-startup-%d", time.Now().UnixNano()),
		MachineID: "fly-app-123",
		EventType: MachineEventStartup,
		Status:    MachineStatusStarting,
		Region:    "iad",
		AppName:   "my-app",
		Timestamp: time.Now(),
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

	// Or use the wildcard subscription
	nc.Publish("machine.*", eventData)
}

// Example 2: NATS connection event
func exampleNATSEvent(nc *nats.Conn) {
	natsEvent := NATSEvent{
		ID:        fmt.Sprintf("nats-connect-%d", time.Now().UnixNano()),
		EventType: NATSEventConnect,
		Status:    NATSStatusConnected,
		Server:    "tls://connect.ngs.global",
		Region:    "iad",
		AppName:   "my-app",
		Timestamp: time.Now(),
		Metadata: map[string]interface{}{
			"connection_id": "conn-456",
			"reconnects":    0,
		},
	}

	// Publish to NATS events
	eventData, _ := json.Marshal(natsEvent)
	nc.Publish("nats.connect", eventData)

	// Or use the wildcard subscription
	nc.Publish("nats.*", eventData)
}

// Example 3: Error logging
func exampleErrorLogging(nc *nats.Conn) {
	errorLog := ErrorLog{
		ID:        fmt.Sprintf("error-%d", time.Now().UnixNano()),
		Level:     ErrorLevelError,
		Message:   "Database connection failed",
		Error:     "connection timeout after 30 seconds",
		Service:   "user-service",
		Component: "database",
		UserID:    "user123",
		RequestID: "req-789",
		Timestamp: time.Now(),
		Metadata: map[string]interface{}{
			"database_host": "db.example.com",
			"retry_count":   3,
			"timeout":       30,
		},
	}

	// Publish to error events
	errorData, _ := json.Marshal(errorLog)
	nc.Publish("error.log", errorData)

	// Or use the wildcard subscription
	nc.Publish("error.*", errorData)
}

// Example 4: Custom notification
func exampleCustomNotification(nc *nats.Conn) {
	notification := Notification{
		ID:        fmt.Sprintf("custom-%d", time.Now().UnixNano()),
		UserID:    "user123",
		Title:     "Custom Alert",
		Message:   "This is a custom notification message",
		Category:  "custom",
		Priority:  PriorityHigh,
		NtfyTopic: "my-custom-topic",
		Data: map[string]interface{}{
			"source":    "example-service",
			"timestamp": time.Now(),
			"metadata":  "additional information",
		},
		CreatedAt: time.Now(),
	}

	// Send directly to ntfy service
	notificationData, _ := json.Marshal(notification)
	nc.Publish(SubjectNotification, notificationData)
}

// Example 5: Machine health check
func exampleMachineHealth(nc *nats.Conn) {
	healthEvent := MachineEvent{
		ID:        fmt.Sprintf("health-%d", time.Now().UnixNano()),
		MachineID: "fly-app-123",
		EventType: MachineEventHealthCheck,
		Status:    MachineStatusUnhealthy,
		Region:    "iad",
		AppName:   "my-app",
		Timestamp: time.Now(),
		Metadata: map[string]interface{}{
			"health_check": "http",
			"endpoint":     "/health",
			"response_time": 5000,
			"status_code":  500,
		},
	}

	// Publish to machine health events
	eventData, _ := json.Marshal(healthEvent)
	nc.Publish("machine.health", eventData)
}

// Example 6: Machine scaling event
func exampleMachineScaling(nc *nats.Conn) {
	scaleEvent := MachineEvent{
		ID:        fmt.Sprintf("scale-%d", time.Now().UnixNano()),
		MachineID: "fly-app-123",
		EventType: MachineEventScaleUp,
		Status:    MachineStatusRunning,
		Region:    "iad",
		AppName:   "my-app",
		Timestamp: time.Now(),
		Metadata: map[string]interface{}{
			"direction":     "up",
			"old_count":     2,
			"new_count":     3,
			"reason":        "high_cpu_usage",
			"trigger_value": 85.5,
		},
	}

	// Publish to machine scale events
	eventData, _ := json.Marshal(scaleEvent)
	nc.Publish("machine.scale", eventData)
}

// Example 7: Fatal error logging
func exampleFatalError(nc *nats.Conn) {
	fatalError := ErrorLog{
		ID:        fmt.Sprintf("fatal-%d", time.Now().UnixNano()),
		Level:     ErrorLevelFatal,
		Message:   "Critical system failure",
		Error:     "out of memory: cannot allocate 1GB",
		Service:   "system-service",
		Component: "memory-manager",
		Timestamp: time.Now(),
		Metadata: map[string]interface{}{
			"memory_usage": "95%",
			"available_mb": 512,
			"process_count": 150,
		},
	}

	// Publish to fatal error events
	errorData, _ := json.Marshal(fatalError)
	nc.Publish("error.fatal", errorData)
}

// Example 8: NATS error event
func exampleNATSError(nc *nats.Conn) {
	natsError := NATSEvent{
		ID:        fmt.Sprintf("nats-error-%d", time.Now().UnixNano()),
		EventType: NATSEventError,
		Status:    NATSStatusError,
		Server:    "tls://connect.ngs.global",
		Region:    "iad",
		AppName:   "my-app",
		Timestamp: time.Now(),
		Error:     "subscription timeout",
		Metadata: map[string]interface{}{
			"connection_id": "conn-456",
			"subject":       "user.events",
			"queue":         "user-workers",
		},
	}

	// Publish to NATS error events
	eventData, _ := json.Marshal(natsError)
	nc.Publish("nats.error", eventData)
}

// Example 9: Machine shutdown event
func exampleMachineShutdown(nc *nats.Conn) {
	shutdownEvent := MachineEvent{
		ID:        fmt.Sprintf("shutdown-%d", time.Now().UnixNano()),
		MachineID: "fly-app-123",
		EventType: MachineEventShutdown,
		Status:    MachineStatusStopping,
		Region:    "iad",
		AppName:   "my-app",
		Timestamp: time.Now(),
		Metadata: map[string]interface{}{
			"reason":        "maintenance",
			"duration_min":  15,
			"affected_users": 0,
		},
	}

	// Publish to machine shutdown events
	eventData, _ := json.Marshal(shutdownEvent)
	nc.Publish("machine.shutdown", eventData)
}

// Example 10: Warning log
func exampleWarningLog(nc *nats.Conn) {
	warningLog := ErrorLog{
		ID:        fmt.Sprintf("warning-%d", time.Now().UnixNano()),
		Level:     ErrorLevelWarning,
		Message:   "High memory usage detected",
		Service:   "monitoring-service",
		Component: "memory-monitor",
		Timestamp: time.Now(),
		Metadata: map[string]interface{}{
			"memory_usage": "85%",
			"threshold":    "80%",
			"action":       "monitor_closely",
		},
	}

	// Publish to warning events
	errorData, _ := json.Marshal(warningLog)
	nc.Publish("error.warning", errorData)
}