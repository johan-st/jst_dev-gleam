## IMPLEMENTATION_GUIDE

This guide explains how to implement the unified realtime architecture across backend (Go) and frontend (Gleam/Lustre), aligned with the current repository layout.

- Backend: `server/`
- Frontend: `jst_lustre/`

It complements `ARCHITECTURE_AND_REFACTOR_PLAN.md` with concrete steps, code touchpoints, and commands.

---

## Quick start

- Backend (env + run):
  - Copy `.env_template` to `.env` and fill values
  - Run: `cd server && go run . -proxy -log debug`
- Frontend (dev):
  - Run dev server (hot reload): `cd jst_lustre && gleam run -m lustre/dev start --tailwind-entry=./src/styles.css`
  - Build static to Go app: `cd jst_lustre && gleam run -m lustre/dev build --minify --tailwind-entry=./src/styles.css --outdir=../server/web/static`

---

## Prerequisites

- Go 1.22+
- Gleam 1.3+ and Lustre
- Node (for Tailwind via Lustre dev pipeline)
- NATS account (JWT + NKEY) or use `-local` to run an embedded NATS server
- NATS CLI (optional, for testing): `nats` command

Environment variables (see `server/.env_template`):
- `NATS_JWT` and `NATS_NKEY`: credentials for NGS/global
- `JWT_SECRET`: for server-side JWT signing/verification
- `WEB_HASH_SALT`: for password hashing
- `NTFY_TOKEN`: optional notifications token (currently required by `conf.go`)
- `FLY_APP_NAME`, `PRIMARY_REGION`: used to form app name
- `PORT`: HTTP port

Runtime flags (see `server/conf.go`):
- `-local` run embedded NATS
- `-proxy` proxy frontend to dev server (localhost:1234)
- `-log {debug|info|warn|error|fatal}` set log level

---

## Backend implementation (Go)

The current WebSocket implementation in `server/web/socket.go` provides the unified protocol described in `ARCHITECTURE_AND_REFACTOR_PLAN.md` with NATS Core, KV, and JetStream integration.

**Architecture Decision**: 
- **WebSocket**: Real-time data synchronization and updates only
- **HTTP REST API**: Request-response operations (CRUD, commands, queries)
- **Frontend State**: Updated ONLY from WebSocket subscriptions, never from HTTP responses
- **Fallback**: Long polling if WebSocket issues arise

### 1) Current Implementation Status

- ✅ `server/web/socket.go` - Full WebSocket protocol implementation
- ✅ `server/web/routes.go` - WebSocket endpoint mounted
- ✅ Protocol envelopes and validation implemented
- ✅ Capability model and matching implemented
- ✅ JetStream integration implemented
- ✅ KV integration implemented

**Missing**: Command/reply operations (`cmd`/`reply`) - These will be implemented via HTTP REST API instead
**Note**: HTTP responses won't update frontend state - all updates come through WebSocket

### 2) Protocol envelope and operations

The protocol envelope is fully implemented with operation-specific payloads.

- **Envelope** (implemented):
  - `op`: `"sub" | "unsub" | "kv_sub" | "js_sub" | "cap_update" | "error"`
  - `target`: subject/bucket/stream
  - `inbox`: correlation id (currently unused, planned for future)
  - `data`: operation-specific object

- **Server Operations** (implemented):
  - `sub_msg`: NATS subject messages
  - `kv_msg`: KV update messages with `{op, rev, key, value}`
  - `js_msg`: JetStream messages
  - `cap_update`: Capability updates
  - `error`: Error messages

- **Missing**: `cmd`/`reply` operations for request/response pattern - These will be implemented via HTTP REST API
- **Note**: HTTP responses won't update frontend state - all updates come through WebSocket

### 3) Capabilities

Fully implemented in `server/web/socket.go`:

- **Struct** (implemented):
  - `Subjects []string` - Allowed NATS subjects
  - `Buckets map[string][]string` - bucket pattern → allowed key patterns
  - `Commands []string` - Allowed command targets (currently unused)
  - `Streams map[string][]string` - stream pattern → allowed filter subject patterns

- **Matching** (implemented):
  - Custom NATS-style wildcard matcher (`*`, `>`) implemented in `subjectMatch()` function
  - Pattern matching for subjects, KV buckets, and streams

- **Source** (implemented):
  - JWT-based user identification via `whoApi.JwtVerify` middleware
  - Capabilities fetched from NATS KV bucket `auth.users` key `<user_id>`
  - Real-time capability updates via `watchAuthKV()` with automatic subscription revocation

### 4) Client lifecycle & backpressure

Fully implemented in `rtClient` struct:

- **Fields** (implemented):
  - `ctx`, `cancel` - Context for lifecycle management
  - `sendCh chan serverMsg` (bounded to 256) - Outbound message queue
  - `subs` registry - NATS subscriptions
  - `kvWatchers` registry - KV watchers

- **Writer goroutine** (implemented):
  - `writeLoop()` processes messages from `sendCh`
  - Backpressure: 250ms timeout, then connection closed with error

- **Cleanup** (implemented):
  - Context cancellation on disconnect
  - Automatic cleanup of all NATS subscriptions and KV watchers
  - Proper resource cleanup in `unsubscribeAll()`

### 5) Core subjects (sub/unsub)

Fully implemented:

- **On `sub`** (implemented):
  - `isAllowedSubject(target)` capability check
  - NATS Core subscription created and stored in `client.subs[target]`
  - Messages forwarded as `sub_msg` with `target` and payload

- **On `unsub`** (implemented):
  - Subscription found and properly unsubscribed
  - Registry cleaned up automatically

### 6) Commands (cmd/reply)

**Architecture Decision**: Commands will be implemented via HTTP REST API, not WebSocket.

- **Rationale**: WebSocket is for real-time data synchronization only
- **Implementation**: Standard REST endpoints for all CRUD operations and commands
- **Benefits**: Simpler protocol, better tooling support, standard HTTP semantics
- **Frontend State**: HTTP responses acknowledged but don't update frontend data models
- **Data Flow**: HTTP API → Backend → WebSocket → Frontend state update

**Current status**: Command handling code is commented out in `socket.go`. HTTP REST API will handle all request-response operations.

### 7) KV subscriptions (kv_sub)

Fully implemented:

- **Capability check**: `isAllowedKV(bucket, pattern)` enforced
- **KV bucket acquisition**: Via JetStream API (`js.KeyValue(bucket)`)
- **Pattern support**: `WatchKeys(pattern)` if pattern provided, else `WatchAll()`
- **Event emission**: `kv_msg` with `target: bucket` and `data: {op, rev, key, value}`
- **Registry management**: Watchers stored in `client.kvWatchers[bucket]`
- **Operations supported**: `put`, `delete`, `purge`, `in_sync`

### 8) JetStream subscriptions (js_sub)

Fully implemented:

- **Capability check**: `isAllowedStream(stream, filter)` enforced
- **Consumer creation**: Durable consumer with `BindStream(stream)`
- **Filter support**: `FilterSubject` required (no default fallback)
- **Start position**: `start_seq` support for resume functionality
- **Batch processing**: Configurable batch size (default 50)
- **Message emission**: `js_msg` with `target: stream` and raw message data
- **Acknowledgment**: Automatic `Ack()` after successful send
- **Registry management**: Stored in `client.subs[stream]`
- **Resume support**: Durable consumer naming per user/stream/filter

### 9) Mounting the WebSocket route

Fully implemented:

- **Route**: `GET /ws` endpoint mounted in routes
- **Handler**: `HandleRealtimeWebSocket()` function processes connections
- **Integration**: Direct integration with NATS connection and JetStream context
- **No legacy hub**: Modern implementation without deprecated hub structure

---

## HTTP REST API Implementation

### Overview
All request-response operations (CRUD, commands, queries) will use standard HTTP REST API endpoints instead of WebSocket commands.

### Planned Endpoints

#### Articles
- `GET /api/articles` - List all articles
- `GET /api/articles/{id}` - Get specific article
- `POST /api/articles` - Create new article
- `PUT /api/articles/{id}` - Update article
- `DELETE /api/articles/{id}` - Delete article
- `GET /api/articles/{id}/revisions` - Get article revision history
- `GET /api/articles/{id}/revisions/{revision}` - Get specific revision

#### Authentication
- `POST /api/auth/login` - User login
- `POST /api/auth/logout` - User logout
- `GET /api/auth/me` - Get current user info

#### User Management
- `GET /api/users` - List users (admin only)
- `POST /api/users` - Create user (admin only)
- `PUT /api/users/{id}` - Update user
- `DELETE /api/users/{id}` - Delete user (admin only)

#### Commands
- `POST /api/commands/{command}` - Execute business command
  - Example: `POST /api/commands/publish-article` with article ID in body

### Benefits of HTTP REST API
- **Standard Semantics**: Familiar HTTP methods and status codes
- **Better Tooling**: Standard HTTP clients, testing tools, documentation
- **Caching**: HTTP caching headers and CDN support
- **Security**: Standard HTTP security practices and middleware
- **Monitoring**: Standard HTTP metrics and logging

---

## Data Flow and State Management

### Architecture Principles
1. **WebSocket Only for State Updates**: All frontend data model changes come through WebSocket subscriptions
2. **HTTP for Operations**: HTTP REST API handles all CRUD operations and commands
3. **No HTTP State Updates**: HTTP responses confirm success but don't modify frontend data
4. **Real-time Sync**: Changes made via HTTP automatically appear through WebSocket

### Implementation Pattern
```
User Action → HTTP API → Backend → Database → WebSocket → Frontend State Update
```

### Benefits
- **Consistent State**: Single source of truth from WebSocket
- **Real-time Updates**: Immediate UI updates without manual state management
- **Clean Separation**: HTTP for operations, WebSocket for data sync
- **Fallback Ready**: Can implement long polling if WebSocket issues arise

---

## Frontend implementation (Gleam/Lustre)

`src/sync.gleam` exists and provides KV-focused WebSocket functionality.

### 1) Model and API

- **Model fields** (implemented):
  - `id: String` - Unique subscription identifier
  - `state: KVState` - Connection and sync state
  - `bucket: String` - KV bucket name
  - `filter: Option(String)` - Optional key pattern filter
  - `revision: Int` - Current revision number
  - `data: Dict(key, value)` - Local data cache
  - **Missing**: Subject subscriptions, JetStream subscriptions, capabilities

**Note**: This module handles KV data synchronization. HTTP operations are handled separately.

- **Public helpers** (current implementation):
  - ✅ `connect(path: String) -> Effect(Msg)` - Connect to WebSocket
  - ✅ `subscribe(subject: String) -> Effect(Msg)` - Subscribe to NATS subject
  - ✅ `kv_subscribe(bucket: String) -> Effect(Msg)` - Subscribe to KV bucket
  - ❌ `kv_subscribe_pattern(bucket: String, pattern: String)` - Not implemented
  - ❌ `js_subscribe(stream: String, start_seq: Int, batch: Int, filter: String)` - Not implemented
  - ❌ `js_resume(stream: String, last_seq: Int, batch: Int, filter: String)` - Not implemented
  - ❌ `send_command(target: String, payload: json.Json, cb: fn(json.Json) -> Msg)` - **Will use HTTP REST API instead**
  - **Note**: HTTP operations handled separately, WebSocket only for data sync

- **Message handling** (partially implemented):
  - ✅ WebSocket text message parsing
  - ✅ Basic message routing
  - ❌ `reply` handling - Not implemented (no `pending_cmds`) - **Will use HTTP REST API instead**
- **Note**: No reply handling needed - WebSocket only for data sync
  - ❌ `cap_update` handling - Not implemented (no capabilities field)
  - ❌ `error` handling - Basic error dispatch exists

### 2) Socket lifecycle

Fully implemented:

- **Connection**: `ws://<host>/ws` with JWT cookies
- **Auto-subscription**: On connect, automatically resubscribes to all subjects and KV buckets
- **Reconnection**: Exponential backoff with automatic retry
- **Resubscription**: Core subjects and KV buckets automatically resubscribed on reconnect
- **Missing**: JetStream resume with `last_seq` not implemented
- **Fallback Strategy**: Long polling can be implemented if WebSocket connection issues persist

### 3) Integration into current app

Partially implemented:

- **Model integration**: `sync.gleam` KV types used for data synchronization
- **Initialization**: Basic KV subscription initialization in place
- **Event mapping**: WebSocket message handling for KV updates implemented
- **Missing**: Subject subscriptions integration not implemented
- **Missing**: JetStream subscriptions integration not implemented

### 4) Encoding/decoding

Partially implemented:

- **Envelope encoding**: Basic envelope creation for `sub`, `kv_sub` operations
- **Message parsing**: WebSocket text message parsing implemented
- **Missing**: Full envelope encoding/decoding for all operations
- **Missing**: `reply`, `cap_update` message handling
- **Missing**: Unit tests for codec definitions

---

## Configuration and deployment

- Local development:
  - With embedded NATS: `cd server && go run . -local -proxy -log debug`
  - Frontend dev server (hot reload): `cd jst_lustre && gleam run -m lustre/dev start --tailwind-entry=./src/styles.css`
  - Go server proxies `GET /` and static to `http://127.0.0.1:1234` in `-proxy` mode (see `routes.go`)

- Static build for production:
  - `cd jst_lustre && gleam run -m lustre/dev build --minify --tailwind-entry=./src/styles.css --outdir=../server/web/static`
  - Start server without `-proxy` so embedded static is served

- Env var notes (`server/conf.go`):
  - All required env vars must be set; current code treats `NTFY_TOKEN` as required
  - HTTP server binds to `0.0.0.0:8080` (see `web/web.go`)

---

## Testing and validation

- **Core subject subscription** ❌ Not implemented
  - Subject subscriptions not yet implemented in frontend
  - Backend supports it but frontend uses `sync.gleam` for KV only

- **Command/reply** ❌ Not implemented
  - Command handling code is commented out in `socket.go`
  - **Architecture**: Commands will use HTTP REST API instead of WebSocket

- **KV subscription** ✅ Testable
  - Create bucket: `nats kv add todos`
  - Frontend: Uses `sync.gleam` KV types for subscription
  - CLI: `nats kv put TODOS user.123.task1 '{"done":false}'` and verify `kv_msg` event

- **JetStream subscription** ❌ Not implemented
  - Backend supports it but frontend not yet implemented
  - Will need to extend `sync.gleam` or create separate module

- Backpressure
  - Temporarily reduce `sendCh` buffer and inject large bursts; verify connection closes after the configured timeout with an `error`

- **Capabilities** ✅ Testable
  - Seed capabilities into KV (e.g., bucket `auth.users`, key `<user_id>`)
  - Connect as the user; verify allowed vs denied operations and that `cap_update` triggers revocations

---

## HTTP REST API Testing

- **CRUD Operations** - Test all article endpoints
- **Authentication** - Test login/logout and JWT validation
- **Authorization** - Test permission-based access control
- **User Management** - Test user CRUD operations
- **Commands** - Test business command endpoints

---

## Migration notes (from current WS types)

- ✅ **Completed**: The existing `WebSocketMessage{ Type, Topic, Data, ... }` and `MsgType*` constants have been replaced by the unified envelope (`op`, `target`, `data`, ...)
- ✅ **Completed**: Modern implementation without deprecated hub structure (`Hub`, `Client`, `readPump`, `writePump`)
- ✅ **Completed**: Protocol parsing/dispatch implemented in `readLoop()` and `handleMessage` functions
- ✅ **Completed**: No legacy handling needed - clean implementation

---

## Reference locations in repo

- Backend entrypoint: `server/main.go`
- HTTP server and routing: `server/web/web.go`, `server/web/routes.go`
- WebSocket implementation: `server/web/socket.go`
- Frontend entry HTML: `jst_lustre/index.html`
- Frontend app: `jst_lustre/src/jst_lustre.gleam`
- Frontend sync: `jst_lustre/src/sync.gleam`
- Frontend session/auth: `jst_lustre/src/session.gleam`

---

## Future work

### WebSocket Enhancements
- Time-based resume for JetStream when `last_seq == 0`
- Durable consumer naming per user/session and stream
- At-least-once delivery with explicit acks and retry loops
- Protocol versioning in envelope to allow incremental evolution
- Heartbeat ops (`ping/pong`) at the protocol level for fast dead-connection detection

### HTTP REST API
- Implement all planned endpoints (articles, auth, users, commands)
- Add comprehensive JWT authorization and permission system
- Consider implementing WebSocket commands in the future for real-time command execution

---

## Design rationale (why these choices)

- Evan Czaplicki’s “Life of a File”
  - Keep infra in one place (`realtime.gleam`) and let each domain own its state machine (data + logic + view) to avoid premature fragmentation. This reduces cross-file hops and makes updates localized.

- modem + plinth
  - Routing and SPA boot are handled by dedicated libraries so the realtime layer remains orthogonal. Domains consume `Event`s from `realtime` and render; routing stays pure.

- Unified envelope (op/target/inbox/data)
  - A single shape across sub/unsub/kv_sub/js_sub/cmd/reply/msg avoids ad-hoc handlers and makes client/server evolvable. `inbox` is client-side correlation only; never used as a NATS subject.

- Capabilities as patterns
  - Subjects, KV keys, and JS filter subjects are governed by NATS-style wildcards (`*`, `>`). This gives least-privilege control without enumerating every resource.
  - Example check (Go):

```go
func matchPattern(pattern, subject string) bool {
  ok, err := nats.Match(pattern, subject)
  return err == nil && ok
}
```

- Auth change handling via Auth KV watch
  - Watching `auth.users/<user_id>` ensures revocation and grants apply mid-connection. On change, we diff, revoke live subs, and push `cap_update` to the client.

- KV as projections (WatchAll/WatchKeys)
  - KV provides full-state hydration plus incremental updates. `WatchKeys(pattern)` reduces noise and bandwidth when only a subset is needed.

- JetStream resumeability and pagination
  - Default to sequence-based resume so domains can reliably “pick up where we left off”. Store `last_seq` in domain models.
  - Optional filter subjects let consumers focus on a slice of the stream (e.g., `chat.room.123`).
  - Time-based resume is a pragmatic fallback when `last_seq` is 0.

- Command correlation with client-generated inbox
  - The client sets `inbox` for correlation over WebSocket; server echoes it in `reply`. Server uses `nats.RequestWithContext` internally; the client token is never used as a NATS subject.

```go
// reply with echoed inbox
c.send(ServerMsg{ Op: "reply", Target: target, Inbox: inbox, Data: payload })
```

- Backpressure policy
  - A bounded `sendCh` with a 250 ms enqueue timeout guards server resources and prevents head-of-line blocking. If blocked, we send a terminal error frame and close.

```go
select {
case c.sendCh <- msg:
case <-time.After(250 * time.Millisecond):
  c.closeWithError("backpressure timeout")
}
```

- Context propagation and cleanup
  - All goroutines (KV watchers, JS subs, command requests) are tied to `Client.ctx`. Disconnect cancels context to ensure drains and resource release.

- Domain-responsible sequence tracking (frontend)
  - Domains persist `last_seq` and use `js_resume(stream, last_seq, batch, filter)` after reconnects so history gaps are avoided without server-side state.

- Simplicity first, durability as needed
  - Start with ephemeral subs and client-held resume; add durable consumers for long-lived or mission-critical feeds where pagination/rewind is required.

