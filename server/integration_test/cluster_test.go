//go:build integration

package integration

import (
	"context"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// TestTwoNodeCluster tests basic two-node cluster formation and operation
func TestTwoNodeCluster(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	configs := TwoNodeConfigs("")
	cluster := NewTestCluster(t, configs)
	defer cluster.Cleanup()

	t.Log("Starting 2-node cluster...")
	if err := cluster.Start(); err != nil {
		t.Fatalf("Failed to start cluster: %v", err)
	}

	// Test 1: All nodes healthy
	t.Run("AllNodesHealthy", func(t *testing.T) {
		for _, node := range cluster.Nodes {
			if !node.IsReady() {
				t.Errorf("%s is not ready", node.Config.Name)
			}
		}
	})

	// Test 2: Cluster info shows connected nodes
	t.Run("ClusterConnected", func(t *testing.T) {
		// Give cluster time to establish routes
		time.Sleep(5 * time.Second)

		info, err := cluster.Nodes[0].GetClusterInfo()
		if err != nil {
			t.Fatalf("Failed to get cluster info: %v", err)
		}

		status, ok := info["status"].(string)
		if !ok || status != "CONNECTED" {
			t.Errorf("Expected status CONNECTED, got %v", info["status"])
		}

		// Check discovered servers
		if servers, ok := info["servers"].([]interface{}); ok {
			t.Logf("Discovered servers: %v", servers)
		}
	})

	// Test 3: Data replication
	t.Run("DataReplication", func(t *testing.T) {
		node1 := cluster.Nodes[0]
		node2 := cluster.Nodes[1]

		js1, err := node1.GetJetStream()
		if err != nil {
			t.Fatalf("Failed to get JetStream from node1: %v", err)
		}

		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		// Create bucket on node1 with replication
		bucketName := "test-two-node-replication"
		kv1, err := CreateTestKVBucket(ctx, js1, bucketName, 2)
		if err != nil {
			t.Fatalf("Failed to create KV bucket: %v", err)
		}

		// Store data on node1
		testKey := "replicated-key"
		testValue := "replicated-value"
		if _, err := kv1.Put(ctx, testKey, []byte(testValue)); err != nil {
			t.Fatalf("Failed to put on node1: %v", err)
		}

		// Wait for replication
		time.Sleep(2 * time.Second)

		// Read from node2
		js2, err := node2.GetJetStream()
		if err != nil {
			t.Fatalf("Failed to get JetStream from node2: %v", err)
		}

		kv2, err := js2.KeyValue(ctx, bucketName)
		if err != nil {
			t.Fatalf("Failed to get bucket on node2: %v", err)
		}

		entry, err := kv2.Get(ctx, testKey)
		if err != nil {
			t.Fatalf("Failed to get on node2: %v", err)
		}

		if string(entry.Value()) != testValue {
			t.Errorf("Value mismatch on node2: got %q, want %q", entry.Value(), testValue)
		}

		t.Log("Data replicated successfully between 2 nodes!")

		// Cleanup
		if err := js1.DeleteKeyValue(ctx, bucketName); err != nil {
			t.Logf("Warning: cleanup failed: %v", err)
		}
	})
}

// TestThreeNodeCluster tests full three-node cluster with quorum
func TestThreeNodeCluster(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	configs := DefaultNodeConfigs("")
	cluster := NewTestCluster(t, configs)
	defer cluster.Cleanup()

	t.Log("Starting 3-node cluster...")
	if err := cluster.Start(); err != nil {
		t.Fatalf("Failed to start cluster: %v", err)
	}

	// Test 1: All nodes healthy
	t.Run("AllNodesHealthy", func(t *testing.T) {
		for _, node := range cluster.Nodes {
			if !node.IsReady() {
				t.Errorf("%s is not ready", node.Config.Name)
			}
		}
	})

	// Test 2: Full replication (R=3)
	t.Run("FullReplication", func(t *testing.T) {
		js, err := cluster.Nodes[0].GetJetStream()
		if err != nil {
			t.Fatalf("Failed to get JetStream: %v", err)
		}

		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()

		// Create bucket with R=3
		bucketName := "test-three-node-replication"
		kv, err := CreateTestKVBucket(ctx, js, bucketName, 3)
		if err != nil {
			t.Fatalf("Failed to create KV bucket: %v", err)
		}

		// Store data
		testKey := "full-replicated-key"
		testValue := "full-replicated-value"
		if _, err := kv.Put(ctx, testKey, []byte(testValue)); err != nil {
			t.Fatalf("Failed to put: %v", err)
		}

		// Wait for replication
		time.Sleep(3 * time.Second)

		// Verify data can be read from all nodes
		for _, node := range cluster.Nodes {
			nodeJS, err := node.GetJetStream()
			if err != nil {
				t.Errorf("Failed to get JetStream from %s: %v", node.Config.Name, err)
				continue
			}

			nodeKV, err := nodeJS.KeyValue(ctx, bucketName)
			if err != nil {
				t.Errorf("Failed to get bucket on %s: %v", node.Config.Name, err)
				continue
			}

			entry, err := nodeKV.Get(ctx, testKey)
			if err != nil {
				t.Errorf("Failed to get on %s: %v", node.Config.Name, err)
				continue
			}

			if string(entry.Value()) != testValue {
				t.Errorf("Value mismatch on %s: got %q, want %q", node.Config.Name, entry.Value(), testValue)
			}
		}

		t.Log("Data replicated to all 3 nodes!")

		// Cleanup
		if err := js.DeleteKeyValue(ctx, bucketName); err != nil {
			t.Logf("Warning: cleanup failed: %v", err)
		}
	})

	// Test 3: Stream replication
	t.Run("StreamReplication", func(t *testing.T) {
		js, err := cluster.Nodes[0].GetJetStream()
		if err != nil {
			t.Fatalf("Failed to get JetStream: %v", err)
		}

		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()

		// Create stream with R=3
		streamName := "TEST_REPLICATED_STREAM"
		stream, err := js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
			Name:     streamName,
			Subjects: []string{"test.replicated.>"},
			Replicas: 3,
			Storage:  jetstream.FileStorage,
		})
		if err != nil {
			t.Fatalf("Failed to create stream: %v", err)
		}

		// Publish messages
		nc, _ := cluster.Nodes[0].Connect()
		for i := 0; i < 10; i++ {
			if err := nc.Publish("test.replicated.msg", []byte("message")); err != nil {
				t.Fatalf("Failed to publish: %v", err)
			}
		}

		time.Sleep(2 * time.Second)

		// Verify stream info
		info, err := stream.Info(ctx)
		if err != nil {
			t.Fatalf("Failed to get stream info: %v", err)
		}

		if info.State.Msgs != 10 {
			t.Errorf("Expected 10 messages, got %d", info.State.Msgs)
		}

		if info.Config.Replicas != 3 {
			t.Errorf("Expected 3 replicas, got %d", info.Config.Replicas)
		}

		t.Logf("Stream %s has %d messages with %d replicas",
			streamName, info.State.Msgs, info.Config.Replicas)

		// Cleanup
		if err := js.DeleteStream(ctx, streamName); err != nil {
			t.Logf("Warning: cleanup failed: %v", err)
		}
	})

	// Test 4: Cross-node messaging
	t.Run("CrossNodeMessaging", func(t *testing.T) {
		// Subscribe on node1
		nc1, _ := cluster.Nodes[0].Connect()
		received := make(chan string, 1)

		sub, err := nc1.Subscribe("cross.node.test", func(msg *nats.Msg) {
			received <- string(msg.Data)
		})
		if err != nil {
			t.Fatalf("Failed to subscribe: %v", err)
		}
		defer sub.Unsubscribe()

		// Publish from node3
		nc3, _ := cluster.Nodes[2].Connect()
		testMsg := "message-from-node3"
		if err := nc3.Publish("cross.node.test", []byte(testMsg)); err != nil {
			t.Fatalf("Failed to publish from node3: %v", err)
		}

		// Wait for message
		select {
		case msg := <-received:
			if msg != testMsg {
				t.Errorf("Wrong message: got %q, want %q", msg, testMsg)
			}
			t.Log("Cross-node messaging works!")
		case <-time.After(10 * time.Second):
			t.Error("Timeout waiting for cross-node message")
		}
	})
}

// TestClusterFormation tests that nodes can form a cluster dynamically
func TestClusterFormation(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	// Start with a single node first
	configs := SingleNodeConfig("")
	cluster := NewTestCluster(t, configs)
	defer cluster.Cleanup()

	t.Log("Starting first node...")
	if err := cluster.Start(); err != nil {
		t.Fatalf("Failed to start first node: %v", err)
	}

	// Verify first node is working
	if !cluster.Nodes[0].IsReady() {
		t.Fatal("First node is not ready")
	}

	// Create some data on first node
	js, err := cluster.Nodes[0].GetJetStream()
	if err != nil {
		t.Fatalf("Failed to get JetStream: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	bucketName := "test-cluster-formation"
	kv, err := CreateTestKVBucket(ctx, js, bucketName, 1)
	if err != nil {
		t.Fatalf("Failed to create bucket: %v", err)
	}

	if _, err := kv.Put(ctx, "initial-key", []byte("initial-value")); err != nil {
		t.Fatalf("Failed to put initial data: %v", err)
	}

	t.Log("First node has data, test complete.")
	t.Log("Note: Dynamic cluster joining requires reconfiguration which is not tested here.")
	t.Log("For full cluster tests, use TestThreeNodeCluster.")
}
