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

// ErrorLog represents a logged error that should trigger notifications
type ErrorLog struct {
	ID          string                 `json:"id"`
	Level       ErrorLevel             `json:"level"`
	Message     string                 `json:"message"`
	Error       string                 `json:"error"`
	Stack       string                 `json:"stack,omitempty"`
	Service     string                 `json:"service"`
	Component   string                 `json:"component"`
	UserID      string                 `json:"user_id,omitempty"`
	RequestID   string                 `json:"request_id,omitempty"`
	Timestamp   time.Time              `json:"timestamp"`
	Metadata    map[string]interface{} `json:"metadata,omitempty"`
	Priority    Priority               `json:"priority"`
	Category    string                 `json:"category"`
	Region      string                 `json:"region"`
	AppName     string                 `json:"app_name"`
}

type ErrorLevel string

const (
	ErrorLevelDebug   ErrorLevel = "debug"
	ErrorLevelInfo    ErrorLevel = "info"
	ErrorLevelWarning ErrorLevel = "warning"
	ErrorLevelError   ErrorLevel = "error"
	ErrorLevelFatal   ErrorLevel = "fatal"
)

// ErrorLogger handles error logging and notifications
type ErrorLogger struct {
	ntfy    *Ntfy
	nc      *nats.Conn
	l       *jst_log.Logger
	svc     micro.Service
	appName string
	region  string
}

// NewErrorLogger creates a new error logger
func NewErrorLogger(ntfy *Ntfy, nc *nats.Conn, l *jst_log.Logger, appName, region string) *ErrorLogger {
	return &ErrorLogger{
		ntfy:    ntfy,
		nc:      nc,
		l:       l,
		appName: appName,
		region:  region,
	}
}

// Start initializes the error logging service
func (e *ErrorLogger) Start(ctx context.Context) error {
	svcMetadata := map[string]string{
		"service":     "error-logger",
		"version":     "1.0.0",
		"description": "Error logging and notification service",
	}

	svc, err := micro.AddService(e.nc, micro.Config{
		Name:        "error-logger",
		Version:     "1.0.0",
		Description: "Error logging and notification service",
		Metadata:    svcMetadata,
	})
	if err != nil {
		return fmt.Errorf("add error logger service: %w", err)
	}

	e.svc = svc

	// Add endpoints for different error levels
	endpoints := []struct {
		name    string
		subject string
		handler micro.HandlerFunc
	}{
		{"log_error", "error.log", e.handleErrorLog},
		{"log_warning", "error.warning", e.handleWarningLog},
		{"log_fatal", "error.fatal", e.handleFatalLog},
		{"log_custom", "error.custom", e.handleCustomErrorLog},
	}

	for _, endpoint := range endpoints {
		if err := svc.AddEndpoint(endpoint.name, endpoint.handler, 
			micro.WithEndpointSubject(endpoint.subject)); err != nil {
			return fmt.Errorf("add endpoint %s: %w", endpoint.name, err)
		}
	}

	// Subscribe to error events for automatic notifications
	if err := e.subscribeToErrorEvents(); err != nil {
		return fmt.Errorf("subscribe to error events: %w", err)
	}

	e.l.Info("error logger started")
	return nil
}

// Subscribe to error events for automatic notifications
func (e *ErrorLogger) subscribeToErrorEvents() error {
	// Subscribe to all error events
	sub, err := e.nc.Subscribe("error.*", func(msg *nats.Msg) {
		var errorLog ErrorLog
		if err := json.Unmarshal(msg.Data, &errorLog); err != nil {
			e.l.Error("failed to unmarshal error log", "error", err)
			return
		}

		// Set defaults
		if errorLog.Timestamp.IsZero() {
			errorLog.Timestamp = time.Now()
		}
		if errorLog.Category == "" {
			errorLog.Category = "error"
		}
		if errorLog.Priority == "" {
			errorLog.Priority = e.determinePriority(errorLog.Level)
		}
		if errorLog.Region == "" {
			errorLog.Region = e.region
		}
		if errorLog.AppName == "" {
			errorLog.AppName = e.appName
		}

		// Send notification for errors and above
		if errorLog.Level == ErrorLevelError || errorLog.Level == ErrorLevelFatal {
			if err := e.sendErrorNotification(errorLog); err != nil {
				e.l.Error("failed to send error notification", "error", err, "error_id", errorLog.ID)
			}
		}
	})
	if err != nil {
		return fmt.Errorf("subscribe to error events: %w", err)
	}

	// Set subscription options
	sub.SetPendingLimits(1000, 100*1024*1024) // 1000 messages, 100MB

	return nil
}

// Determine priority based on error level
func (e *ErrorLogger) determinePriority(level ErrorLevel) Priority {
	switch level {
	case ErrorLevelFatal:
		return PriorityUrgent
	case ErrorLevelError:
		return PriorityHigh
	case ErrorLevelWarning:
		return PriorityNormal
	case ErrorLevelInfo, ErrorLevelDebug:
		return PriorityLow
	default:
		return PriorityNormal
	}
}

// Send error notification
func (e *ErrorLogger) sendErrorNotification(errorLog ErrorLog) error {
	// Create notification title and message
	title := fmt.Sprintf("Error: %s - %s", errorLog.Level, errorLog.Service)
	message := fmt.Sprintf("%s: %s", errorLog.Component, errorLog.Message)

	// Add error details if available
	if errorLog.Error != "" {
		message += fmt.Sprintf(" - %s", errorLog.Error)
	}

	// Add metadata to message if available
	if len(errorLog.Metadata) > 0 {
		if requestID, ok := errorLog.Metadata["request_id"].(string); ok {
			message += fmt.Sprintf(" (Request: %s)", requestID)
		}
		if userID, ok := errorLog.Metadata["user_id"].(string); ok {
			message += fmt.Sprintf(" (User: %s)", userID)
		}
	}

	notification := Notification{
		ID:        errorLog.ID,
		UserID:    errorLog.UserID,
		Title:     title,
		Message:   message,
		Category:  errorLog.Category,
		Priority:  errorLog.Priority,
		NtfyTopic: "error-logs", // Default topic for error logs
		Data: map[string]interface{}{
			"level":       errorLog.Level,
			"service":     errorLog.Service,
			"component":   errorLog.Component,
			"error":       errorLog.Error,
			"stack":       errorLog.Stack,
			"request_id":  errorLog.RequestID,
			"timestamp":   errorLog.Timestamp,
			"metadata":    errorLog.Metadata,
			"region":      errorLog.Region,
			"app_name":    errorLog.AppName,
		},
		CreatedAt: errorLog.Timestamp,
	}

	// Send via NATS to the ntfy service
	notificationData, err := json.Marshal(notification)
	if err != nil {
		return fmt.Errorf("marshal notification: %w", err)
	}

	// Publish to ntfy service
	return e.nc.Publish(SubjectNotification, notificationData)
}

// Handler functions for different error levels
func (e *ErrorLogger) handleErrorLog() micro.HandlerFunc {
	return func(req micro.Request) {
		var errorLog ErrorLog
		if err := json.Unmarshal(req.Data(), &errorLog); err != nil {
			e.l.Error("failed to unmarshal error log", "error", err)
			req.Error("400", "invalid error log", nil)
			return
		}

		errorLog.Level = ErrorLevelError
		errorLog.Category = "error"
		errorLog.Priority = PriorityHigh

		if err := e.sendErrorNotification(errorLog); err != nil {
			e.l.Error("failed to send error notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("error notification sent"))
	}
}

func (e *ErrorLogger) handleWarningLog() micro.HandlerFunc {
	return func(req micro.Request) {
		var errorLog ErrorLog
		if err := json.Unmarshal(req.Data(), &errorLog); err != nil {
			e.l.Error("failed to unmarshal warning log", "error", err)
			req.Error("400", "invalid warning log", nil)
			return
		}

		errorLog.Level = ErrorLevelWarning
		errorLog.Category = "error"
		errorLog.Priority = PriorityNormal

		if err := e.sendErrorNotification(errorLog); err != nil {
			e.l.Error("failed to send warning notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("warning notification sent"))
	}
}

func (e *ErrorLogger) handleFatalLog() micro.HandlerFunc {
	return func(req micro.Request) {
		var errorLog ErrorLog
		if err := json.Unmarshal(req.Data(), &errorLog); err != nil {
			e.l.Error("failed to unmarshal fatal log", "error", err)
			req.Error("400", "invalid fatal log", nil)
			return
		}

		errorLog.Level = ErrorLevelFatal
		errorLog.Category = "error"
		errorLog.Priority = PriorityUrgent

		if err := e.sendErrorNotification(errorLog); err != nil {
			e.l.Error("failed to send fatal notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("fatal notification sent"))
	}
}

func (e *ErrorLogger) handleCustomErrorLog() micro.HandlerFunc {
	return func(req micro.Request) {
		var errorLog ErrorLog
		if err := json.Unmarshal(req.Data(), &errorLog); err != nil {
			e.l.Error("failed to unmarshal custom error log", "error", err)
			req.Error("400", "invalid custom error log", nil)
			return
		}

		// Use provided level and priority
		if errorLog.Category == "" {
			errorLog.Category = "error"
		}
		if errorLog.Priority == "" {
			errorLog.Priority = e.determinePriority(errorLog.Level)
		}

		if err := e.sendErrorNotification(errorLog); err != nil {
			e.l.Error("failed to send custom error notification", "error", err)
			req.Error("500", "failed to send notification", nil)
			return
		}

		req.Respond([]byte("custom error notification sent"))
	}
}

// LogError logs an error and optionally sends a notification
func (e *ErrorLogger) LogError(service, component, message, errorStr string, metadata map[string]interface{}) error {
	errorLog := ErrorLog{
		ID:        fmt.Sprintf("error-%d", time.Now().UnixNano()),
		Level:     ErrorLevelError,
		Message:   message,
		Error:     errorStr,
		Service:   service,
		Component: component,
		Timestamp: time.Now(),
		Metadata:  metadata,
		Priority:  PriorityHigh,
		Category:  "error",
		Region:    e.region,
		AppName:   e.appName,
	}

	// Publish to error events
	errorData, err := json.Marshal(errorLog)
	if err != nil {
		return fmt.Errorf("marshal error log: %w", err)
	}

	return e.nc.Publish("error.log", errorData)
}

// LogWarning logs a warning and optionally sends a notification
func (e *ErrorLogger) LogWarning(service, component, message string, metadata map[string]interface{}) error {
	errorLog := ErrorLog{
		ID:        fmt.Sprintf("warning-%d", time.Now().UnixNano()),
		Level:     ErrorLevelWarning,
		Message:   message,
		Service:   service,
		Component: component,
		Timestamp: time.Now(),
		Metadata:  metadata,
		Priority:  PriorityNormal,
		Category:  "error",
		Region:    e.region,
		AppName:   e.appName,
	}

	// Publish to error events
	errorData, err := json.Marshal(errorLog)
	if err != nil {
		return fmt.Errorf("marshal warning log: %w", err)
	}

	return e.nc.Publish("error.warning", errorData)
}

// LogFatal logs a fatal error and sends an urgent notification
func (e *ErrorLogger) LogFatal(service, component, message, errorStr string, metadata map[string]interface{}) error {
	errorLog := ErrorLog{
		ID:        fmt.Sprintf("fatal-%d", time.Now().UnixNano()),
		Level:     ErrorLevelFatal,
		Message:   message,
		Error:     errorStr,
		Service:   service,
		Component: component,
		Timestamp: time.Now(),
		Metadata:  metadata,
		Priority:  PriorityUrgent,
		Category:  "error",
		Region:    e.region,
		AppName:   e.appName,
	}

	// Publish to error events
	errorData, err := json.Marshal(errorLog)
	if err != nil {
		return fmt.Errorf("marshal fatal log: %w", err)
	}

	return e.nc.Publish("error.fatal", errorData)
}

// Shutdown gracefully shuts down the service
func (e *ErrorLogger) Shutdown() {
	if e.svc != nil {
		e.svc.Stop()
	}
}