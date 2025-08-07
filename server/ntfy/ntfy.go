package ntfy

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/micro"
)

type Ntfy struct {
	nc *nats.Conn
	l  *jst_log.Logger

	// ntfy.sh configuration
	ntfyServer string
	ntfyToken  string
	httpClient *http.Client
}

const (
	// NATS Subjects
	SubjectNotification = "ntfy.notification"

	// ntfy.sh defaults
	DefaultNtfyServer = "https://ntfy.sh"
)

// Notification message
type Notification struct {
	ID        string                 `json:"id"`
	UserID    string                 `json:"user_id"`
	Title     string                 `json:"title"`
	Message   string                 `json:"message"`
	Category  string                 `json:"category"`
	Priority  Priority               `json:"priority"`
	NtfyTopic string                 `json:"ntfy_topic"` // User's ntfy topic
	Data      map[string]interface{} `json:"data,omitempty"`
	CreatedAt time.Time              `json:"created_at"`
}

type Priority string

const (
	PriorityLow    Priority = "low"
	PriorityNormal Priority = "normal"
	PriorityHigh   Priority = "high"
	PriorityUrgent Priority = "urgent"
)

func New(ctx context.Context, nc *nats.Conn, l *jst_log.Logger) (Ntfy, error) {
	return NewWithConfig(ctx, nc, l, DefaultNtfyServer, "")
}

func NewWithConfig(ctx context.Context, nc *nats.Conn, l *jst_log.Logger, ntfyServer, ntfyToken string) (Ntfy, error) {
	if l == nil {
		return Ntfy{}, fmt.Errorf("logger is required")
	}

	// Create HTTP client with timeout
	httpClient := &http.Client{
		Timeout: 30 * time.Second,
	}

	return Ntfy{
		nc:         nc,
		l:          l,
		ntfyServer: ntfyServer,
		ntfyToken:  ntfyToken,
		httpClient: httpClient,
	}, nil
}

// Start the notification service
func (n *Ntfy) Start(ctx context.Context) error {
	svcMetadata := map[string]string{}
	svcMetadata["location"] = "unknown"
	svcMetadata["environment"] = "development"

	ntfySvc, err := micro.AddService(n.nc, micro.Config{
		Name:        "ntfy",
		Version:     "1.0.0",
		Description: "ntfy.sh notification service",
		Metadata:    svcMetadata,
	})
	if err != nil {
		return fmt.Errorf("add service: %w", err)
	}

	// Add notification endpoint
	if err = ntfySvc.AddEndpoint("send_notification", n.handleNotification(), micro.WithEndpointSubject(SubjectNotification)); err != nil {
		return fmt.Errorf("add notification endpoint: %w", err)
	}

	n.l.Info("ntfy service started")
	return nil
}

// Handle incoming notifications
func (n *Ntfy) handleNotification() micro.HandlerFunc {
	return func(req micro.Request) {
		var notification Notification
		if err := json.Unmarshal(req.Data(), &notification); err != nil {
			n.l.Error("failed to unmarshal notification", "error", err)
			if err := req.Error("400", fmt.Sprintf("failed to unmarshal notification: %v", err), nil); err != nil {
				n.l.Error("failed to send error response", "error", err)
			}
			return
		}

		// Validate required fields
		if err := n.validateNotification(&notification); err != nil {
			n.l.Error("invalid notification", "error", err, "notification_id", notification.ID)
			if err := req.Error("400", fmt.Sprintf("invalid notification: %v", err), nil); err != nil {
				n.l.Error("failed to send error response", "error", err)
			}
			return
		}

		// Set defaults
		if notification.CreatedAt.IsZero() {
			notification.CreatedAt = time.Now()
		}
		if notification.Priority == "" {
			notification.Priority = PriorityNormal
		}

		// Send notification via ntfy
		err := n.sendNtfyNotification(notification)
		if err != nil {
			n.l.Error("failed to send ntfy notification", "error", err, "notification_id", notification.ID)
			if err := req.Error("500", fmt.Sprintf("failed to send notification: %v", err), nil); err != nil {
				n.l.Error("failed to send error response", "error", err)
			}
		} else {
			n.l.Info("ntfy notification sent successfully", "notification_id", notification.ID, "topic", notification.NtfyTopic)
			if err := req.Respond([]byte("success")); err != nil {
				n.l.Error("failed to send success response", "error", err)
			}
		}
	}
}

// Send notification via ntfy.sh
func (n *Ntfy) sendNtfyNotification(notification Notification) error {
	// Determine topic to use
	topic := notification.NtfyTopic
	if topic == "" {
		// Use user ID as topic if no custom topic is set
		topic = fmt.Sprintf("user_%s", notification.UserID)
	}

	// Build ntfy.sh request
	url := fmt.Sprintf("%s/%s", n.ntfyServer, topic)

	// Create request body
	body := bytes.NewBufferString(notification.Message)

	// Create HTTP request
	req, err := http.NewRequest("POST", url, body)
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	// Set headers
	req.Header.Set("Content-Type", "text/plain")
	req.Header.Set("Title", notification.Title)
	req.Header.Set("Priority", n.mapPriorityToNtfy(notification.Priority))
	req.Header.Set("Tags", notification.Category)

	// Add authorization header if token is configured
	if n.ntfyToken != "" {
		req.Header.Set("Authorization", "Bearer "+n.ntfyToken)
	}

	// Add custom headers for additional data
	if notification.Data != nil {
		if dataJSON, err := json.Marshal(notification.Data); err == nil {
			req.Header.Set("X-Data", string(dataJSON))
		}
	}

	// Send request
	resp, err := n.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("failed to send request: %w", err)
	}
	defer resp.Body.Close()

	// Read response body
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("failed to read response: %w", err)
	}

	// Check response status
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("ntfy request failed with status %d: %s", resp.StatusCode, string(respBody))
	}

	return nil
}

// Map our priority levels to ntfy.sh priority levels
func (n *Ntfy) mapPriorityToNtfy(priority Priority) string {
	switch priority {
	case PriorityLow:
		return "1"
	case PriorityNormal:
		return "3"
	case PriorityHigh:
		return "4"
	case PriorityUrgent:
		return "5"
	default:
		return "3"
	}
}

// Validate notification fields
func (n *Ntfy) validateNotification(notification *Notification) error {
	if notification.ID == "" {
		return fmt.Errorf("notification ID is required")
	}
	if notification.UserID == "" {
		return fmt.Errorf("user ID is required")
	}
	if notification.Title == "" {
		return fmt.Errorf("title is required")
	}
	if notification.Message == "" {
		return fmt.Errorf("message is required")
	}
	if notification.Category == "" {
		return fmt.Errorf("category is required")
	}
	return nil
}
