package ntfy_test

import (
	"context"
	"encoding/json"
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
	nc, err := talk.EmbeddedServer(
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
	defer cancel()

	go func() {
		if err := ntfyService.Run(ctx); err != nil && err != context.Canceled {
			// Log error but don't fail test since this is in setup
			_ = err
		}
	}()

	// Wait a bit for service to initialize
	time.Sleep(100 * time.Millisecond)

	return nc,
		func() {
			cancel() // Cancel context to stop service
			nc.Close()
		},
		nil
}
