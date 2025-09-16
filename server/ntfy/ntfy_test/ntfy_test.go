package ntfy_test

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"jst_dev/server/jst_log"
	"jst_dev/server/ntfy"
	"jst_dev/server/talk"

	"github.com/nats-io/nats.go"
)

func TestNtfy(t *testing.T) {
	nc, teardown, err := setup()
	if err != nil {
		t.Fatalf("Failed to setup ntfy service: %v", err)
	}
	defer teardown()

	// Send a test notification using request-reply
	notification := ntfy.Notification{
		ID:        "test-notification",
		UserID:    "test-user",
		Title:     "Test title",
		Message:   "Test message",
		Category:  "test-category",
		Priority:  ntfy.PriorityLow,
		NtfyTopic: "jst_dev-test",
		Data:      map[string]interface{}{"test": "data"},
		CreatedAt: time.Now(),
	}

	req, err := json.Marshal(notification)
	if err != nil {
		t.Fatalf("Failed to marshal notification: %v", err)
	}
	response, err := nc.Request(ntfy.SubjectNotification, req, 5*time.Second)
	if err != nil {
		t.Fatalf("Failed to send notification: %v", err)
	}

	t.Logf("Response: %s", string(response.Data))
}

func setup() (*nats.Conn, func(), error) {
	// Start embedded NATS server using talk package
	nc, _, err := talk.EmbeddedServer(
		context.Background(),
		talk.Conf{
			ServerName:        "test-server-ntfy",
			EnableLogging:     false,
			ListenOnLocalhost: false,
		},
		jst_log.NewLogger("test-talk-ntfy", jst_log.DefaultSubjects()),
	)
	if err != nil {
		return nil, nil, err
	}

	ntfyService, err := ntfy.New(
		context.Background(),
		nc,
		jst_log.NewLogger("test-ntfy", jst_log.DefaultSubjects()),
	)
	if err != nil {
		return nil, nil, err
	}

	// Start ntfy service in background
	ctx, cancel := context.WithCancel(context.Background())

	go func() {
		if err := ntfyService.Run(ctx); err != nil && err != context.Canceled {
			// Log error but don't fail test since this is in setup
			_ = err
		}
	}()

	// Wait for service to be ready by checking if the endpoint is available
	if err := waitForService(nc, ntfy.SubjectNotification, 5*time.Second); err != nil {
		cancel()
		nc.Close()
		return nil, nil, err
	}

	return nc,
		func() {
			cancel() // Cancel context to stop service
			nc.Close()
		},
		nil
}

// waitForService waits for a NATS service endpoint to be available
func waitForService(nc *nats.Conn, subject string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)

	for time.Now().Before(deadline) {
		// Try to discover the service by sending a request with a very short timeout
		// If we get a "no responders" error, the service isn't ready yet
		_, err := nc.Request(subject, []byte("{}"), 100*time.Millisecond)
		if err == nil {
			// Service is ready
			return nil
		}

		// Check if it's a "no responders" error (service not ready)
		if err != nats.ErrNoResponders {
			// Some other error occurred, service might be ready but request failed
			// This is acceptable for our discovery check
			return nil
		}

		// Service not ready yet, wait a bit
		time.Sleep(50 * time.Millisecond)
	}

	return fmt.Errorf("service not ready after %v", timeout)
}
