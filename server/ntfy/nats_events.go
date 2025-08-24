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

// NATSEvent represents a NATS connection or system event
type NATSEvent struct {
	ID          string                 `json:"id"`
	EventType   NATSEventType          `json:"event_type"`
	Status      NATSConnectionStatus   `json:"status"`
	Server      string                 `json:"server"`
	Region      string                 `json:"region"`
	AppName     string                 `json:"app_name"`
	Timestamp   time.Time              `json:"timestamp"`
	Error       string                 `json:"error,omitempty"`
	Metadata    map[string]interface{} `json:"metadata,omitempty"`
	UserID      string                 `json:"user_id,omitempty"`
	Priority    Priority               `json:"priority"`
	Category    string                 `json:"category"`
	ReconnectAttempts int              `json:"reconnect_attempts,omitempty"`
}

type NATSEventType string

const (
	NATSEventConnect     NATSEventType = "connect"
	NATSEventDisconnect NATSEventType = "disconnect"
	NATSEventReconnect  NATSEventType = "reconnect"
	NATSEventClose      NATSEventType = "close"
	NATSEventError      NATSEventType = "error"
	NATSEventLameDuck   NATSEventType = "lame_duck"
	NATSEventServerInfo NATSEventType = "server_info"
)

type NATSConnectionStatus string

const (
	NATSStatusConnected    NATSConnectionStatus = "connected"
	NATSStatusDisconnected NATSConnectionStatus = "disconnected"
	NATSStatusReconnecting NATSConnectionStatus = "reconnecting"
	NATSStatusClosed       NATSConnectionStatus = "closed"
	NATSStatusError        NATSConnectionStatus = "error"
)

// NATSEventNotifier handles NATS connection event notifications
type NATSEventNotifier struct {
	ntfy    *Ntfy
	nc      *nats.Conn
	l       *jst_log.Logger
	svc     micro.Service
	appName string
	region  string
}

// NewNATSEventNotifier creates a new NATS event notifier
func NewNATSEventNotifier(ntfy *Ntfy, nc *nats.Conn, l *jst_log.Logger, appName, region string) *NATSEventNotifier {
	return &NATSEventNotifier{
		ntfy:    ntfy,
		nc:      nc,
		l:       l,
		appName: appName,
		region:  region,
	}
}

// Start initializes the NATS event notification service
func (n *NATSEventNotifier) Start(ctx context.Context) error {
	svcMetadata := map[string]string{
		"service":     "nats-events",
		"version":     "1.0.0",
		"description": "NATS connection event notifications",
	}

	svc, err := micro.AddService(n.nc, micro.Config{
		Name:        "nats-events",
		Version:     "1.0.0",
		Description: "NATS connection event notification service",
		Metadata:    svcMetadata,
	})
	if err != nil {
		return fmt.Errorf("add NATS events service: %w", err)
	}

	n.svc = svc

	// Add endpoints for different event types
	endpoints := []struct {
		name    string
		subject string
		handler micro.HandlerFunc
	}{
		{"nats_connect", "nats.connect", n.handleNATSConnect},
		{"nats_disconnect", "nats.disconnect", n.handleNATSDisconnect},
		{"nats_reconnect", "nats.reconnect", n.handleNATSReconnect},
		{"nats_close", "nats.close", n.handleNATSClose},
		{"nats_error", "nats.error", n.handleNATSError},
	}

	for _, endpoint := range endpoints {
		if err := svc.AddEndpoint(endpoint.name, endpoint.handler, 
			micro.WithEndpointSubject(endpoint.subject)); err != nil {
			return fmt.Errorf("add endpoint %s: %w", endpoint.name, err)
		}
	}

	// Set up NATS connection event handlers
	if err := n.setupNATSEventHandlers(); err != nil {
		return fmt.Errorf("setup NATS event handlers: %w", err)
	}

	n.l.Info("NATS event notifier started")
	return nil
}

// Setup NATS connection event handlers
func (n *NATSEventNotifier) setupNATSEventHandlers() error {
	// Set connection event handlers
	n.nc.SetDisconnectHandler(func(nc *nats.Conn) {
		event := NATSEvent{
			ID:        fmt.Sprintf("nats-disconnect-%d", time.Now().UnixNano()),
			EventType: NATSEventDisconnect,
			Status:    NATSStatusDisconnected,
			Server:    nc.ConnectedUrl(),
			Region:    n.region,
			AppName:   n.appName,
			Timestamp: time.Now(),
			Category:  "nats",
			Priority:  PriorityHigh,
			Metadata: map[string]interface{}{
				"connection_id": nc.ConnectedServerId(),
				"last_error":    nc.LastError(),
			},
		}

		if err := n.sendNATSEventNotification(event); err != nil {
			n.l.Error("failed to send disconnect notification", "error", err)
		}
	})

	n.nc.SetReconnectHandler(func(nc *nats.Conn) {
		event := NATSEvent{
			ID:        fmt.Sprintf("nats-reconnect-%d", time.Now().UnixNano()),
			EventType: NATSEventReconnect,
			Status:    NATSStatusConnected,
			Server:    nc.ConnectedUrl(),
			Region:    n.region,
			AppName:   n.appName,
			Timestamp: time.Now(),
			Category:  "nats",
			Priority:  PriorityNormal,
			Metadata: map[string]interface{}{
				"connection_id": nc.ConnectedServerId(),
				"reconnect_count": nc.Reconnects(),
			},
		}

		if err := n.sendNATSEventNotification(event); err != nil {
			n.l.Error("failed to send reconnect notification", "error", err)
		}
	})

	n.nc.SetClosedHandler(func(nc *nats.Conn) {
		event := NATSEvent{
			ID:        fmt.Sprintf("nats-close-%d", time.Now().UnixNano()),
			EventType: NATSEventClose,
			Status:    NATSStatusClosed,
			Server:    nc.ConnectedUrl(),
			Region:    n.region,
			AppName:   n.appName,
			Timestamp: time.Now(),
			Category:  "nats",
			Priority:  PriorityUrgent,
			Metadata: map[string]interface{}{
				"connection_id": nc.ConnectedServerId(),
				"last_error":    nc.LastError(),
			},
		}

		if err := n.sendNATSEventNotification(event); err != nil {
			n.l.Error("failed to send close notification", "error", err)
		}
	})

	n.nc.SetErrorHandler(func(nc *nats.Conn, sub *nats.Subscription, err error) {
		event := NATSEvent{
			ID:        fmt.Sprintf("nats-error-%d", time.Now().UnixNano()),
			EventType: NATSEventError,
			Status:    NATSStatusError,
			Server:    nc.ConnectedUrl(),
			Region:    n.region,
			AppName:   n.appName,
			Timestamp: time.Now(),
			Error:     err.Error(),
			Category:  "nats",
			Priority:  PriorityUrgent,
			Metadata: map[string]interface{}{
				"connection_id": nc.ConnectedServerId(),
				"subscription":  sub != nil,
			},
		}

		if sub != nil {
			event.Metadata["subject"] = sub.Subject
			event.Metadata["queue"] = sub.Queue
		}

		if err := n.sendNATSEventNotification(event); err != nil {
			n.l.Error("failed to send error notification", "error", err)
		}
	})

	// Monitor connection status changes
	go n.monitorConnectionStatus(ctx)

	return nil
}

// Monitor connection status changes
func (n *NATSEventNotifier) monitorConnectionStatus(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second) // Check every 30 seconds
	defer ticker.Stop()

	lastStatus := n.nc.Status()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			currentStatus := n.nc.Status()
			if currentStatus != lastStatus {
				// Status changed, send notification
				event := NATSEvent{
					ID:        fmt.Sprintf("nats-status-%d", time.Now().UnixNano()),
					EventType: NATSEventServerInfo,
					Status:    NATSConnectionStatus(currentStatus.String()),
					Server:    n.nc.ConnectedUrl(),
					Region:    n.region,
					AppName:   n.appName,
					Timestamp: time.Now(),
					Category:  "nats",
					Priority:  PriorityNormal,
					Metadata: map[string]interface{}{
						"previous_status": lastStatus.String(),
						"current_status":  currentStatus.String(),
						"connection_id":   n.nc.ConnectedServerId(),
						"reconnects":      n.nc.Reconnects(),
					},
				}

				if err := n.sendNATSEventNotification(event); err != nil {
					n.l.Error("failed to send status change notification", "error", err)
				}

				lastStatus = currentStatus
			}
		}
	}
}

// Send NATS event notification
func (n *NATSEventNotifier) sendNATSEventNotification(event NATSEvent) error {
	// Create notification title and message
	title := fmt.Sprintf("NATS %s: %s", event.EventType, event.Status)
	message := fmt.Sprintf("NATS connection %s in %s region has %s status", 
		event.Server, event.Region, event.Status)

	// Add error information if available
	if event.Error != "" {
		message += fmt.Sprintf(" - Error: %s", event.Error)
	}

	// Add metadata to message if available
	if len(event.Metadata) > 0 {
		if connID, ok := event.Metadata["connection_id"].(string); ok {
			message += fmt.Sprintf(" (Conn: %s)", connID)
		}
		if reconnects, ok := event.Metadata["reconnects"].(int); ok {
			message += fmt.Sprintf(" [Reconnects: %d]", reconnects)
		}
	}

	notification := Notification{
		ID:        event.ID,
		UserID:    event.UserID,
		Title:     title,
		Message:   message,
		Category:  event.Category,
		Priority:  event.Priority,
		NtfyTopic: "nats-events", // Default topic for NATS events
		Data: map[string]interface{}{
			"event_type": event.EventType,
			"status":     event.Status,
			"server":     event.Server,
			"region":     event.Region,
			"app_name":   event.AppName,
			"timestamp":  event.Timestamp,
			"error":      event.Error,
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
	return n.nc.Publish(SubjectNotification, notificationData)
}

// Handler functions for different NATS events
func (n *NATSEventNotifier) handleNATSConnect() micro.HandlerFunc {
	return func(req micro.Request) {
		var event NATSEvent
		if err := json.Unmarshal(req.Data(), &event); err != nil {
			n.l.Error("failed to unmarshal connect event", "error", err)
			req.Error("400", "invalid connect event", nil)
			return
		}

		event.EventType = NATSEventConnect
		event.Status = NATSStatusConnected
		event.Category = "nats"
		event.Priority = PriorityNormal

		if err := n.sendNATSEventNotification(event); err != nil {
			n.l.Error("failed to send connect notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("connect notification sent"))
	}
}

func (n *NATSEventNotifier) handleNATSDisconnect() micro.HandlerFunc {
	return func(req micro.Request) {
		var event NATSEvent
		if err := json.Unmarshal(req.Data(), &event); err != nil {
			n.l.Error("failed to unmarshal disconnect event", "error", err)
			req.Error("400", "invalid disconnect event", nil)
			return
		}

		event.EventType = NATSEventDisconnect
		event.Status = NATSStatusDisconnected
		event.Category = "nats"
		event.Priority = PriorityHigh

		if err := n.sendNATSEventNotification(event); err != nil {
			n.l.Error("failed to send disconnect notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("disconnect notification sent"))
	}
}

func (n *NATSEventNotifier) handleNATSReconnect() micro.HandlerFunc {
	return func(req micro.Request) {
		var event NATSEvent
		if err := json.Unmarshal(req.Data(), &event); err != nil {
			n.l.Error("failed to unmarshal reconnect event", "error", err)
			req.Error("400", "invalid reconnect event", nil)
			return
		}

		event.EventType = NATSEventReconnect
		event.Status = NATSStatusConnected
		event.Category = "nats"
		event.Priority = PriorityNormal

		if err := n.sendNATSEventNotification(event); err != nil {
			n.l.Error("failed to send reconnect notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("reconnect notification sent"))
	}
}

func (n *NATSEventNotifier) handleNATSClose() micro.HandlerFunc {
	return func(req micro.Request) {
		var event NATSEvent
		if err := json.Unmarshal(req.Data(), &event); err != nil {
			n.l.Error("failed to unmarshal close event", "error", err)
			req.Error("400", "invalid close event", nil)
			return
		}

		event.EventType = NATSEventClose
		event.Status = NATSStatusClosed
		event.Category = "nats"
		event.Priority = PriorityUrgent

		if err := n.sendNATSEventNotification(event); err != nil {
			n.l.Error("failed to send close notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("close notification sent"))
	}
}

func (n *NATSEventNotifier) handleNATSError() micro.HandlerFunc {
	return func(req micro.Request) {
		var event NATSEvent
		if err := json.Unmarshal(req.Data(), &event); err != nil {
			n.l.Error("failed to unmarshal error event", "error", err)
			req.Error("400", "invalid error event", nil)
			return
		}

		event.EventType = NATSEventError
		event.Status = NATSStatusError
		event.Category = "nats"
		event.Priority = PriorityUrgent

		if err := n.sendNATSEventNotification(event); err != nil {
			n.l.Error("failed to send error notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("error notification sent"))
	}
}

// Shutdown gracefully shuts down the service
func (n *NATSEventNotifier) Shutdown() {
	if n.svc != nil {
		n.svc.Stop()
	}
}