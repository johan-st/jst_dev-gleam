//go:build integration

package integration

import (
	"context"
	"testing"
	"time"

	"github.com/nats-io/nats.go/jetstream"
)

// TestSingleFatNode tests that a single fat node starts and operates correctly
func TestSingleFatNode(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	// Create single node cluster
	configs := SingleNodeConfig("")
	cluster := NewTestCluster(t, configs)
	defer cluster.Cleanup()

	// Start the node
	t.Log("Starting single fat node...")
	if err := cluster.Start(); err != nil {
		t.Fatalf("Failed to start cluster: %v", err)
	}

	node := cluster.Nodes[0]

	// Test 1: Health checks
	t.Run("HealthChecks", func(t *testing.T) {
		if !node.IsAlive() {
			t.Error("Node is not alive")
		}
		if !node.IsReady() {
			t.Error("Node is not ready")
		}
	})

	// Test 2: Cluster info
	t.Run("ClusterInfo", func(t *testing.T) {
		info, err := node.GetClusterInfo()
		if err != nil {
			t.Fatalf("Failed to get cluster info: %v", err)
		}

		status, ok := info["status"].(string)
		if !ok || status != "CONNECTED" {
			t.Errorf("Expected status CONNECTED, got %v", info["status"])
		}
	})

	// Test 3: NATS connection
	t.Run("NATSConnection", func(t *testing.T) {
		nc, err := node.Connect()
		if err != nil {
			t.Fatalf("Failed to connect to NATS: %v", err)
		}

		if !nc.IsConnected() {
			t.Error("NATS connection is not connected")
		}
	})

	// Test 4: JetStream operations
	t.Run("JetStreamKV", func(t *testing.T) {
		js, err := node.GetJetStream()
		if err != nil {
			t.Fatalf("Failed to get JetStream: %v", err)
		}

		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		// Create a test KV bucket
		bucketName := "test-single-node"
		kv, err := CreateTestKVBucket(ctx, js, bucketName, 1)
		if err != nil {
			t.Fatalf("Failed to create KV bucket: %v", err)
		}

		// Test put and get
		testKey := "test-key"
		testValue := "test-value"
		if err := PutAndVerify(ctx, kv, testKey, testValue); err != nil {
			t.Fatalf("Put and verify failed: %v", err)
		}

		// Test update
		updatedValue := "updated-value"
		if err := PutAndVerify(ctx, kv, testKey, updatedValue); err != nil {
			t.Fatalf("Update and verify failed: %v", err)
		}

		// Test delete
		if err := kv.Delete(ctx, testKey); err != nil {
			t.Fatalf("Delete failed: %v", err)
		}

		// Verify delete
		_, err = kv.Get(ctx, testKey)
		if err == nil {
			t.Error("Expected error getting deleted key")
		}

		// Cleanup
		if err := js.DeleteKeyValue(ctx, bucketName); err != nil {
			t.Logf("Warning: failed to cleanup bucket: %v", err)
		}
	})

	// Test 5: JetStream Stream operations
	t.Run("JetStreamStream", func(t *testing.T) {
		js, err := node.GetJetStream()
		if err != nil {
			t.Fatalf("Failed to get JetStream: %v", err)
		}

		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		// Create a test stream
		streamName := "TEST_SINGLE_NODE"
		stream, err := js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
			Name:     streamName,
			Subjects: []string{"test.single.>"},
			Replicas: 1,
			Storage:  jetstream.FileStorage,
		})
		if err != nil {
			t.Fatalf("Failed to create stream: %v", err)
		}

		// Publish a message
		nc, _ := node.Connect()
		if err := nc.Publish("test.single.msg", []byte("hello")); err != nil {
			t.Fatalf("Failed to publish: %v", err)
		}

		// Wait for message to be stored
		time.Sleep(500 * time.Millisecond)

		// Verify message count
		info, err := stream.Info(ctx)
		if err != nil {
			t.Fatalf("Failed to get stream info: %v", err)
		}

		if info.State.Msgs != 1 {
			t.Errorf("Expected 1 message, got %d", info.State.Msgs)
		}

		// Cleanup
		if err := js.DeleteStream(ctx, streamName); err != nil {
			t.Logf("Warning: failed to cleanup stream: %v", err)
		}
	})

	// Test 6: Ping-pong (basic NATS)
	t.Run("NATSPingPong", func(t *testing.T) {
		nc, err := node.Connect()
		if err != nil {
			t.Fatalf("Failed to connect: %v", err)
		}

		// The embedded server has a ping handler
		msg, err := nc.Request("ping", nil, 5*time.Second)
		if err != nil {
			t.Fatalf("Ping request failed: %v", err)
		}

		if string(msg.Data) != "pong" {
			t.Errorf("Expected 'pong', got %q", msg.Data)
		}
	})
}

// TestSingleNodeRestart tests that a single node can restart and recover data
func TestSingleNodeRestart(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	configs := SingleNodeConfig("")
	cluster := NewTestCluster(t, configs)
	defer cluster.Cleanup()

	t.Log("Starting single fat node...")
	if err := cluster.Start(); err != nil {
		t.Fatalf("Failed to start cluster: %v", err)
	}

	node := cluster.Nodes[0]

	// Create test data
	t.Log("Creating test data...")
	js, err := node.GetJetStream()
	if err != nil {
		t.Fatalf("Failed to get JetStream: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	bucketName := "test-restart"
	kv, err := CreateTestKVBucket(ctx, js, bucketName, 1)
	if err != nil {
		t.Fatalf("Failed to create KV bucket: %v", err)
	}

	// Store some data
	testData := map[string]string{
		"key1": "value1",
		"key2": "value2",
		"key3": "value3",
	}

	for k, v := range testData {
		if _, err := kv.Put(ctx, k, []byte(v)); err != nil {
			t.Fatalf("Failed to put %s: %v", k, err)
		}
	}

	t.Log("Data stored, stopping node...")

	// Stop the node
	node.Stop()
	time.Sleep(2 * time.Second)

	t.Log("Restarting node...")

	// Restart the node
	serverBin := cluster.BaseDir + "/server"
	if err := node.Restart(cluster, serverBin); err != nil {
		t.Fatalf("Failed to restart node: %v", err)
	}

	// Wait for node to be ready
	if err := cluster.WaitForReady(60 * time.Second); err != nil {
		t.Fatalf("Node did not become ready: %v", err)
	}

	t.Log("Node restarted, verifying data...")

	// Reconnect
	js, err = node.GetJetStream()
	if err != nil {
		t.Fatalf("Failed to get JetStream after restart: %v", err)
	}

	ctx2, cancel2 := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel2()

	kv, err = js.KeyValue(ctx2, bucketName)
	if err != nil {
		t.Fatalf("Failed to get KV bucket after restart: %v", err)
	}

	// Verify data
	for k, expected := range testData {
		entry, err := kv.Get(ctx2, k)
		if err != nil {
			t.Errorf("Failed to get %s after restart: %v", k, err)
			continue
		}
		if string(entry.Value()) != expected {
			t.Errorf("Value mismatch for %s: got %q, want %q", k, entry.Value(), expected)
		}
	}

	t.Log("Data verified successfully after restart!")
}
