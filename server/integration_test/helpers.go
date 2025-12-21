//go:build integration

// Package integration provides comprehensive integration tests for the jst_dev
// fat node cluster. These tests verify multi-node clustering, data replication,
// and network partition recovery.
package integration

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// NodeConfig holds configuration for a single fat node
type NodeConfig struct {
	Name        string
	HTTPPort    int
	NATSClient  int
	NATSCluster int
	Peers       []string
	DataDir     string
}

// TestNode represents a running fat node process
type TestNode struct {
	Config  NodeConfig
	cmd     *exec.Cmd
	nc      *nats.Conn
	httpURL string
	natsURL string
	mu      sync.Mutex
}

// TestCluster manages a cluster of test nodes
type TestCluster struct {
	Nodes   []*TestNode
	BaseDir string
	t       *testing.T
}

// DefaultNodeConfigs returns configurations for a 3-node test cluster
func DefaultNodeConfigs(baseDir string) []NodeConfig {
	return []NodeConfig{
		{
			Name:        "node1",
			HTTPPort:    18081,
			NATSClient:  14222,
			NATSCluster: 16222,
			Peers:       []string{"127.0.0.1:16223", "127.0.0.1:16224"},
			DataDir:     filepath.Join(baseDir, "node1"),
		},
		{
			Name:        "node2",
			HTTPPort:    18082,
			NATSClient:  14223,
			NATSCluster: 16223,
			Peers:       []string{"127.0.0.1:16222", "127.0.0.1:16224"},
			DataDir:     filepath.Join(baseDir, "node2"),
		},
		{
			Name:        "node3",
			HTTPPort:    18083,
			NATSClient:  14224,
			NATSCluster: 16224,
			Peers:       []string{"127.0.0.1:16222", "127.0.0.1:16223"},
			DataDir:     filepath.Join(baseDir, "node3"),
		},
	}
}

// TwoNodeConfigs returns configurations for a 2-node test cluster
func TwoNodeConfigs(baseDir string) []NodeConfig {
	return []NodeConfig{
		{
			Name:        "node1",
			HTTPPort:    18081,
			NATSClient:  14222,
			NATSCluster: 16222,
			Peers:       []string{"127.0.0.1:16223"},
			DataDir:     filepath.Join(baseDir, "node1"),
		},
		{
			Name:        "node2",
			HTTPPort:    18082,
			NATSClient:  14223,
			NATSCluster: 16223,
			Peers:       []string{"127.0.0.1:16222"},
			DataDir:     filepath.Join(baseDir, "node2"),
		},
	}
}

// SingleNodeConfig returns configuration for a single fat node
func SingleNodeConfig(baseDir string) []NodeConfig {
	return []NodeConfig{
		{
			Name:        "node1",
			HTTPPort:    18081,
			NATSClient:  14222,
			NATSCluster: 16222,
			Peers:       nil, // No peers for single node
			DataDir:     filepath.Join(baseDir, "node1"),
		},
	}
}

// NewTestCluster creates a new test cluster with the given configurations
func NewTestCluster(t *testing.T, configs []NodeConfig) *TestCluster {
	t.Helper()

	// Create base directory for test data
	baseDir := filepath.Join(os.TempDir(), fmt.Sprintf("jst-cluster-test-%d", time.Now().UnixNano()))
	if err := os.MkdirAll(baseDir, 0755); err != nil {
		t.Fatalf("failed to create base dir: %v", err)
	}

	cluster := &TestCluster{
		Nodes:   make([]*TestNode, len(configs)),
		BaseDir: baseDir,
		t:       t,
	}

	for i, cfg := range configs {
		// Update data dir to use the cluster's base dir
		cfg.DataDir = filepath.Join(baseDir, cfg.Name)
		cluster.Nodes[i] = &TestNode{
			Config:  cfg,
			httpURL: fmt.Sprintf("http://127.0.0.1:%d", cfg.HTTPPort),
			natsURL: fmt.Sprintf("nats://127.0.0.1:%d", cfg.NATSClient),
		}
	}

	return cluster
}

// Start starts all nodes in the cluster
func (c *TestCluster) Start() error {
	c.t.Helper()

	// Build server binary
	serverBin := filepath.Join(c.BaseDir, "server")
	buildCmd := exec.Command("go", "build", "-o", serverBin, ".")
	buildCmd.Dir = filepath.Join(getProjectRoot(), "server")
	if output, err := buildCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to build server: %v\n%s", err, output)
	}

	// Start nodes with staggered timing
	for i, node := range c.Nodes {
		if err := c.startNode(node, serverBin); err != nil {
			// Stop already started nodes
			for j := 0; j < i; j++ {
				c.Nodes[j].Stop()
			}
			return fmt.Errorf("failed to start %s: %w", node.Config.Name, err)
		}
		// Stagger node starts to avoid port conflicts during startup
		time.Sleep(2 * time.Second)
	}

	// Wait for all nodes to be ready
	if err := c.WaitForReady(120 * time.Second); err != nil {
		c.Stop()
		return err
	}

	return nil
}

// startNode starts a single node
func (c *TestCluster) startNode(node *TestNode, serverBin string) error {
	node.mu.Lock()
	defer node.mu.Unlock()

	// Create data directory
	if err := os.MkdirAll(node.Config.DataDir, 0755); err != nil {
		return fmt.Errorf("create data dir: %w", err)
	}

	// Build peer string
	peerStr := ""
	if len(node.Config.Peers) > 0 {
		for i, p := range node.Config.Peers {
			if i > 0 {
				peerStr += ","
			}
			peerStr += p
		}
	}

	// Set environment variables
	env := os.Environ()
	env = append(env,
		fmt.Sprintf("NODE_NAME=%s", node.Config.Name),
		fmt.Sprintf("PORT=%d", node.Config.HTTPPort),
		fmt.Sprintf("NATS_CLIENT_PORT=%d", node.Config.NATSClient),
		fmt.Sprintf("NATS_CLUSTER_PORT=%d", node.Config.NATSCluster),
		fmt.Sprintf("CLUSTER_PEERS=%s", peerStr),
		fmt.Sprintf("JETSTREAM_STORE=%s/jetstream", node.Config.DataDir),
		"TAILSCALE_IP=127.0.0.1",
		"JWT_SECRET=test-jwt-secret-12345",
		"WEB_HASH_SALT=test-hash-salt",
		fmt.Sprintf("JETSTREAM_REPLICAS=%d", len(c.Nodes)),
	)

	// Create log file
	logFile, err := os.Create(filepath.Join(node.Config.DataDir, "stdout.log"))
	if err != nil {
		return fmt.Errorf("create log file: %w", err)
	}

	// Start process
	node.cmd = exec.Command(serverBin, "-fat-node", "-log", "info")
	node.cmd.Env = env
	node.cmd.Stdout = logFile
	node.cmd.Stderr = logFile

	if err := node.cmd.Start(); err != nil {
		logFile.Close()
		return fmt.Errorf("start process: %w", err)
	}

	c.t.Logf("Started %s (PID: %d, HTTP: %d, NATS: %d)",
		node.Config.Name, node.cmd.Process.Pid, node.Config.HTTPPort, node.Config.NATSClient)

	return nil
}

// Stop stops all nodes in the cluster
func (c *TestCluster) Stop() {
	c.t.Helper()

	for _, node := range c.Nodes {
		node.Stop()
	}
}

// Cleanup stops the cluster and removes all test data
func (c *TestCluster) Cleanup() {
	c.t.Helper()

	c.Stop()

	// Give processes time to release file handles
	time.Sleep(1 * time.Second)

	// Remove test data directory
	if err := os.RemoveAll(c.BaseDir); err != nil {
		c.t.Logf("Warning: failed to remove test data: %v", err)
	}
}

// Stop stops a single node
func (n *TestNode) Stop() {
	n.mu.Lock()
	defer n.mu.Unlock()

	if n.nc != nil {
		n.nc.Close()
		n.nc = nil
	}

	if n.cmd != nil && n.cmd.Process != nil {
		// Send SIGTERM first
		n.cmd.Process.Signal(syscall.SIGTERM)

		// Wait briefly for graceful shutdown
		done := make(chan error, 1)
		go func() {
			done <- n.cmd.Wait()
		}()

		select {
		case <-done:
			// Process exited
		case <-time.After(5 * time.Second):
			// Force kill if still running
			n.cmd.Process.Kill()
			<-done
		}

		n.cmd = nil
	}
}

// Restart restarts a stopped node
func (n *TestNode) Restart(cluster *TestCluster, serverBin string) error {
	n.Stop()
	time.Sleep(1 * time.Second)
	return cluster.startNode(n, serverBin)
}

// WaitForReady waits for all nodes to be ready
func (c *TestCluster) WaitForReady(timeout time.Duration) error {
	c.t.Helper()

	deadline := time.Now().Add(timeout)

	for _, node := range c.Nodes {
		for time.Now().Before(deadline) {
			if node.IsReady() {
				c.t.Logf("%s is ready", node.Config.Name)
				break
			}
			time.Sleep(1 * time.Second)
		}

		if !node.IsReady() {
			return fmt.Errorf("%s did not become ready within timeout", node.Config.Name)
		}
	}

	return nil
}

// IsReady checks if a node is ready to accept requests
func (n *TestNode) IsReady() bool {
	resp, err := http.Get(n.httpURL + "/health/ready")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// IsAlive checks if a node is alive (basic HTTP check)
func (n *TestNode) IsAlive() bool {
	resp, err := http.Get(n.httpURL + "/health/live")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// GetClusterInfo returns cluster info from this node
func (n *TestNode) GetClusterInfo() (map[string]interface{}, error) {
	resp, err := http.Get(n.httpURL + "/health/cluster")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var info map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return nil, err
	}
	return info, nil
}

// Connect creates a NATS connection to this node
func (n *TestNode) Connect() (*nats.Conn, error) {
	n.mu.Lock()
	defer n.mu.Unlock()

	if n.nc != nil && n.nc.IsConnected() {
		return n.nc, nil
	}

	nc, err := nats.Connect(n.natsURL,
		nats.Name(fmt.Sprintf("test-client-%s", n.Config.Name)),
		nats.MaxReconnects(5),
		nats.ReconnectWait(time.Second),
		nats.Timeout(5*time.Second),
	)
	if err != nil {
		return nil, err
	}

	n.nc = nc
	return nc, nil
}

// GetJetStream returns a JetStream context for this node
func (n *TestNode) GetJetStream() (jetstream.JetStream, error) {
	nc, err := n.Connect()
	if err != nil {
		return nil, err
	}
	return jetstream.New(nc)
}

// HTTPGet performs an HTTP GET request to this node
func (n *TestNode) HTTPGet(path string) (*http.Response, error) {
	return http.Get(n.httpURL + path)
}

// HTTPPost performs an HTTP POST request to this node
func (n *TestNode) HTTPPost(path string, contentType string, body io.Reader) (*http.Response, error) {
	return http.Post(n.httpURL+path, contentType, body)
}

// WaitForCondition waits for a condition to be true
func WaitForCondition(timeout time.Duration, interval time.Duration, condition func() bool) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if condition() {
			return nil
		}
		time.Sleep(interval)
	}
	return fmt.Errorf("condition not met within timeout")
}

// getProjectRoot returns the project root directory
func getProjectRoot() string {
	// Walk up from current directory looking for go.mod
	dir, _ := os.Getwd()
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			// Reached root without finding go.mod
			return ""
		}
		dir = parent
	}
}

// PortAvailable checks if a TCP port is available
func PortAvailable(port int) bool {
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		return false
	}
	ln.Close()
	return true
}

// WaitForPort waits for a port to become available
func WaitForPort(port int, timeout time.Duration) error {
	return WaitForCondition(timeout, 100*time.Millisecond, func() bool {
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 100*time.Millisecond)
		if err != nil {
			return false
		}
		conn.Close()
		return true
	})
}

// CreateTestKVBucket creates a test KV bucket for testing
func CreateTestKVBucket(ctx context.Context, js jetstream.JetStream, name string, replicas int) (jetstream.KeyValue, error) {
	cfg := jetstream.KeyValueConfig{
		Bucket:   name,
		Replicas: replicas,
		Storage:  jetstream.FileStorage,
	}
	return js.CreateOrUpdateKeyValue(ctx, cfg)
}

// PutAndVerify puts a value and verifies it can be read back
func PutAndVerify(ctx context.Context, kv jetstream.KeyValue, key, value string) error {
	if _, err := kv.Put(ctx, key, []byte(value)); err != nil {
		return fmt.Errorf("put failed: %w", err)
	}

	entry, err := kv.Get(ctx, key)
	if err != nil {
		return fmt.Errorf("get failed: %w", err)
	}

	if string(entry.Value()) != value {
		return fmt.Errorf("value mismatch: got %q, want %q", entry.Value(), value)
	}

	return nil
}
