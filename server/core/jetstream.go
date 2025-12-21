package core

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// JetStreamConfig holds cluster-aware JetStream configuration
type JetStreamConfig struct {
	// Replicas is the number of replicas for streams and KV buckets
	// Default is 1 for single node, can be increased for clusters
	Replicas int
}

var (
	jsConfig     *JetStreamConfig
	jsConfigOnce sync.Once
)

// GetJetStreamConfig returns the singleton JetStream configuration
// Reads from JETSTREAM_REPLICAS environment variable, defaults to 1
func GetJetStreamConfig() *JetStreamConfig {
	jsConfigOnce.Do(func() {
		replicas := 1
		if r := os.Getenv("JETSTREAM_REPLICAS"); r != "" {
			if n, err := strconv.Atoi(r); err == nil && n > 0 {
				replicas = n
			}
		}
		jsConfig = &JetStreamConfig{
			Replicas: replicas,
		}
	})
	return jsConfig
}

// GetReplicas returns the configured replica count
// For fat node clusters, this should match the number of nodes
func (c *JetStreamConfig) GetReplicas() int {
	if c.Replicas < 1 {
		return 1
	}
	return c.Replicas
}

// CreateKeyValueWithRetry creates a JetStream key-value bucket with retry logic.
// This is essential for fat node clusters where JetStream may not be immediately
// ready after startup (waiting for meta leader election, routing, etc.).
//
// Parameters:
//   - ctx: Context for cancellation
//   - nc: NATS connection
//   - cfg: KeyValue configuration
//   - maxRetries: Maximum number of retry attempts (0 = unlimited until context cancelled)
//   - retryDelay: Delay between retry attempts
//
// Returns the created KeyValue bucket or an error if all retries fail.
func CreateKeyValueWithRetry(
	ctx context.Context,
	nc *nats.Conn,
	cfg jetstream.KeyValueConfig,
	maxRetries int,
	retryDelay time.Duration,
) (jetstream.KeyValue, error) {
	var (
		kv       jetstream.KeyValue
		err      error
		attempts int
	)

	// Get JetStream context
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, fmt.Errorf("jetstream new: %w", err)
	}

	for {
		attempts++

		// Try to create or update the KeyValue bucket
		kv, err = js.CreateOrUpdateKeyValue(ctx, cfg)
		if err == nil {
			if attempts > 1 {
				// Log success after retries
				fmt.Printf("[jetstream] KV bucket '%s' created after %d attempts\n", cfg.Bucket, attempts)
			}
			return kv, nil
		}

		// Log retry attempt (only after first failure)
		if attempts == 1 {
			fmt.Printf("[jetstream] KV bucket '%s' creation failed, retrying (max %d attempts)...\n", cfg.Bucket, maxRetries)
		} else if attempts%5 == 0 {
			fmt.Printf("[jetstream] KV bucket '%s' still waiting... (%d/%d attempts)\n", cfg.Bucket, attempts, maxRetries)
		}

		// Check if we've exceeded max retries (0 means unlimited)
		if maxRetries > 0 && attempts >= maxRetries {
			return nil, fmt.Errorf("failed to create KV bucket '%s' after %d attempts: %w", cfg.Bucket, attempts, err)
		}

		// Check if context is cancelled
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("context cancelled while creating KV bucket '%s' after %d attempts: %w", cfg.Bucket, attempts, ctx.Err())
		default:
		}

		// Wait before retrying
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("context cancelled while waiting to retry KV bucket '%s': %w", cfg.Bucket, ctx.Err())
		case <-time.After(retryDelay):
		}
	}
}

// DefaultKVRetryConfig returns sensible defaults for KV creation retries
// - 30 retries with 2 second delay = 60 seconds total wait time
// This should be enough for JetStream cluster meta leader election
func DefaultKVRetryConfig() (maxRetries int, retryDelay time.Duration) {
	return 30, 2 * time.Second
}

// CreateStreamWithRetry creates a JetStream stream with retry logic.
// This is essential for fat node clusters where JetStream may not be immediately
// ready after startup (waiting for meta leader election, routing, etc.).
//
// Parameters:
//   - ctx: Context for cancellation
//   - nc: NATS connection
//   - cfg: Stream configuration
//   - maxRetries: Maximum number of retry attempts (0 = unlimited until context cancelled)
//   - retryDelay: Delay between retry attempts
//
// Returns the created Stream or an error if all retries fail.
func CreateStreamWithRetry(
	ctx context.Context,
	nc *nats.Conn,
	cfg jetstream.StreamConfig,
	maxRetries int,
	retryDelay time.Duration,
) (jetstream.Stream, error) {
	var (
		stream   jetstream.Stream
		err      error
		attempts int
	)

	// Get JetStream context
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, fmt.Errorf("jetstream new: %w", err)
	}

	for {
		attempts++

		// Try to create or update the stream
		stream, err = js.CreateOrUpdateStream(ctx, cfg)
		if err == nil {
			if attempts > 1 {
				// Log success after retries
				fmt.Printf("[jetstream] Stream '%s' created after %d attempts\n", cfg.Name, attempts)
			}
			return stream, nil
		}

		// Log retry attempt (only after first failure)
		if attempts == 1 {
			fmt.Printf("[jetstream] Stream '%s' creation failed, retrying (max %d attempts)...\n", cfg.Name, maxRetries)
		} else if attempts%5 == 0 {
			fmt.Printf("[jetstream] Stream '%s' still waiting... (%d/%d attempts)\n", cfg.Name, attempts, maxRetries)
		}

		// Check if we've exceeded max retries (0 means unlimited)
		if maxRetries > 0 && attempts >= maxRetries {
			return nil, fmt.Errorf("failed to create stream '%s' after %d attempts: %w", cfg.Name, attempts, err)
		}

		// Check if context is cancelled
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("context cancelled while creating stream '%s' after %d attempts: %w", cfg.Name, attempts, ctx.Err())
		default:
		}

		// Wait before retrying
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("context cancelled while waiting to retry stream '%s': %w", cfg.Name, ctx.Err())
		case <-time.After(retryDelay):
		}
	}
}
