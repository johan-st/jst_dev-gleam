# REFACTOR.md - Fat Nodes Architecture

> **This is the canonical architecture document for jst_dev.**

## Overview

jst_dev is a **personal/team infrastructure platform** built with a "fat nodes" architecture - each node is self-sufficient with embedded NATS, local caching, and the ability to operate independently during network partitions.

## Target Requirements

- Multiple servers with high latency tolerance
- Nodes that can fall off and reconnect gracefully
- Nodes outside of Fly.io network (edge nodes, home servers, Raspberry Pis)
- Support for: chat, collaborative editing, document sharing, URL shortener, push notifications (ntfy.sh), planning, scheduled tasks, IoT telemetry

---

## Architecture: Fat Nodes with NATS Backbone

### What is a "Fat Node"?

A fat node is a self-sufficient server instance that:

1. **Runs an embedded NATS server** - Can operate independently or cluster with other nodes
2. **Has local state/caching** - JetStream KV and streams persist locally
3. **Serves the full application** - HTTP API, WebSocket bridge, static assets
4. **Handles offline operation** - Queues messages locally, syncs when reconnected
5. **Auto-clusters via Tailscale** - Nodes discover and connect to each other over VPN

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Tailscale VPN Mesh                              │
│                         (100.x.x.x private network)                          │
└───────────┬─────────────────────┬─────────────────────┬─────────────────────┘
            │                     │                     │
     ┌──────▼──────┐       ┌──────▼──────┐       ┌──────▼──────┐
     │  Fat Node   │       │  Fat Node   │       │  Fat Node   │
     │  (Fly.io)   │◄─────►│  (Hetzner)  │◄─────►│ (Home RPi)  │
     │             │ NATS  │             │ NATS  │             │
     │ ┌─────────┐ │ Cluster│ ┌─────────┐ │ Cluster│ ┌─────────┐ │
     │ │Embedded │ │       │ │Embedded │ │       │ │Embedded │ │
     │ │  NATS   │ │       │ │  NATS   │ │       │ │  NATS   │ │
     │ │Server   │ │       │ │Server   │ │       │ │Server   │ │
     │ └─────────┘ │       │ └─────────┘ │       │ └─────────┘ │
     │             │       │             │       │             │
     │ ┌─────────┐ │       │ ┌─────────┐ │       │ ┌─────────┐ │
     │ │ Go HTTP │ │       │ │ Go HTTP │ │       │ │ Go HTTP │ │
     │ │ Server  │ │       │ │ Server  │ │       │ │ Server  │ │
     │ │ + WS    │ │       │ │ + WS    │ │       │ │ + WS    │ │
     │ └─────────┘ │       │ └─────────┘ │       │ └─────────┘ │
     │             │       │             │       │             │
     │ ┌─────────┐ │       │ ┌─────────┐ │       │ ┌─────────┐ │
     │ │JetStream│ │       │ │JetStream│ │       │ │JetStream│ │
     │ │ KV/     │ │       │ │ KV/     │ │       │ │ KV/     │ │
     │ │ Streams │ │       │ │ Streams │ │       │ │ Streams │ │
     │ └─────────┘ │       │ └─────────┘ │       │ └─────────┘ │
     └─────────────┘       └─────────────┘       └─────────────┘
            │                     │                     │
            └──────────┬──────────┴──────────┬──────────┘
                       │                     │
                ┌──────▼──────┐       ┌──────▼──────┐
                │ PostgreSQL  │       │ S3/MinIO    │
                │ (Optional)  │       │ (Files)     │
                └─────────────┘       └─────────────┘
```

### Key Properties

| Property | Implementation |
|----------|---------------|
| **Self-sufficient** | Each node runs full stack: HTTP, WebSocket, NATS, JetStream |
| **Offline-capable** | Local JetStream persistence, queues messages during partition |
| **Auto-clustering** | NATS cluster routes over Tailscale IPs |
| **Graceful degradation** | Node operates alone if cluster unreachable |
| **Eventually consistent** | JetStream replication syncs when nodes reconnect |

---

## Current Implementation Status

### What Exists Today

| Component | Location | Status |
|-----------|----------|--------|
| **Go HTTP Server** | `server/` | Production-ready |
| **WebSocket Bridge** | `server/web/socket.go` | Production-ready |
| **NATS Integration** | `server/main.go` | Supports embedded + NGS |
| **JetStream KV** | `server/core/repoNatsKv.go` | Production-ready |
| **Services** | `server/who/`, `server/urlShort/`, etc. | Production-ready |
| **Lustre Frontend** | `jst_lustre/` | Production-ready |
| **Gleam Server** | `jst_server/` | Experimental |

### Current NATS Architecture

The Go server already supports:
- **Embedded NATS** (`-local` flag) for development/single-node
- **NGS Connection** (production) via JWT/NKEY credentials
- **JetStream KV** for articles, URL shortcuts, chat rooms, auth
- **JetStream Streams** for chat messages
- **NATS Microservices** for who, urlShort, ntfy, convo

---

## Technology Stack

| Layer | Technology | Purpose |
|-------|------------|---------|
| **Frontend** | Lustre (Gleam → JS) | Type-safe SPA with MVU pattern |
| **Web Server** | Go + chi router | HTTP API, static files, WebSocket |
| **Real-time** | WebSocket + NATS bridge | Bidirectional sync with capabilities |
| **Messaging** | NATS + JetStream | Pub/sub, KV, streams, clustering |
| **Persistence** | JetStream KV/Streams | Replicated across cluster |
| **VPN Mesh** | Tailscale | NAT traversal, stable IPs, encryption |
| **File Storage** | S3-compatible | Tigris (Fly.io) or MinIO |
| **Push Notifications** | ntfy.sh | HTTP POSTs from worker |

---

## Fat Node Configuration

### NATS Cluster Configuration

Each fat node runs an embedded NATS server configured for clustering:

```go
// server/conf.go - Fat node NATS configuration
type FatNodeConfig struct {
    NodeName       string   // Unique node identifier
    TailscaleIP    string   // 100.x.x.x address
    ClusterPort    int      // NATS cluster port (default: 6222)
    ClientPort     int      // NATS client port (default: 4222)
    ClusterPeers   []string // Other node Tailscale IPs
    JetStreamStore string   // Local storage path for JetStream
}
```

### NATS Server Options (Embedded)

```go
opts := &server.Options{
    ServerName:   config.NodeName,
    Host:         config.TailscaleIP,
    Port:         config.ClientPort,
    Cluster: server.ClusterOpts{
        Name: "jst-cluster",
        Host: config.TailscaleIP,
        Port: config.ClusterPort,
    },
    Routes: parseRoutes(config.ClusterPeers),
    JetStream:    true,
    StoreDir:     config.JetStreamStore,
}
```

### JetStream Replication

Configure streams and KV buckets for multi-node replication:

```go
// R=3 means replicate across 3 nodes (or all if fewer)
streamConfig := &nats.StreamConfig{
    Name:     "ARTICLES",
    Subjects: []string{"articles.>"},
    Replicas: 3,
    Storage:  nats.FileStorage,
}

kvConfig := &nats.KeyValueConfig{
    Bucket:   "article",
    Replicas: 3,
    Storage:  nats.FileStorage,
}
```

---

## Service Architecture

### Services Run as NATS Microservices

Each service registers with NATS and handles requests via subjects:

| Service | Subject Group | Storage |
|---------|--------------|---------|
| **who** | `svc.who.*` | KV `who_users`, KV `auth.users` |
| **urlShort** | `svc.shorturl.*` | KV `url_short` |
| **articles** | Direct KV | KV `article` |
| **convo** | `svc.convo.*` | KV `convo_room`, Stream `convo_message` |
| **ntfy** | `ntfy.notification` | None (stateless) |

### Request Flow

```
Client → HTTP API → Go Handler → NATS Request → Service → NATS Reply → HTTP Response
                                      ↓
                              JetStream KV/Stream
                                      ↓
                              WebSocket broadcast to subscribers
```

---

## WebSocket Protocol

### Envelope Format

```json
{
  "op": "sub | unsub | kv_sub | js_sub | sub_msg | kv_msg | js_msg | cap_update | error",
  "target": "subject-or-bucket-or-stream",
  "inbox": "optional-correlation-id",
  "data": { }
}
```

### Supported Operations

| Operation | Direction | Purpose |
|-----------|-----------|---------|
| `sub` | Client → Server | Subscribe to NATS subject |
| `unsub` | Client → Server | Unsubscribe |
| `kv_sub` | Client → Server | Watch KV bucket (all or pattern) |
| `js_sub` | Client → Server | Subscribe to JetStream with filter |
| `sub_msg` | Server → Client | NATS subject message |
| `kv_msg` | Server → Client | KV update (put/delete) |
| `js_msg` | Server → Client | JetStream message |
| `cap_update` | Server → Client | Capabilities changed |
| `error` | Server → Client | Error message |

### Capabilities System

Per-user access control using NATS-style wildcards:

```json
{
  "subjects": ["chat.room.*", "articles.>"],
  "buckets": {
    "article": [">"],
    "todos": ["user.123.*"]
  },
  "streams": {
    "convo_message": ["convo_message.room.*"]
  }
}
```

---

## Data Flow Patterns

### 1. HTTP API → WebSocket Sync

All CRUD operations go through HTTP, updates flow through WebSocket:

```
User clicks "Save" → POST /api/article → Handler writes to KV
                                              ↓
                                         KV watcher detects change
                                              ↓
                                         WebSocket broadcasts kv_msg
                                              ↓
                                         All subscribed clients update
```

### 2. Offline Operation

When a node loses cluster connectivity:

```
1. Node continues serving local requests
2. Writes go to local JetStream
3. Reads served from local replica
4. On reconnect:
   - NATS cluster syncs JetStream
   - Newer writes win (last-write-wins for KV)
   - Streams merge by sequence number
```

### 3. Cross-Node Communication

```
User A (Node 1) sends chat message
         ↓
    Publish to convo_message.room.123
         ↓
    JetStream replicates to Node 2, Node 3
         ↓
    WebSocket bridges on all nodes broadcast
         ↓
    User B (Node 2) receives message
```

---

## Networking: Tailscale

### Why Tailscale?

- **NAT Traversal:** Works behind any firewall/router
- **Stable IPs:** 100.x.x.x addresses don't change
- **Encryption:** WireGuard-based, always encrypted
- **Zero Config:** No port forwarding, no firewall rules

### Node Discovery

Nodes discover each other via:
1. **Static config:** List of known Tailscale IPs
2. **Tailscale API:** Query for tagged machines (`tag:jst-node`)
3. **DNS:** `*.jst.tail12345.ts.net` resolves to Tailscale IPs

### Configuration

```bash
# Tag machines for discovery
tailscale up --hostname=jst-fly-1 --advertise-tags=tag:jst-node

# Each node knows cluster peers
CLUSTER_PEERS=100.64.0.1:6222,100.64.0.2:6222,100.64.0.3:6222
```

---

## Implementation Roadmap

### Phase 1: Embedded NATS Clustering (Current Focus)

**Goal:** Enable fat node operation with NATS clustering over Tailscale

| Task | Status | Notes |
|------|--------|-------|
| Embedded NATS server in Go | Done | `-local` and `-fat-node` flags |
| JetStream persistence | Done | File-based storage |
| Cluster configuration | Done | `CLUSTER_PEERS` env var |
| Tailscale IP detection | Done | Auto-detect 100.x.x.x |
| Health check endpoints | Done | `/health/live`, `/health/ready`, `/health/cluster` |
| JetStream retry logic | Done | KV/Stream creation retries for cluster startup |
| Peer discovery | TODO | Config or Tailscale API |
| Graceful partition handling | Partial | Nodes operate independently |

### Phase 2: Replication and Sync

**Goal:** Data consistency across nodes

| Task | Status | Notes |
|------|--------|-------|
| KV bucket replication (R=N) | TODO | Configure per-bucket |
| Stream replication | TODO | Configure per-stream |
| Conflict resolution | TODO | Last-write-wins for KV |
| Sync status monitoring | TODO | Expose via /health |

### Phase 3: Edge Node Support

**Goal:** Raspberry Pi / home server deployment

| Task | Status | Notes |
|------|--------|-------|
| ARM64 builds | TODO | Cross-compile Go |
| Minimal resource mode | TODO | Reduce JetStream memory |
| Offline queue | TODO | Buffer during partition |
| Auto-reconnect | Done | NATS handles this |

### Phase 4: Gleam Server Migration (Optional)

**Goal:** Pure Gleam/BEAM fat nodes

| Task | Status | Notes |
|------|--------|-------|
| NATS client FFI | Partial | `jst_server/nats/enats.gleam` |
| HTTP server | Partial | `jst_server/http_server.gleam` |
| WebSocket bridge | TODO | Port from Go |
| Embedded NATS | Research | May need Go sidecar |

---

## Configuration Reference

### Environment Variables

```bash
# Node identity
NODE_NAME=jst-fly-1           # Unique node name
TAILSCALE_IP=100.64.0.1       # Auto-detected if not set

# NATS clustering
NATS_CLUSTER_NAME=jst-cluster
NATS_CLIENT_PORT=4222
NATS_CLUSTER_PORT=6222
CLUSTER_PEERS=100.64.0.2:6222,100.64.0.3:6222

# JetStream
JETSTREAM_STORE=/data/jetstream
JETSTREAM_MAX_MEM=1GB
JETSTREAM_MAX_FILE=10GB

# Existing config
JWT_SECRET=...
WEB_HASH_SALT=...
NTFY_TOKEN=...
PORT=8080
```

### Runtime Flags

```bash
# Development (single node, embedded NATS, localhost only)
go run . -local -proxy -log debug

# Standalone fat node (embedded NATS, network accessible)
JWT_SECRET=secret WEB_HASH_SALT=salt go run . -fat-node -log info

# Clustered fat nodes (requires CLUSTER_PEERS)
NODE_NAME=node1 JETSTREAM_STORE=/tmp/node1 PORT=8081 NATS_CLIENT_PORT=4222 NATS_CLUSTER_PORT=6222 \
CLUSTER_PEERS=100.64.0.2:6222 JWT_SECRET=secret WEB_HASH_SALT=salt \
go run . -fat-node -log info

# Connect to NGS (legacy, not fat node)
go run . -log info
```

### JetStream Cluster Startup

When running in cluster mode (`CLUSTER_PEERS` set), JetStream requires all nodes to establish routes before the meta leader can be elected. The server handles this by:

1. **NATS server starts** and begins connecting to peers
2. **Services wait with retry logic** - KV buckets and streams are created with up to 60s of retries (30 attempts × 2s delay)
3. **Cluster forms** when majority of nodes are connected
4. **JetStream ready** once meta leader is elected

This allows nodes to start simultaneously without requiring a specific startup order.

---

## Operational Considerations

### Monitoring

```bash
# NATS cluster status
nats server list
nats server info

# JetStream status
nats stream list
nats kv list

# Watch all traffic (debugging)
nats sub ">"
```

### Backup Strategy

JetStream data is stored locally. For backups:

1. **Snapshot JetStream directory:** `$JETSTREAM_STORE`
2. **Export KV buckets:** `nats kv dump bucket-name > backup.json`
3. **Export streams:** `nats stream backup stream-name backup-dir/`

### Failure Modes

| Scenario | Behavior |
|----------|----------|
| Single node down | Other nodes continue, replication maintains data |
| Network partition | Each partition operates independently |
| Partition heals | NATS syncs JetStream, latest writes win |
| All nodes down | Data persists in JetStream files |
| Node rejoins | Catches up via NATS cluster sync |

---

## Project Structure

```
jst_dev/
├── server/                    # Go fat node server
│   ├── main.go               # Entry point, service orchestration
│   ├── conf.go               # Configuration (add fat node config)
│   ├── core/                 # Core utilities
│   │   ├── repoNatsKv.go    # JetStream KV repository
│   │   └── service.go       # Service interface
│   ├── web/                  # HTTP + WebSocket
│   │   ├── routes.go        # HTTP routing
│   │   ├── socket.go        # WebSocket bridge
│   │   └── static/          # Embedded frontend
│   ├── articles/            # Article service
│   ├── urlShort/            # URL shortener service
│   ├── who/                 # Auth/user service
│   ├── convo/               # Chat service
│   └── ntfy/                # Push notification service
├── jst_lustre/              # Gleam/Lustre frontend
│   ├── src/
│   │   ├── jst_lustre.gleam # Main app
│   │   ├── sync.gleam       # WebSocket sync
│   │   └── view/            # UI components
│   └── index.html
├── jst_server/              # Gleam server (experimental)
└── REFACTOR.md              # This document
```

---

## References

### NATS
- [NATS Clustering](https://docs.nats.io/running-a-nats-service/configuration/clustering)
- [JetStream](https://docs.nats.io/nats-concepts/jetstream)
- [Embedded NATS Server](https://github.com/nats-io/nats-server)

### Tailscale
- [Tailscale Documentation](https://tailscale.com/kb/)
- [Tailscale API](https://tailscale.com/api/)

### Project
- [Lustre](https://hexdocs.pm/lustre/)
- [Gleam](https://gleam.run/)
