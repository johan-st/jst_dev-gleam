# Chat Request Feature - Fat Nodes Implementation

> See [REFACTOR.md](./REFACTOR.md) for the complete fat nodes architecture.

## Overview

This document outlines the chat request feature implementation within the fat nodes architecture. The feature allows users to request chat sessions and receive notifications via ntfy.sh.

## Architecture

### Fat Node Context

In the fat nodes architecture:
- Chat rooms are stored in JetStream KV (`convo_room`)
- Messages are stored in JetStream streams (`convo_message.*`)
- Data replicates across all nodes in the cluster
- Any node can create rooms or send messages
- WebSocket subscriptions work on any node

```
User A (Node 1)                    User B (Node 2)
      │                                  │
      ▼                                  ▼
┌─────────────┐                   ┌─────────────┐
│ Fat Node 1  │◄────NATS Cluster──►│ Fat Node 2  │
│             │                   │             │
│ KV: convo_room (replicated)     │ KV: convo_room │
│ Stream: convo_message (replicated) │ Stream: convo_message │
└─────────────┘                   └─────────────┘
```

### Data Flow

```
1. User clicks "Request Chat"
   └→ POST /api/chat/request (any node)
      └→ Create room in KV convo_room
         └→ JetStream replicates to all nodes
      └→ Send ntfy notification
      └→ Return room_id

2. User navigates to /chat/{room_id}
   └→ WebSocket subscribes to convo_message.{room_id}
      └→ JetStream stream subscription
   └→ WebSocket subscribes to KV convo_room (room metadata)

3. Users send messages
   └→ POST /api/chat/room/{room_id}/message (any node)
      └→ Publish to convo_message.{room_id}
         └→ JetStream replicates to all nodes
         └→ All WebSocket subscribers receive message
```

## Implementation

### Backend (Go)

#### Chat Request Endpoint

**File:** `server/web/routes.go`

```go
// POST /api/chat/request
func handleChatRequest(l *jst_log.Logger, nc *nats.Conn) http.Handler {
    type Response struct {
        RoomID string `json:"room_id"`
        URL    string `json:"url"`
    }

    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // 1. Generate room ID
        roomID := uuid.New().String()

        // 2. Create room in KV (replicates across cluster)
        js, _ := nc.JetStream()
        kv, _ := js.KeyValue("convo_room")
        
        room := api.Room{
            Id:        roomID,
            Name:      "Chat Request",
            Public:    true,
            CreatedAt: time.Now(),
        }
        roomBytes, _ := json.Marshal(room)
        kv.Put(roomID, roomBytes)

        // 3. Send ntfy notification via NATS service
        notification := ntfy.Notification{
            Title:     "New Chat Request",
            Message:   fmt.Sprintf("https://jst.dev/chat/%s", roomID),
            Priority:  ntfy.PriorityHigh,
            NtfyTopic: "jst",
        }
        notifBytes, _ := json.Marshal(notification)
        nc.Request(ntfy.SubjectNotification, notifBytes, 10*time.Second)

        // 4. Return response
        respJson(w, Response{
            RoomID: roomID,
            URL:    fmt.Sprintf("/chat/%s", roomID),
        }, http.StatusOK)
    })
}
```

#### Route Registration

```go
// server/web/routes.go
mux.Handle("POST /api/chat/request", handleChatRequest(l, nc))
```

### Frontend (Lustre/Gleam)

#### Chat Request Effect

**File:** `jst_lustre/src/chat.gleam`

```gleam
import gleam/http
import gleam/json
import lustre/effect.{type Effect}

pub type ChatRequestResult {
  ChatRequestSuccess(room_id: String)
  ChatRequestError(String)
}

pub fn request_chat() -> Effect(ChatRequestResult) {
  http.post(
    "/api/chat/request",
    json.object([]),
    fn(result) {
      case result {
        Ok(response) -> {
          case json.decode(response.body, room_id_decoder()) {
            Ok(room_id) -> ChatRequestSuccess(room_id)
            Error(_) -> ChatRequestError("Invalid response")
          }
        }
        Error(_) -> ChatRequestError("Request failed")
      }
    }
  )
}

fn room_id_decoder() -> json.Decoder(String) {
  json.field("room_id", json.string)
}
```

#### Chat Index View

**File:** `jst_lustre/src/view/page/chat_index.gleam`

```gleam
pub fn view(
  rooms: sync.KV(String, ChatRoom),
  on_request_chat: fn() -> msg,
) -> List(Element(msg)) {
  [
    html.div([attr.class("flex justify-between items-center mb-4")], [
      ui.page_title("Chat Rooms"),
      html.button(
        [
          attr.class("bg-pink-500 hover:bg-pink-600 text-white px-4 py-2 rounded"),
          event.on_click(on_request_chat),
        ],
        [html.text("Request Chat")],
      ),
    ]),
    // Room list...
  ]
}
```

### WebSocket Subscriptions

The chat room page subscribes to:

1. **Room metadata (KV):** `kv_sub` to `convo_room` with key filter
2. **Messages (JetStream):** `js_sub` to `convo_message` stream with filter

```json
// Subscribe to room metadata
{
  "op": "kv_sub",
  "target": "convo_room",
  "data": { "pattern": "room-id-here" }
}

// Subscribe to messages
{
  "op": "js_sub",
  "target": "convo_message",
  "data": {
    "filter": "convo_message.room-id-here",
    "start_seq": 0,
    "batch": 50
  }
}
```

## Fat Node Considerations

### Replication

Chat data is replicated across the cluster:

```go
// KV bucket for rooms (R=3)
kvConfig := &nats.KeyValueConfig{
    Bucket:   "convo_room",
    Replicas: 3,
}

// Stream for messages (R=3)
streamConfig := &nats.StreamConfig{
    Name:     "convo_message",
    Subjects: []string{"convo_message.*"},
    Replicas: 3,
}
```

### Cross-Node Messaging

When User A on Node 1 sends a message:

```
User A → POST /api/chat/room/{id}/message → Node 1
                                              │
         Publish to convo_message.{id}────────┘
                                              │
         JetStream replicates ────────────────┼──────────────┐
                                              │              │
         Node 1 WebSocket subscribers ◄───────┘              │
         Node 2 WebSocket subscribers ◄──────────────────────┘
                                              │
                                        User B receives
```

### Offline Node Behavior

If a node is partitioned:
- Users on that node can still chat (local JetStream)
- Messages queue locally
- When partition heals, messages sync to cluster
- All users eventually see all messages

### ntfy Notification

The ntfy notification is sent via NATS service:
- Any node can send the notification
- The ntfy service runs on each node
- Only one node processes the request (NATS request/reply)

## Capabilities

Chat requires specific capabilities:

```json
{
  "buckets": {
    "convo_room": [">"]
  },
  "streams": {
    "convo_message": ["convo_message.*"]
  }
}
```

For private rooms, restrict to specific room IDs:

```json
{
  "buckets": {
    "convo_room": ["room-123", "room-456"]
  },
  "streams": {
    "convo_message": ["convo_message.room-123", "convo_message.room-456"]
  }
}
```

## Testing

### Local Development

```bash
# Start fat node in local mode
go run . -local -proxy -log debug

# Create chat request
curl -X POST http://localhost:8080/api/chat/request

# Watch messages (NATS CLI)
nats sub "convo_message.>"
```

### Multi-Node Testing

```bash
# Node 1 (Fly.io)
go run . -fat-node

# Node 2 (local with Tailscale)
CLUSTER_PEERS=100.64.0.1:6222 go run . -fat-node

# Create room on Node 1, verify it appears on Node 2
```

## Future Enhancements

- **Room expiration:** Auto-delete rooms after 24 hours
- **Typing indicators:** Ephemeral NATS subjects (no persistence)
- **Read receipts:** Track per-user read position in stream
- **File attachments:** Store in S3, reference in messages
- **Audio/video:** WebRTC with NATS signaling
