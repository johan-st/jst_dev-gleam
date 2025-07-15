package talk_test

import (
	"context"
	"testing"
	"time"

	"github.com/nats-io/nats.go"

	"jst_dev/server/jst_log"
	"jst_dev/server/talk"
)

func BenchmarkMessagingInProcess(b *testing.B) {
	// Initialize nats
	nc, err := talk.EmbeddedServer(
		context.Background(),
		talk.Conf{
			ServerName:        "test",
			EnableLogging:     false,
			ListenOnLocalhost: false,
		},
		jst_log.NewLogger("test", jst_log.DefaultSubjects()),
	)
	if err != nil {
		b.Fatalf("Failed to initialize TALK: %v", err)
	}
	defer nc.Close()

	b.ResetTimer()
	// Run the benchmark
	for n := 0; n < b.N; n++ {
		msg, err := nc.Request("ping", []byte("ping"), 50*time.Millisecond)
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
	nc, err := talk.EmbeddedServer(
		context.Background(),
		talk.Conf{
			ServerName:        "test",
			EnableLogging:     false,
			ListenOnLocalhost: false,
		},
		jst_log.NewLogger("test", jst_log.DefaultSubjects()),
	)
	if err != nil {
		b.Fatalf("Failed to initialize TALK: %v", err)
	}
	defer nc.Close()

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
