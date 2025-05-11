package talk_test

import (
	"context"
	"jst_dev/server/jst_log"
	"jst_dev/server/talk"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
)

func BenchmarkMessagingInProcess(b *testing.B) {
	// Initialize nats
	talk, err := talk.New(talk.Conf{
		ServerName:        "test",
		EnableLogging:     false,
		ListenOnLocalhost: false,
	}, jst_log.NewLogger("test", jst_log.DefaultSubjects()))
	if err != nil {
		b.Fatalf("Failed to initialize TALK: %v", err)
	}
	conn, err := talk.Start(context.Background())
	if err != nil {
		b.Fatalf("Failed to start TALK: %v", err)
	}
	defer talk.Shutdown()

	b.ResetTimer()
	// Run the benchmark
	for n := 0; n < b.N; n++ {
		msg, err := conn.Request("ping", []byte("ping"), 50*time.Millisecond)
		if err != nil {
			b.Fatalf("Request failed: %v", err)
		}
		if string(msg.Data) != "pong" {
			b.Fatalf("Unexpected response: %s", string(msg.Data))
		}
	}
}

func BenchmarkMessagingLoopback(b *testing.B) {
	// Initialize nats
	talk, err := talk.New(talk.Conf{
		ServerName:        "test",
		EnableLogging:     false,
		ListenOnLocalhost: true,
	}, jst_log.NewLogger("test", jst_log.DefaultSubjects()))
	if err != nil {
		b.Fatalf("Failed to initialize TALK: %v", err)
	}
	defer talk.Shutdown()

	_, err = talk.Start(context.Background())
	if err != nil {
		b.Fatalf("Failed to start TALK: %v", err)
	}

	clientOpts := []nats.Option{}
	nc2, err := nats.Connect(nats.DefaultURL, clientOpts...)
	if err != nil {
		b.Fatalf("Failed to connect client: %v", err)
	}
	defer nc2.Close()

	b.ResetTimer()

	// Run the benchmark
	for n := 0; n < b.N; n++ {
		msg, err := nc2.Request("ping", []byte("ping"), 50*time.Millisecond)
		if err != nil {
			b.Fatalf("Request failed: %v", err)
		}
		if string(msg.Data) != "pong" {
			b.Fatalf("Unexpected response: %s", string(msg.Data))
		}
	}
}
