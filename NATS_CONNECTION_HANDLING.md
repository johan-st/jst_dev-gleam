# NATS Connection Handling - Fat Nodes

This document describes how fat nodes handle NATS connections, clustering, and failure scenarios.

> See [REFACTOR.md](./REFACTOR.md) for the complete fat nodes architecture.

## Fat Node NATS Architecture

Each fat node runs an **embedded NATS server** that:
1. Serves local clients (the Go HTTP server)
2. Clusters with other fat nodes over Tailscale
3. Replicates JetStream data across the cluster

```
┌─────────────────────────────────────┐
│           Fat Node                  │
│  ┌─────────────────────────────┐   │
│  │      Go HTTP Server         │   │
│  │  (NATS Client Connection)   │   │
│  └──────────────┬──────────────┘   │
│                 │ localhost:4222   │
│  ┌──────────────▼──────────────┐   │
│  │    Embedded NATS Server     │   │
│  │  ┌───────────────────────┐  │   │
│  │  │     JetStream         │  │   │
│  │  │   (Local Storage)     │  │   │
│  │  └───────────────────────┘  │   │
│  └──────────────┬──────────────┘   │
│                 │ :6222 cluster    │
└─────────────────┼──────────────────┘
                  │ Tailscale VPN
                  ▼
         Other Fat Nodes
```

## Connection Modes

### 1. Fat Node Mode (Production)

```bash
go run . -fat-node
```

- Starts embedded NATS server with clustering enabled
- Connects to local NATS (localhost:4222)
- Clusters with peers over Tailscale IPs
- JetStream stores data locally

### 2. Local Development Mode

```bash
go run . -local
```

- Starts embedded NATS server (single node, no clustering)
- JetStream stores data in temp directory
- For development and testing

### 3. NGS Mode (Legacy)

```bash
go run .
```

- Connects to Synadia NGS (global NATS service)
- Uses JWT/NKEY credentials
- Not a fat node (thin client)

## Startup Behavior

### Fat Node Startup Sequence

```go
1. Detect Tailscale IP (100.x.x.x)
2. Load cluster peer configuration
3. Start embedded NATS server with:
   - Cluster routes to peers
   - JetStream enabled with local storage
4. Wait for NATS server to be ready
5. Connect Go app as NATS client (localhost)
6. Initialize JetStream context
7. Create/verify KV buckets and streams
8. Start HTTP server and services
```

### Cluster Join Behavior

When a fat node starts and discovers peers:

```
Node A (existing):  Running, serving requests
Node B (new):       Starting up...
                    ↓
                    Connect to cluster route (Node A:6222)
                    ↓
                    NATS cluster handshake
                    ↓
                    JetStream sync begins
                    ↓
                    Streams/KV replicate from Node A
                    ↓
                    Node B ready to serve
```

## Failure Handling

### Network Partition

When a fat node loses connectivity to peers:

```
Before:  Node A ←──cluster──→ Node B ←──cluster──→ Node C

Partition: Node A ←──X──→ [Node B ←──cluster──→ Node C]

Behavior:
- Node A continues serving requests (local JetStream)
- Node B + C continue serving (they still cluster)
- Writes on Node A stay local until partition heals
- JetStream handles eventual consistency on reconnect
```

### Single Node Operation

A fat node can operate completely alone:

- All requests served from local JetStream
- No replication (R=1 effective)
- When cluster reconnects, newer writes propagate

### Embedded NATS Server Crash

If the embedded NATS server crashes:

```go
// The Go server monitors NATS health
// On embedded server failure, entire node restarts
// This is intentional - NATS is critical infrastructure

if embeddedServer.ReadyForConnections(10*time.Second) == false {
    log.Fatal("Embedded NATS server failed to start")
}
```

### Recovery Scenarios

| Scenario | Behavior |
|----------|----------|
| Node restart | JetStream recovers from local files |
| Network restored | NATS cluster syncs automatically |
| New node joins | Gets replicated data from cluster |
| All nodes restart | Each recovers local state, then syncs |

## JetStream Replication

### Replication Factor

Configure per stream/KV bucket:

```go
// R=3: Replicate to 3 nodes (or all if fewer nodes)
streamConfig := &nats.StreamConfig{
    Name:     "ARTICLES",
    Replicas: 3,
}

// R=1: Local only (no replication)
kvConfig := &nats.KeyValueConfig{
    Bucket:   "cache",
    Replicas: 1,
}
```

### Conflict Resolution

JetStream uses **last-write-wins** for KV:

```
Node A: PUT key="foo" value="A" @ time T1
Node B: PUT key="foo" value="B" @ time T2 (T2 > T1)

After sync: key="foo" has value="B" on all nodes
```

For streams, messages are ordered by sequence number and merged.

## Configuration

### Environment Variables

```bash
# Fat node identity
NODE_NAME=jst-node-1
TAILSCALE_IP=100.64.0.1      # Auto-detected if not set

# Cluster configuration
NATS_CLUSTER_NAME=jst-cluster
NATS_CLIENT_PORT=4222
NATS_CLUSTER_PORT=6222
CLUSTER_PEERS=100.64.0.2:6222,100.64.0.3:6222

# JetStream storage
JETSTREAM_STORE=/data/jetstream
JETSTREAM_MAX_MEM=1GB
JETSTREAM_MAX_FILE=10GB
```

### NATS Server Options

```go
opts := &server.Options{
    ServerName: nodeName,
    Host:       tailscaleIP,
    Port:       4222,
    
    // Clustering
    Cluster: server.ClusterOpts{
        Name: "jst-cluster",
        Host: tailscaleIP,
        Port: 6222,
    },
    Routes: clusterRoutes,
    
    // JetStream
    JetStream:    true,
    StoreDir:     jetStreamStore,
    JetStreamMaxMemory: maxMem,
    JetStreamMaxStore:  maxFile,
    
    // Resilience
    MaxReconnects: -1,  // Unlimited reconnection attempts
    ReconnectWait: time.Second,
}
```

## Health Checks

### Liveness Check

```go
// /health/live - Is the node running?
func liveHandler(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
}
```

### Readiness Check

```go
// /health/ready - Can the node serve requests?
func readyHandler(nc *nats.Conn) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        if nc.Status() != nats.CONNECTED {
            http.Error(w, "NATS not connected", http.StatusServiceUnavailable)
            return
        }
        w.WriteHeader(http.StatusOK)
    }
}
```

### Cluster Status

```go
// /health/cluster - Cluster membership info
func clusterHandler(embeddedServer *server.Server) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        info := embeddedServer.ClusterInfo()
        json.NewEncoder(w).Encode(info)
    }
}
```

## Monitoring

### NATS CLI Commands

```bash
# Check cluster status
nats server list --server=localhost:4222

# Check JetStream
nats stream list
nats kv list

# Monitor traffic
nats sub ">" --server=localhost:4222
```

### Metrics

Fat nodes expose Prometheus metrics:

```
# NATS connection status
nats_connection_status{node="jst-node-1"} 1

# Cluster members
nats_cluster_size{cluster="jst-cluster"} 3

# JetStream
jetstream_streams_total 5
jetstream_consumers_total 12
jetstream_messages_total 45678
```

## Troubleshooting

### Node Won't Join Cluster

1. Check Tailscale connectivity: `tailscale ping other-node`
2. Verify cluster port is reachable: `nc -zv 100.64.0.2 6222`
3. Check NATS logs: Look for "route" connection messages
4. Verify cluster name matches across nodes

### JetStream Not Syncing

1. Check replication factor: `nats stream info STREAM_NAME`
2. Verify cluster has enough nodes for R=N
3. Check storage limits: `nats server report jetstream`
4. Look for stream errors in NATS logs

### Split-Brain After Partition

JetStream handles this automatically:
1. Each partition operates independently
2. On reconnect, NATS syncs based on sequence numbers
3. KV uses last-write-wins
4. Monitor for data conflicts in application logs

## Summary

- **Fat nodes run embedded NATS servers** - Self-sufficient, can operate alone
- **Clustering over Tailscale** - Nodes discover and connect via VPN
- **JetStream replication** - Data syncs across cluster automatically
- **Graceful degradation** - Partitioned nodes continue serving locally
- **Automatic recovery** - NATS handles reconnection and sync
