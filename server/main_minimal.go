package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/joho/godotenv"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"jst_dev/server/core"
	"jst_dev/server/jst_log"
)

func main() {
	_ = godotenv.Load()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	nc, err := nats.Connect(os.Getenv("NATS_URL"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect NATS: %v\n", err)
		os.Exit(1)
	}
	defer nc.Drain()

	logger := jst_log.NewLogger("server-minimal", jst_log.DefaultSubjects())
	logger.Connect(nc)

	js, err := jetstream.New(nc)
	if err != nil {
		fmt.Fprintf(os.Stderr, "jetstream: %v\n", err)
		os.Exit(1)
	}

	// Services to start in minimal mode
	serviceNames := []string{"articles", "who", "convo", "urlshort", "ntfy"}

	// Start each service with its own KV bucket
	type running struct {
		name string
		svc  *core.MinimalService
	}
	runningSvcs := make([]running, 0, len(serviceNames))

	for _, name := range serviceNames {
		bucket := name + "_kv"
		kv, err := js.CreateOrUpdateKeyValue(ctx, jetstream.KeyValueConfig{Bucket: bucket})
		if err != nil {
			fmt.Fprintf(os.Stderr, "kv %s: %v\n", bucket, err)
			os.Exit(1)
		}

		svc := core.NewMinimalService(name, nc, kv, logger.WithBreadcrumb(name))
		if err := svc.Start(); err != nil {
			fmt.Fprintf(os.Stderr, "start %s: %v\n", name, err)
			os.Exit(1)
		}
		runningSvcs = append(runningSvcs, running{name: name, svc: svc})
	}

	logger.Info("minimal services running: %v", serviceNames)

	<-ctx.Done()
	logger.Info("shutting down...")

	// Stop services gracefully
	for i := len(runningSvcs) - 1; i >= 0; i-- {
		_ = runningSvcs[i].svc.Stop()
	}

	_ = nc.FlushTimeout(2 * time.Second)
}
