# REFACTOR.md - Architecture and Refactoring Plan

## Overview

This document outlines the recommended architecture for building a full-stack Gleam application with SSR, real-time communication, and distributed node support across high-latency networks.

## Target Requirements

- Multiple servers with high latency tolerance
- Nodes that can fall off and reconnect
- Nodes outside of Fly.io network (edge nodes, home servers, etc.)
- Support for: chat, collaborative editing, document sharing, URL shortener, push notifications (ntfy.sh), planning, scheduled tasks, IoT telemetry

---

## Part 1: Single-Server Full-Stack Gleam

### The Core Stack (Basic)

For a simple full-stack Gleam application:

| Component | Technology | Purpose |
|-----------|------------|---------|
| **Language** | Gleam | Type safety, runs on BEAM |
| **Frontend & SSR** | Lustre | Standard Gleam frontend framework. Use `lustre_server` for SSR. Renders initial HTML on server, "hydrates" on client. |
| **Web Server** | Wisp | Lightweight, composable web framework for Gleam. Handles routing and middleware. |
| **Real-Time** | Mist | Erlang-based HTTP/WebSocket server for Gleam. Best choice for persistent WebSocket connections. |
| **Database** | PostgreSQL | Use `pgo` or `gleam_pgo` library. Robust, integrates well with BEAM connection pooling. |
| **Build Tool** | Gleam's built-in | Manages dependencies, compiles to both Erlang (server) and JavaScript (frontend). |

### Basic Deployment Platforms

- **Fly.io (Recommended):** Industry leaders for deploying BEAM languages. Native support for clustering nodes globally.
- **Railway:** Excellent for quick deployments via Docker. Developer-friendly UI.
- **Hetzner/DigitalOcean:** For self-managed VPS. Containerize with Docker.

### Basic Architectural Strategy

1. **Isomorphic Logic:** Write business logic and types once in Gleam, share between server and frontend.
2. **Asset Pipeline:** Use `lustre dev` for local development. For production, bundle compiled JavaScript (via `esbuild` or `Vite`) and serve through Wisp.
3. **State Management:** Use Lustre's Model-View-Update (MVU) pattern. For real-time updates, server pushes messages over WebSockets (Mist), which Lustre frontend receives as `Msg`s.

---

## Part 2: Multi-Server Architecture (Distributed)

When deploying to multiple servers, clients connected to Server A need to receive messages sent by clients on Server B.

### Multi-Node Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| **Networking** | Mist | Best choice for WebSockets |
| **Clustering** | Fly.io | Easiest for BEAM distribution - provides private IPv6 networking for automatic node discovery |
| **PubSub/Registry** | [Glyn](https://github.com/mbuhot/glyn) | Type-safe wrapper around `syn` (Erlang library). Handles global process registration and message broadcasting across cluster. |

### Why Glyn is Critical

Without Glyn (or similar), messages are "trapped" on a single server. Glyn ensures that when you publish a "chat_message," it is delivered to subscribers on **all nodes**.

### Frontend & SSR Strategy (Multi-Node)

1. **SSR:** Wisp renders initial HTML using `lustre.to_html`
2. **Hydration:** Client-side Lustre app takes over for immediate UI responsiveness
3. **Sync:** Lustre runtime handles WebSocket messages. When a message arrives from Glyn (via server), server pushes it to specific client's Lustre runtime to update UI.

### Data Consistency

- **Database:** PostgreSQL
- **Connection Pooling:** `gleam_pgo`
- **Primary/Replica:** For globally distributed servers, use Fly.io's "Regional Read Replicas" for low latency reads, always write to primary.

### Deployment (Multi-Node)

- **Infrastructure:** Fly.io is essential for "multi-server real-time Gleam"
- **Sticky Sessions:** `fly-proxy` handles sticky sessions and WebSocket connections
- **Clustering:** Internal DNS allows Gleam nodes to form cluster using `libcluster` (via Erlang interop)
- **CI/CD:** Docker-based workflow. Gleam build tool generates Erlang release that fits in small Alpine Linux container.

---

## Part 3: High-Latency Edge Networks

Building a Gleam application that remains stable over **high-latency, intermittent networks with nodes outside a controlled data center** is a specialized challenge. Standard Distributed Erlang is notorious for being "chatty" and sensitive to latency.

### The Problem with Standard Distributed Erlang (`disterl`)

- Uses a "full mesh" topology (every node talks to every other node)
- Heartbeats frequently
- If a heartbeat is missed due to latency, the node is kicked
- Not designed for WAN or residential internet "jitter"

### Networking Foundation: Tailscale + Partisan

Instead of standard Distributed Erlang, use **Partisan**:

| Component | Technology | Purpose |
|-----------|------------|---------|
| **VPN Layer** | Tailscale | Creates "fake local network". Handles NAT traversal. Provides stable, encrypted IP (100.x.x.x range) for each node regardless of physical location. |
| **Distribution Layer** | Partisan | Drop-in replacement for Erlang distribution layer. Designed specifically for high-latency and large-scale clusters. |

#### Why Partisan?

- Standard Erlang distribution uses full mesh + frequent heartbeats
- **Partisan** allows different topologies (client-server, peer-to-peer)
- Far more resilient to "jitter" of residential internet
- **Gleam Note:** Requires Erlang interop wrapper to initialize Partisan (most Gleam-native clustering libraries like Barnacle default to standard `disterl`)

### Service Discovery: Barnacle

For handling nodes falling off and coming back:

- **Barnacle:** Gleam-native library for self-healing clusters
- Polls a source (DNS record, static list of Tailscale IPs, or specialized "discovery" node)
- Automatically attempts reconnection when node becomes reachable again
- **Strategy:** Configure Barnacle to use Tailscale IPs. Since Tailscale IPs are static for machine lifetime, Barnacle can keep retrying.

### Real-Time State Sync: Versioned Update Pattern

Over high latency, simple message passing isn't enough - messages might arrive out of order or be delayed by seconds.

**Strategy:**
- Every piece of state (counter, chat message list, etc.) has a **Version ID**
- Lustre frontend maintains local "optimistic" state but checks Version ID of incoming messages
- **Conflict Resolution:** If Node A is offline for 10 minutes, when it reconnects, it shouldn't blast its old state. Use a **Reconciliation Loop**: node asks for "Everything since Version X" when it recovers.

### Edge-First Stack Summary

| Component | Technology |
|-----------|------------|
| **Language** | Gleam |
| **Web Server** | Wisp + Mist |
| **Frontend/SSR** | Lustre |
| **VPN Layer** | Tailscale |
| **Distribution Layer** | **Partisan** (Erlang) |
| **Clustering/Healing** | **Barnacle** (Gleam) |
| **Database** | PostgreSQL (Centralized) |

### Erlang Interop for Distribution

Example snippet to enable distribution:

```gleam
// Example snippet to enable distribution
pub fn start_distribution(name: String) {
  // Use Erlang's net_kernel to allow this node to be discovered
  // This is what allows Glyn/Syn to work across servers.
}
```

**Critical Caveat:** Using Partisan in Gleam requires Erlang knowledge - you'll be calling `:partisan.start()` and configuring via Erlang terms.

---

## Part 4: Gleam/BEAM vs Go + NATS Comparison

### Head-to-Head Comparison

| Dimension | Gleam/BEAM + Partisan | Go + Embedded NATS |
|-----------|----------------------|-------------------|
| **Latency Tolerance** | Partisan is designed for WAN, but niche. | NATS is purpose-built for WAN/edge. Industry-proven. |
| **Node Churn (Join/Leave)** | Barnacle handles it, but needs tuning. | NATS clustering handles this out-of-the-box. |
| **Fault Tolerance** | **BEAM wins.** Supervision trees are legendary. A single crash doesn't bring down the node. | You build this yourself. Goroutines can panic; recovery is manual. |
| **Message Guarantees** | Actor mailboxes are "at-most-once" by default. You add persistence yourself. | **NATS JetStream wins.** At-least-once, exactly-once, persistent streams built-in. |
| **Operational Maturity** | Partisan is niche. Limited tooling, docs, and community knowledge. | **NATS wins.** Excellent CLI, monitoring, Grafana dashboards, massive community. |
| **Developer Availability** | Gleam is tiny. Erlang is small. Hard to hire. | **Go wins.** Massive talent pool. Easy to onboard. |
| **Explicit vs. Implicit** | "Magic." Processes message each other transparently across nodes. Powerful but opaque. | Explicit pub/sub on named subjects. Easier to reason about and debug. |
| **Ecosystem** | Small but growing. | Huge. NATS has clients in every language. |
| **Debugging** | Harder. Distributed actor state is opaque. | Easier. You can inspect NATS subjects and streams directly. |

### The Core Trade-off

| Aspect | Gleam/BEAM | Go + NATS |
|--------|------------|-----------|
| **Philosophy** | "Let it crash." The runtime recovers. | "Don't crash." You handle errors explicitly. |
| **Abstraction** | High. Processes and message passing are first-class. | Low. You manage goroutines, channels, and NATS subjects. |
| **Debugging** | Harder. Distributed actor state is opaque. | Easier. You can inspect NATS subjects and streams directly. |

### When to Choose Each

**Choose Go + NATS if:**
- You need proven, battle-tested WAN clustering *today*
- Your team (or future hires) are more likely to know Go
- You want persistence (JetStream) without building it yourself
- Operational simplicity matters - NATS tooling is excellent

**Choose Gleam/BEAM + Partisan if:**
- Building something where **fine-grained fault tolerance** is critical (e.g., thousands of independent stateful "actors" that must not take each other down)
- You value the elegance of the actor model and are willing to invest in the learning curve
- You want to bet on Gleam's future and are comfortable being an early adopter
- Hot code reloading (updating code without dropping connections) is a requirement

---

## Part 5: Recommended Architecture - Hybrid Gleam + NATS

For the target requirements (chat, document sharing, URL shortener, push notifications, planning, scheduled tasks, collaborative editing, IoT telemetry), you're building a **personal/team infrastructure platform**, not a single app.

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        NATS (JetStream)                         │
│                  The backbone. Connects everything.             │
└───────────┬─────────────────┬─────────────────┬─────────────────┘
            │                 │                 │
     ┌──────▼──────┐   ┌──────▼──────┐   ┌──────▼──────┐
     │ Gleam Node  │   │ Gleam Node  │   │  Edge Node  │
     │ (Fly.io)    │   │ (Hetzner)   │   │ (Home RPi)  │
     │             │   │             │   │             │
     │ - Lustre UI │   │ - Workers   │   │ - Local     │
     │ - SSR       │   │ - Scheduler │   │   cache     │
     │ - WebSocket │   │ - ntfy.sh   │   │ - Offline   │
     │   (Mist)    │   │   push      │   │   queue     │
     └─────────────┘   └─────────────┘   └─────────────┘
            │                 │                 │
            └────────────┬────┴─────────────────┘
                         │
                  ┌──────▼──────┐
                  │ PostgreSQL  │
                  │ + S3 (files)│
                  └─────────────┘
```

### The Full Stack

| Layer | Technology |
|-------|------------|
| **Frontend** | Lustre (Gleam → JS) |
| **Web Server** | Wisp + Mist (Gleam) |
| **Messaging Backbone** | **NATS + JetStream** |
| **NATS Client (Gleam)** | Erlang's `nats.erl` via FFI |
| **Collaborative Editing** | **Yjs** (JS CRDT library, mature) – embed in Lustre |
| **VPN Mesh** | Tailscale |
| **Database** | PostgreSQL |
| **File Storage** | S3-compatible (Tigris on Fly.io, or MinIO self-hosted) |
| **Push Notifications** | ntfy.sh (just HTTP POSTs from a worker) |
| **Deployment (Core)** | Fly.io |
| **Deployment (Edge)** | Anything with Docker + Tailscale |

### Why NATS Becomes Essential at This Scale

| Feature | How NATS Helps |
|---------|----------------|
| **Scheduled Tasks** | JetStream + consumers with delayed delivery. No external cron needed. |
| **Collaborative Editing** | Publish edits to a subject per document. All nodes see all edits. |
| **Push Notifications** | Worker subscribes to `notifications.>`, calls ntfy.sh. |
| **URL Shortener** | NATS KV store for fast lookups (or just PostgreSQL). |
| **Document Sharing** | Metadata in NATS/Postgres, blobs in S3. |
| **Offline Edge Nodes** | NATS client queues messages locally, syncs when reconnected. |
| **Chat** | Classic pub/sub. Trivial with NATS. |

---

## Part 6: Key Architectural Patterns

### 1. Event Sourcing via JetStream

Every action (create doc, shorten URL, send message) becomes an event in a stream. Nodes subscribe and build local views.

```
Streams:
  - DOCUMENTS.created
  - DOCUMENTS.edited
  - URLS.shortened
  - TASKS.scheduled
  - CHAT.room.{id}
```

### 2. Offline-First Edge Nodes

Use the NATS client's built-in buffering. When a home RPi loses connection, messages queue locally. On reconnect, they flush to JetStream.

### 3. Collaborative Editing with Yjs

Yjs is the industry standard. It runs in the browser (integrates with Lustre) and syncs via a provider. You can write a **NATS sync provider** so edits flow through your existing backbone instead of a separate WebSocket server.

### 4. Scheduled Tasks Pattern

```
1. Publish to TASKS.schedule with a "run_at" header.
2. A worker consumes from TASKS.schedule with delayed ack.
3. At "run_at" time, worker executes and acks.
```

JetStream handles retry, persistence, and exactly-once delivery.

---

## Part 7: Trade-offs Analysis

### What You Lose by Not Going Pure BEAM

| Feature | Workaround |
|---------|------------|
| Hot code reloading | Rolling deploys via Fly.io (seconds of downtime). |
| Supervision trees | Design Gleam services to be stateless; let NATS handle recovery. |
| Actor model elegance | Explicit pub/sub subjects. More verbose, but clearer. |

### What You Gain

- **Operational sanity.** NATS has a CLI (`nats` command), Grafana dashboards, and excellent docs.
- **Polyglot future.** Need a Rust node for video transcoding? It just connects to NATS.
- **Proven at scale.** Synadia (NATS creators) run global deployments.
- **Simpler debugging.** `nats sub ">"` shows all traffic. No distributed actor tracing.

---

## Part 8: The Hybrid Option

You could use **Gleam/Lustre for the frontend and web layer** (where its type safety shines) and **Go + NATS as the "backbone"** for inter-node communication. The Gleam nodes would simply be NATS clients. This gives you:

- NATS's proven WAN clustering
- Gleam's type-safe, pleasant frontend DX
- Flexibility to have non-Gleam nodes (Python, Rust, etc.) participate easily

**Bottom Line:** For the specific requirements (high latency, nodes dropping, nodes outside Fly.io), Go + NATS is the more pragmatic and operationally mature choice. The BEAM is theoretically superior for fault tolerance, but realizing that advantage requires deep expertise.

---

## Part 9: Implementation Next Steps

1. **Prototype the NATS ↔ Gleam bridge.** Wrap `nats.erl` in a Gleam module.
2. **Set up Tailscale + a 3-node NATS cluster** (2 on Fly, 1 on a home machine).
3. **Build the simplest feature first** (URL shortener) to validate the full loop: Lustre → Wisp → NATS → Postgres → Response.
4. **Add Yjs** for collaborative editing once the backbone is stable.

---

## Part 10: Networking with Tailscale

Use Tailscale to create a "fake local network":

- Handles NAT traversal
- Provides stable, encrypted IPs (100.x.x.x range) for each node
- Works regardless of physical location
- Static IPs for the life of the machine (Barnacle/NATS can keep retrying)

### Deployment Strategy

- **Central Hub:** Fly.io (for core database and stable nodes)
- **Edge Nodes:** Any VPS (Hetzner, DigitalOcean) or Raspberry Pis running Tailscale
- **Coordination:** Tailscale hosted admin or self-hosted coordination server

---

## Part 11: Project Structure Recommendation

### Ideal Monorepo for Full-Stack Gleam

Gleam works best with a three-project monorepo:

1. `shared/` - Data types, validation logic, JSON encoders/decoders
2. `client/` - Lustre frontend (compiles to JS)
3. `server/` - Wisp/Mist/Glyn server (compiles to Erlang)

### Current Structure in This Repo

- `jst_lustre/` - Lustre frontend
- `jst_server/` - Gleam server (currently minimal)
- `server/` - Go server with NATS integration (existing backbone)

---

## References

### Core Technologies
- [Gleam](https://gleam.run/)
- [Lustre](https://hexdocs.pm/lustre/)
- [Wisp](https://hexdocs.pm/wisp/)
- [Mist](https://hexdocs.pm/mist/)

### Distributed Systems
- [NATS Documentation](https://docs.nats.io/)
- [JetStream](https://docs.nats.io/nats-concepts/jetstream)
- [Glyn (Gleam clustering)](https://github.com/mbuhot/glyn)
- [Barnacle (Gleam self-healing clusters)](https://hexdocs.pm/barnacle/)
- [Partisan (WAN-tolerant Erlang distribution)](https://github.com/lasp-lang/partisan)

### Collaborative Editing
- [Yjs](https://yjs.dev/)
- [Electric SQL](https://electric-sql.com/)

### Infrastructure
- [Tailscale](https://tailscale.com/)
- [Fly.io](https://fly.io/)
- [ntfy.sh](https://ntfy.sh/)

### Database
- [gleam_pgo](https://hexdocs.pm/gleam_pgo/)
