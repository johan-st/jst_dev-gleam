# WebSocket Articles API

This document describes the WebSocket realtime bridge used for articles and other features. It does not replace HTTP CRUD; article create/update/delete and reads remain HTTP. The WebSocket connection is used for realtime updates (KV watchers), NATS subject subscriptions, and JetStream consumption.

## Overview

- **Realtime updates (preferred)**: Subscribe to KV bucket `article` to drive UI state
- **Subject subscription**: Subscribe to allowed NATS subjects
- **JetStream subscription**: Pull-based consumption from allowed streams

## Connection

Connect to the WebSocket endpoint:
```
ws://localhost:8080/ws
```

### Auth and CORS
- WebSocket upgrade runs through the HTTP middleware. If the `jst_dev_who` JWT cookie is present and valid, the user is associated with the connection.
- Origins must be in the allowed list. See server for the exact set.

## Message Envelope

All messages are JSON with this envelope:

```json
{
  "op": "operation_name",
  "target": "subject_or_bucket_or_stream",
  "data": { /* operation-specific data, optional */ }
}
```

Note: `inbox` is currently unused. There is no request/response `reply` flow in the implementation.

## Client Operations

### 1) Subscribe to a NATS subject

Client → Server
```json
{ "op": "sub", "target": "time.seconds" }
```

Server → Client (for each message)
```json
{ "op": "sub_msg", "target": "time.seconds", "data": { /* original payload */ } }
```

Requires capability: `subjects` must include a pattern matching the subject.

### 2) Unsubscribe

Client → Server
```json
{ "op": "unsub", "target": "time.seconds" }
```

Also stops a KV watcher if `target` matches a previously watched bucket.

### 3) Subscribe to KV bucket (recommended for Articles)

Client → Server
```json
{ "op": "kv_sub", "target": "article", "data": { "pattern": ">" } }
```

Server → Client
```json
{ "op": "kv_msg", "target": "article", "data": { "op": "in_sync", "rev": 0 } }
{ "op": "kv_msg", "target": "article", "data": { "op": "put", "rev": 2, "key": "<id>", "value": "<json>" } }
{ "op": "kv_msg", "target": "article", "data": { "op": "delete", "rev": 3, "key": "<id>", "value": "" } }
{ "op": "kv_msg", "target": "article", "data": { "op": "purge", "rev": 4, "key": "<id>", "value": "" } }
```

Notes:
- Server attempts pattern watch (`kv.Watch(pattern)`), falls back to `WatchAll()` if unsupported.
- First `in_sync` indicates the watcher is caught up.
- This path aligns with the frontend rule: update KV-derived state via WebSocket messages only.

### 4) Subscribe to JetStream (pull)

Client → Server
```json
{
  "op": "js_sub",
  "target": "<stream>",
  "data": { "filter": "<subject>", "start_seq": 0, "batch": 50 }
}
```

Server → Client (for each fetched message)
```json
{ "op": "js_msg", "target": "<stream>", "data": { "op": "js_msg", "target": "<stream>", "data": <original message bytes> } }
```

Notes:
- `filter` is required to form a concrete subject binding.
- Implementation detail: `js_msg` is currently double-encoded (outer envelope contains a JSON-encoded inner envelope). Parse `data` once more to get the original payload.
- A per-connection durable name is created; messages are acked after forwarding.

## Server Events

- `sub_msg` — forwarded NATS subject payloads
- `kv_msg` — KV watcher events (`in_sync`, `put`, `delete`, `purge`)
- `js_msg` — JetStream messages (see double-encoding note above)
- `cap_update` — capability updates for the current user
- `error` — fatal issues (e.g., JetStream unavailable, backpressure timeout)

## Capabilities and Authorization

Shape stored under `auth.users/<user_id>` KV entry and sent as-is in `cap_update`:

```json
{
  "subjects": ["time.seconds", "convo_message.*"],
  "buckets": { "article": [">"], "url_short": [">"], "convo_room": [">"] },
  "commands": [],
  "streams": {}
}
```

- On connect, default capabilities are used; if a user is authenticated, the server watches `auth.users/<user_id>` and pushes `cap_update` on change.
- Access checks:
  - Subjects: pattern match on `subjects`
  - KV: bucket name must match a `buckets` key; key pattern must match one of its values
  - Streams: stream name and filter subject must match `streams`

## Articles CRUD (HTTP)

All CRUD operations are HTTP. WebSocket is for realtime updates only.

| HTTP Endpoint | Purpose |
|---------------|---------|
| `GET /api/article` | List articles |
| `POST /api/article` | Create article |
| `GET /api/article/{id}` | Get article |
| `PUT /api/article/{id}` | Update article |
| `DELETE /api/article/{id}` | Delete article |
| `GET /api/article/{id}/revisions` | Article history |
| `GET /api/article/{id}/revisions/{revision}` | Specific revision |

Recommended frontend flow:
- Perform CRUD via HTTP
- Maintain live UI state by subscribing to `kv_sub` on bucket `article` and applying `kv_msg` events

## Errors

Server sends error envelopes and may close the connection:

```json
{ "op": "error", "data": { "reason": "jetstream unavailable" } }
{ "op": "error", "data": { "reason": "backpressure timeout" } }
```

Unknown operations are ignored (logged server-side).

## Security Notes

- Auth via cookie (`jst_dev_who`) JWT; the same cookie used by HTTP is used for WebSocket auth context.
- CORS/Origin check is enforced at upgrade time.
- Capability checks are applied to all subscriptions.
