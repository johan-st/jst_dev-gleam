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

The current WebSocket implementation in `server/web/socket.go` provides a hub with simple message types (`connect|subscribe|unsubscribe|auth|sync|data|error`). We will evolve it to the unified protocol described in `ARCHITECTURE_AND_REFACTOR_PLAN.md` while preserving the hub model and integrating NATS Core, KV, and JetStream.

### 1) Files to add/modify

- Modify: `server/web/socket.go`
- Modify: `server/web/routes.go` (ensure WS endpoint mounted)
- Add: `server/web/realtime_protocol.go` (protocol envelopes, validation, helpers)
- Add: `server/web/capabilities.go` (capability model + matching)
- Optional: `server/web/js_bridge.go` (JetStream helpers)
- Optional: `server/web/kv_bridge.go` (KV helpers)

### 2) Protocol envelope and operations

Add a canonical envelope type and operation-specific payloads.

- Envelope:
  - `op`: `"sub" | "unsub" | "kv_sub" | "js_sub" | "cmd" | "msg" | "reply" | "cap_update" | "error"`
  - `target`: subject/bucket/stream
  - `inbox`: correlation id (for `cmd`/`reply`)
  - `data`: operation-specific object

- Parsing/validation:
  - Validate allowed operations and required fields; return `error` if invalid.
  - Include a small `version` (e.g. `v: 1`) for forward-compat.

- Backward compatibility:
  - Optionally continue accepting legacy `type` messages for a deprecation window.

### 3) Capabilities

Create `server/web/capabilities.go`:

- Struct:
  - `Subjects []string`
  - `Buckets map[string][]string` // bucket pattern -> allowed key patterns
  - `Commands []string`
  - `Streams map[string][]string` // stream pattern -> allowed filter subject patterns

- Matching:
  - Use NATS-style wildcard matcher (`*`, `>`). You can implement with `nats.Match`-like semantics. For buckets/streams, treat keys and filter subjects as subjects.

- Source:
  - Upon WS connect, derive user subject from JWT via `authJwt` middleware context (see `routes.go`, `whoApi.JwtVerify`).
  - Fetch JSON capability from NATS KV (e.g., bucket `auth.users` key `<subject>`). If absent, default deny.
  - Watch the capability key for updates; on change, compute diff, revoke disallowed subs, then send `cap_update`.

### 4) Client lifecycle & backpressure

Extend `Client` in `socket.go`:

- Fields: `ctx`, `cancel`, `sendCh chan []byte` (bounded), `subs` registry (core, kv, js), `lastActive` timestamp
- Writer goroutine:
  - Writes from `sendCh` with a 10s write deadline (already present)
  - Backpressure: if enqueue blocks > 250ms, send an `error` frame and close the connection

Cleanup on disconnect:
- Cancel context, drain/close all NATS subscriptions, KV watchers, and JS consumers

### 5) Core subjects (sub/unsub)

- On `sub`:
  - Check `isAllowedSubject(target)`
  - Create NATS Core subscription and store handle under `client.subs.core[target]`
  - Forward each message as `msg` with `target` and payload bytes (or JSON decoded if you standardize)

- On `unsub`:
  - Find and drain/Unsubscribe handle; remove from registry

### 6) Commands (cmd/reply)

- On `cmd`:
  - Check `isAllowedCommand(target)`
  - Use `nats.RequestWithContext` to send to `target`
  - On reply, emit `reply` with the same `inbox` and the response payload
  - On timeout/error, emit `error` with context and matching `inbox`

### 7) KV subscriptions (kv_sub)

- Check `isAllowedKV(bucket, pattern)`
- Acquire KV bucket via JetStream API (`js.KeyValue(bucket)`) and create a watcher:
  - If `pattern` provided, use `WatchKeys(pattern)`; else `WatchAll()`
- For each event, emit `msg` with `target: "kv:<bucket>"` and `data: { key, revision, op, value }`
- Store watcher cancel in registry `client.subs.kv[bucket:pattern]`

### 8) JetStream subscriptions (js_sub)

- Check `isAllowedStream(stream, filter)`
- Create a consumer (durable or ephemeral); set:
  - `FilterSubject` if `filter` provided
  - Start position by `start_seq` (sequence start) or default to latest
  - Pull with `batch` size; loop fetch and forward messages
- Emit `msg` frames with `{ seq, subject, payload }`
- If using at-least-once, `Ack()` after successful send
- Store consumer context in `client.subs.js[stream:filter]`, including last delivered `seq` for resume

### 9) Mounting the WebSocket route

- Ensure a WS handler is mounted (either legacy or new). Example:
  - `mux.HandleFunc("GET /ws", func(w,r){ HandleWebSocket(hub, w, r) })`
- `web.New` already sets up a `SyncService`/hub; you can migrate that hub to use the new protocol types and handlers.

---

## Frontend implementation (Gleam/Lustre)

Create `src/realtime.gleam` as a small infrastructure module and wire it into the app model.

### 1) Model and API

- Model fields (suggested):
  - `socket: Option(websocket.Connection)`
  - `subs: List(String)` (core subjects)
  - `kv_subs: List(String)` (bucket or bucket:pattern)
  - `js_subs: List(#(String, Int, Int, String))` // stream, start_seq, batch, filter
  - `pending_cmds: map.Map(String, fn(json.Json) -> Msg)` // inbox -> callback
  - `caps: Option(json.Json)` (or a typed capability struct)

- Public helpers:
  - `connect(base_uri: Uri) -> Effect(Msg)`
  - `subscribe(subject: String) -> Effect(Msg)`
  - `kv_subscribe(bucket: String) -> Effect(Msg)`
  - `kv_subscribe_pattern(bucket: String, pattern: String) -> Effect(Msg)`
  - `js_subscribe(stream: String, start_seq: Int, batch: Int, filter: String) -> Effect(Msg)`
  - `js_resume(stream: String, last_seq: Int, batch: Int, filter: String) -> Effect(Msg)`
  - `send_command(target: String, payload: json.Json, cb: fn(json.Json) -> Msg) -> Effect(Msg)`

- Message handling:
  - On `msg` from server: route by `target` prefix (`kv:` / `js:` / subject) and decode payload into domain messages
  - On `reply`: `lookup inbox` in `pending_cmds` and dispatch callback
  - On `cap_update`: update local capabilities, optionally prompt UI
  - On `error`: dispatch a global error notification

### 2) Socket lifecycle

- Connect to `ws(s)://<host>/ws`. Cookies include the JWT set by the server auth.
- On open, optionally send a small `hello` if you choose to keep a client-initiated auth or sync message; otherwise wait for `cap_update` from server.
- Reconnect with exponential backoff; on reconnect, resubscribe core subjects and resume JetStream with `last_seq` per stream.

### 3) Integration into current app

- `src/jst_lustre.gleam` is monolithic; start by:
  - Adding `realtime.Model` inside the app `Model`
  - Initializing it in `init`
  - Mapping socket events to app `Msg` via a small adapter
  - Storing per-domain `last_seq` as needed (e.g., chat, audit)

- For TEA refactor (see `TEA.md` and `REFACTOR.md`):
  - If you adopt the page-as-child structure, expose a `subscriptions(model)` per page that needs realtime and `Effect.map` to shell.

### 4) Encoding/decoding

- Create JSON encoders for the envelope:
  - `op`, `target`, `inbox` (when `cmd`), and `data`
- Create decoders for server `msg`, `reply`, `cap_update`, `error`
- Use `gleam/json` for codec definitions and keep them unit tested with fixtures

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

- Core subject subscription
  - Use NATS CLI: `nats sub test.subject` and `nats pub test.subject '{"hello":"world"}'`
  - From client, send `{ op:"sub", target:"test.subject" }` and verify `msg` delivery

- Command/reply
  - Implement a simple service that replies to `svc.echo` and test `cmd` → `reply`

- KV subscription
  - Create bucket: `nats kv add todos`
  - Frontend: `{ op:"kv_sub", target:"todos", data:{"pattern":"user.123.*"} }`
  - CLI: `nats kv put TODOS user.123.task1 '{"done":false}'` and verify event

- JetStream subscription
  - Create stream: `nats stream add CHAT --subjects 'chat.room.*'`
  - Publish: `nats pub chat.room.123 '{"msg":"hi"}'`
  - Frontend: `{ op:"js_sub", target:"CHAT", data:{"start_seq":0, "batch":100, "filter":"chat.room.123"} }`
  - Verify events and `seq` increments; test resume with last seen `seq`

- Backpressure
  - Temporarily reduce `sendCh` buffer and inject large bursts; verify connection closes after the configured timeout with an `error`

- Capabilities
  - Seed capabilities into KV (e.g., bucket `auth.users`, key `<subject>`)
  - Connect as the user; verify allowed vs denied operations and that `cap_update` triggers revocations

---

## Migration notes (from current WS types)

- The existing `WebSocketMessage{ Type, Topic, Data, ... }` and `MsgType*` constants will be replaced by the unified envelope (`op`, `target`, `data`, ...)
- Preserve the hub structure (`Hub`, `Client`, `readPump`, `writePump`) but update parsing/dispatch in `handleMessage`
- Keep legacy `Type: "subscribe"|"unsubscribe"` handling during a transition, translating them into `sub|unsub` internally

---

## Reference locations in repo

- Backend entrypoint: `server/main.go`
- HTTP server and routing: `server/web/web.go`, `server/web/routes.go`
- WebSocket hub: `server/web/socket.go`
- Frontend entry HTML: `jst_lustre/index.html`
- Frontend app: `jst_lustre/src/jst_lustre.gleam`
- Frontend session/auth: `jst_lustre/src/session.gleam`

---

## Future work

- Time-based resume for JetStream when `last_seq == 0`
- Durable consumer naming per user/session and stream
- At-least-once delivery with explicit acks and retry loops
- Protocol versioning in envelope to allow incremental evolution
- Heartbeat ops (`ping/pong`) at the protocol level for fast dead-connection detection

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

