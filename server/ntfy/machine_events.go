package ntfy

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/micro"
)

// MachineEvent represents a machine lifecycle event
type MachineEvent struct {
	ID          string                 `json:"id"`
	MachineID   string                 `json:"machine_id"`
	EventType   MachineEventType       `json:"event_type"`
	Status      MachineStatus          `json:"status"`
	Region      string                 `json:"region"`
	AppName     string                 `json:"app_name"`
	Timestamp   time.Time              `json:"timestamp"`
	Metadata    map[string]interface{} `json:"metadata,omitempty"`
	UserID      string                 `json:"user_id,omitempty"` // Owner/operator
	Priority    Priority               `json:"priority"`
	Category    string                 `json:"category"`
}

type MachineEventType string

const (
	MachineEventStartup     MachineEventType = "startup"
	MachineEventShutdown    MachineEventType = "shutdown"
	MachineEventRestart     MachineEventType = "restart"
	MachineEventScaleUp     MachineEventType = "scale_up"
	MachineEventScaleDown   MachineEventType = "scale_down"
	MachineEventHealthCheck MachineEventType = "health_check"
	MachineEventError       MachineEventType = "error"
)

type MachineStatus string

const (
	MachineStatusStarting MachineStatus = "starting"
	MachineStatusRunning  MachineStatus = "running"
	MachineStatusStopping MachineStatus = "stopping"
	MachineStatusStopped  MachineStatus = "stopped"
	MachineStatusError    MachineStatus = "error"
	MachineStatusHealthy  MachineStatus = "healthy"
	MachineStatusUnhealthy MachineStatus = "unhealthy"
)

// MachineEventNotifier handles machine lifecycle notifications
type MachineEventNotifier struct {
	ntfy    *Ntfy
	nc      *nats.Conn
	l       *jst_log.Logger
	svc     micro.Service
}

// NewMachineEventNotifier creates a new machine event notifier
func NewMachineEventNotifier(ntfy *Ntfy, nc *nats.Conn, l *jst_log.Logger) *MachineEventNotifier {
	return &MachineEventNotifier{
		ntfy: ntfy,
		nc:   nc,
		l:    l,
	}
}

// Start initializes the machine event notification service
func (m *MachineEventNotifier) Start(ctx context.Context) error {
	svcMetadata := map[string]string{
		"service":     "machine-events",
		"version":     "1.0.0",
		"description": "Machine lifecycle event notifications",
	}

	svc, err := micro.AddService(m.nc, micro.Config{
		Name:        "machine-events",
		Version:     "1.0.0",
		Description: "Machine lifecycle event notification service",
		Metadata:    svcMetadata,
	})
	if err != nil {
		return fmt.Errorf("add machine events service: %w", err)
	}

	m.svc = svc

	// Add endpoints for different event types
	endpoints := []struct {
		name    string
		subject string
		handler micro.HandlerFunc
	}{
		{"machine_startup", "machine.startup", m.handleMachineStartup},
		{"machine_shutdown", "machine.shutdown", m.handleMachineShutdown},
		{"machine_restart", "machine.restart", m.handleMachineRestart},
		{"machine_scale", "machine.scale", m.handleMachineScale},
		{"machine_health", "machine.health", m.handleMachineHealth},
		{"machine_error", "machine.error", m.handleMachineError},
	}

	for _, endpoint := range endpoints {
		if err := svc.AddEndpoint(endpoint.name, endpoint.handler, 
			micro.WithEndpointSubject(endpoint.subject)); err != nil {
			return fmt.Errorf("add endpoint %s: %w", endpoint.name, err)
		}
	}

	// Subscribe to machine events for automatic notifications
	if err := m.subscribeToMachineEvents(); err != nil {
		return fmt.Errorf("subscribe to machine events: %w", err)
	}

	m.l.Info("machine event notifier started")
	return nil
}

// Subscribe to machine events for automatic notifications
func (m *MachineEventNotifier) subscribeToMachineEvents() error {
	// Subscribe to all machine events
	sub, err := m.nc.Subscribe("machine.*", func(msg *nats.Msg) {
		var event MachineEvent
		if err := json.Unmarshal(msg.Data, &event); err != nil {
			m.l.Error("failed to unmarshal machine event", "error", err)
			return
		}

		// Set defaults
		if event.Timestamp.IsZero() {
			event.Timestamp = time.Now()
		}
		if event.Category == "" {
			event.Category = "machine"
		}
		if event.Priority == "" {
			event.Priority = m.determinePriority(event.EventType, event.Status)
		}

		// Send notification
		if err := m.sendMachineEventNotification(event); err != nil {
			m.l.Error("failed to send machine event notification", "error", err, "event_id", event.ID)
		}
	})
	if err != nil {
		return fmt.Errorf("subscribe to machine events: %w", err)
	}

	// Set subscription options
	sub.SetPendingLimits(1000, 100*1024*1024) // 1000 messages, 100MB

	return nil
}

// Determine priority based on event type and status
func (m *MachineEventNotifier) determinePriority(eventType MachineEventType, status MachineStatus) Priority {
	switch {
	case status == MachineStatusError || eventType == MachineEventError:
		return PriorityUrgent
	case eventType == MachineEventStartup || eventType == MachineEventShutdown:
		return PriorityHigh
	case eventType == MachineEventHealthCheck && status == MachineStatusUnhealthy:
		return PriorityHigh
	case eventType == MachineEventScaleUp || eventType == MachineEventScaleDown:
		return PriorityNormal
	default:
		return PriorityLow
	}
}

// Send machine event notification
func (m *MachineEventNotifier) sendMachineEventNotification(event MachineEvent) error {
	// Create notification title and message
	title := fmt.Sprintf("Machine %s: %s", event.EventType, event.Status)
	message := fmt.Sprintf("Machine %s in %s region has %s status", 
		event.MachineID, event.Region, event.Status)

	// Add metadata to message if available
	if len(event.Metadata) > 0 {
		if appName, ok := event.Metadata["app_name"].(string); ok {
			message += fmt.Sprintf(" (App: %s)", appName)
		}
		if reason, ok := event.Metadata["reason"].(string); ok {
			message += fmt.Sprintf(" - %s", reason)
		}
	}

	notification := Notification{
		ID:        event.ID,
		UserID:    event.UserID,
		Title:     title,
		Message:   message,
		Category:  event.Category,
		Priority:  event.Priority,
		NtfyTopic: "machine-events", // Default topic for machine events
		Data: map[string]interface{}{
			"machine_id": event.MachineID,
			"event_type": event.EventType,
			"status":     event.Status,
			"region":     event.Region,
			"app_name":   event.AppName,
			"timestamp":  event.Timestamp,
			"metadata":   event.Metadata,
		},
		CreatedAt: event.Timestamp,
	}

	// Send via NATS to the ntfy service
	notificationData, err := json.Marshal(notification)
	if err != nil {
		return fmt.Errorf("marshal notification: %w", err)
	}

	// Publish to ntfy service
	return m.nc.Publish(SubjectNotification, notificationData)
}

// Handler functions for different machine events
func (m *MachineEventNotifier) handleMachineStartup() micro.HandlerFunc {
	return func(req micro.Request) {
		var event MachineEvent
		if err := json.Unmarshal(req.Data(), &event); err != nil {
			m.l.Error("failed to unmarshal startup event", "error", err)
			req.Error("400", "invalid startup event", nil)
			return
		}

		event.EventType = MachineEventStartup
		event.Status = MachineStatusStarting
		event.Category = "machine"
		event.Priority = PriorityHigh

		if err := m.sendMachineEventNotification(event); err != nil {
			m.l.Error("failed to send startup notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("startup notification sent"))
	}
}

func (m *MachineEventNotifier) handleMachineShutdown() micro.HandlerFunc {
	return func(req micro.Request) {
		var event MachineEvent
		if err := json.Unmarshal(req.Data(), &event); err != nil {
			m.l.Error("failed to unmarshal shutdown event", "error", err)
			req.Error("400", "invalid shutdown event", nil)
			return
		}

		event.EventType = MachineEventShutdown
		event.Status = MachineStatusStopping
		event.Category = "machine"
		event.Priority = PriorityHigh

		if err := m.sendMachineEventNotification(event); err != nil {
			m.l.Error("failed to send shutdown notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("shutdown notification sent"))
	}
}

func (m *MachineEventNotifier) handleMachineRestart() micro.HandlerFunc {
	return func(req micro.Request) {
		var event MachineEvent
		if err := json.Unmarshal(req.Data(), &event); err != nil {
			m.l.Error("failed to unmarshal restart event", "error", err)
			req.Error("400", "invalid restart event", nil)
			return
		}

		event.EventType = MachineEventRestart
		event.Status = MachineStatusStarting
		event.Category = "machine"
		event.Priority = PriorityNormal

		if err := m.sendMachineEventNotification(event); err != nil {
			m.l.Error("failed to send restart notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("restart notification sent"))
	}
}

func (m *MachineEventNotifier) handleMachineScale() micro.HandlerFunc {
	return func(req micro.Request) {
		var event MachineEvent
		if err := json.Unmarshal(req.Data(), &event); err != nil {
			m.l.Error("failed to unmarshal scale event", "error", err)
			req.Error("400", "invalid scale event", nil)
			return
		}

		// Determine if it's scale up or down based on metadata
		if direction, ok := event.Metadata["direction"].(string); ok {
			if direction == "up" {
				event.EventType = MachineEventScaleUp
			} else {
				event.EventType = MachineEventScaleDown
			}
		}
		event.Status = MachineStatusRunning
		event.Category = "machine"
		event.Priority = PriorityNormal

		if err := m.sendMachineEventNotification(event); err != nil {
			m.l.Error("failed to send scale notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("scale notification sent"))
	}
}

func (m *MachineEventNotifier) handleMachineHealth() micro.HandlerFunc {
	return func(req micro.Request) {
		var event MachineEvent
		if err := json.Unmarshal(req.Data(), &event); err != nil {
			m.l.Error("failed to unmarshal health event", "error", err)
			req.Error("400", "invalid health event", nil)
			return
		}

		event.EventType = MachineEventHealthCheck
		event.Category = "machine"
		
		// Set priority based on health status
		if event.Status == MachineStatusUnhealthy {
			event.Priority = PriorityHigh
		} else {
			event.Priority = PriorityLow
		}

		if err := m.sendMachineEventNotification(event); err != nil {
			m.l.Error("failed to send health notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("health notification sent"))
	}
}

func (m *MachineEventNotifier) handleMachineError() micro.HandlerFunc {
	return func(req micro.Request) {
		var event MachineEvent
		if err := json.Unmarshal(req.Data(), &event); err != nil {
			m.l.Error("failed to unmarshal error event", "error", err)
			req.Error("400", "invalid error event", nil)
			return
		}

		event.EventType = MachineEventError
		event.Status = MachineStatusError
		event.Category = "machine"
		event.Priority = PriorityUrgent

		if err := m.sendMachineEventNotification(event); err != nil {
			m.l.Error("failed to send error notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("error notification sent"))
	}
}

// Shutdown gracefully shuts down the service
func (m *MachineEventNotifier) Shutdown() {
	if m.svc != nil {
		m.svc.Stop()
	}
}