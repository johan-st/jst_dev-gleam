package talk

import (
	"fmt"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
)

func BenchmarkMessagingInProcess(b *testing.B) {

	// Initialize nats
	nc, _, err := InitNats(ConfNatsServer{
		EnableLogging: false,
		InProcess:     true,
	})
	if err != nil {
		fmt.Println(err)
		b.FailNow()
	}
	defer nc.Close()

	// Setup the handler
	MessagingHandler(nc)

	b.ResetTimer()

	// Run the benchmark
	for n := 0; n < b.N; n++ {
		// Send 100k messages and wait for responses
		msg, err := nc.Request("health", []byte("ping"), 1*time.Second)
		if err != nil {
			b.Fatalf("Request failed: %v", err)
		}
		if string(msg.Data) != "OK" {
			b.Fatalf("Unexpected response: %s", string(msg.Data))
		}
	}
}

func BenchmarkMessagingLoopback(b *testing.B) {

	// Initialize nats
	nc, _, err := InitNats(ConfNatsServer{
		EnableLogging: false,
		InProcess:     true,
	})
	if err != nil {
		fmt.Println(err)
		b.FailNow()
	}
	defer nc.Close()

	// Setup the handler
	MessagingHandler(nc)

	clientOpts := []nats.Option{}
	nc2, err := nats.Connect(nats.DefaultURL, clientOpts...)
	if err != nil {
		b.Fatalf("err: %e", err)
	}

	b.ResetTimer()

	// Run the benchmark
	for n := 0; n < b.N; n++ {
		// Send 100k messages and wait for responses
		msg, err := nc2.Request("health", []byte("ping"), 1*time.Second)
		if err != nil {
			b.Fatalf("Request failed: %v", err)
		}
		if string(msg.Data) != "OK" {
			b.Fatalf("Unexpected response: %s", string(msg.Data))
		}
	}
}
