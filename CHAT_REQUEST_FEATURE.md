# Chat Request Feature - Implementation Plan

## Overview

This document outlines the implementation plan for a chat request feature that allows users to request chat sessions and get notified via ntfy.sh when someone wants to chat.

## Architecture

### Current State Analysis

**Backend (Go + NATS JetStream + KV):**
- ✅ WebSocket realtime bridge (`/ws`) with NATS integration
- ✅ NATS JetStream with `convo_message` stream for room messages
- ✅ NATS KV store `convo_room` for room metadata
- ✅ Basic conversation service with room creation
- ✅ ntfy.sh integration for notifications
- ✅ Authorization system with JWT cookies

**Frontend (Lustre/Gleam):**
- ✅ Chat room listing page (`chat_index.gleam`)
- ✅ Individual chat room page (`chat_room.gleam`)
- ✅ WebSocket integration via sync module
- ✅ Real-time message updates

**Missing Components:**
- ❌ Chat request creation endpoint
- ❌ Chat request notification flow
- ❌ Frontend "Request Chat" button
- ❌ Room ID-based routing
- ❌ User name collection for anonymous users

## Feature Flow

### 1. User Initiates Chat Request

**Frontend Action:**
- User clicks "Request Chat" button
- Frontend sends `POST /chat/request` to server
- Server creates new room and sends ntfy notification
- Frontend redirects to `/chat/{room_id}`

**Backend Processing:**
```go
// New endpoint: POST /chat/request
func handleChatRequest(l *jst_log.Logger, nc *nats.Conn) http.Handler {
    // 1. Generate new room_id (UUID)
    // 2. Store room metadata in convo_room KV
    // 3. Send ntfy.sh notification
    // 4. Return room_id to frontend
}
```

### 2. Notification System

**ntfy.sh Integration:**
- Topic: `jst`
- Title: `"New Chat Request"`
- Message: `"New chat request: https://jst.dev/chat/{room_id}"`
- Priority: High
- Category: `jst.dev`
- Sent via existing ntfy service (not direct HTTP)

### 3. Chat Room Access

**URL Structure:**
- Chat request page: Frontend handles routing to `/chat/{room_id}`
- WebSocket connection: `ws://server/ws` (existing)

**User Experience:**
- Any user with the link can join the chat
- Anonymous users prompted for name (stored in localStorage/cookie)
- Real-time messaging via existing WebSocket bridge

## Implementation Plan

### Phase 1: Backend API Endpoints

#### 1.1 Chat Request Endpoint
**File:** `server/web/routes.go`

```go
// Add to routes function
mux.Handle("POST /chat/request", handleChatRequest(l, nc))
```

**Implementation:**
```go
func handleChatRequest(l *jst_log.Logger, nc *nats.Conn) http.Handler {
    type Resp struct {
        RoomID string `json:"room_id"`
    }
    
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // 1. Generate room_id
        roomID := uuid.New().String()
        
        // 2. Create room metadata
        room := api.Room{
            Id:     roomID,
            Name:   "Chat Request",
            Public: true,
            Users:  []string{},
        }
        
        // 3. Store in KV
        roomBytes, _ := json.Marshal(room)
        js, _ := nc.JetStream()
        kv, _ := js.KeyValue("convo_room")
        kv.Put(roomID, roomBytes)
        
        // 4. Send ntfy notification via ntfy service
        notification := ntfy.Notification{
            ID:        uuid.New().String(),
            UserID:    "", // Anonymous request
            Title:     "New Chat Request",
            Message:   fmt.Sprintf("New chat request: https://jst.dev/chat/%s", roomID),
            Category:  "jst.dev",
            Priority:  ntfy.PriorityHigh,
            NtfyTopic: "jst",
            Data:      map[string]interface{}{"room_id": roomID},
            CreatedAt: time.Now(),
        }
        
        notificationBytes, _ := json.Marshal(notification)
        nc.Request(ntfy.SubjectNotification, notificationBytes, 10*time.Second)
        
        // 5. Return response
        respJson(w, Resp{RoomID: roomID}, http.StatusOK)
    })
}
```


### Phase 2: Frontend Implementation

#### 2.1 Request Chat Button
**File:** `jst_lustre/src/view/page/chat_index.gleam`

```gleam
// Add to chat_index.gleam
pub fn view(
  rooms kv_rooms: sync.KV(String, ChatRoom),
  on_nav_to on_nav_to: fn(uri.Uri) -> msg,
  on_request_chat on_request_chat: fn() -> msg,  // New parameter
) -> List(Element(msg)) {
  let header = ui.page_title("Chat Rooms", "chat-rooms-title")
  
  // Add request chat button to header
  let request_button = html.button(
    [attr.class("bg-pink-500 hover:bg-pink-600 text-white px-4 py-2 rounded")],
    [html.text("Request Chat")]
  )
  
  let header_with_button = ui.flex_between(header, request_button)
  
  // ... rest of existing code
}
```

#### 2.2 Chat Request Logic
**File:** `jst_lustre/src/chat.gleam`

```gleam
// Add new message type
pub type ChatRequestMsg {
  RequestChat
  ChatRequestCreated(room_id: String)
  ChatRequestFailed(String)
}

// Add HTTP request function
pub fn request_chat() -> Effect(ChatRequestMsg) {
  use result <- http.post("/chat/request", json.object([]))
  case result {
    Ok(response) -> {
      case response.body |> json.decode(chat_request_response_decoder()) {
        Ok(data) -> Effect.succeed(ChatRequestCreated(data.room_id))
        Error(_) -> Effect.succeed(ChatRequestFailed("Failed to parse response"))
      }
    }
    Error(_) -> Effect.succeed(ChatRequestFailed("Failed to create chat request"))
  }
}

// Add decoder for response
pub fn chat_request_response_decoder() -> Decoder(String) {
  use room_id <- decode.field("room_id", decode.string)
  decode.success(room_id)
}
```

#### 2.3 Room-Specific Chat Page
**File:** `jst_lustre/src/view/page/chat_room.gleam`

```gleam
// Update to handle room-specific logic
pub fn view(
  room_id room_id: String,
  messages sub_messages: sync.Subscription(ChatMessage),
  user_name user_name: Option(String),  // New parameter
  on_set_name on_set_name: fn(String) -> msg,  // New parameter
) -> List(Element(msg)) {
  let header = ui.page_title("Room: " <> room_id, "chat-room-title")
  
  // Show name prompt if no name set
  let name_prompt = case user_name {
    None -> [
      html.div([attr.class("mb-4 p-4 bg-yellow-100 rounded")], [
        html.p([attr.class("mb-2")], [html.text("Enter your name to join the chat:")]),
        html.input([
          attr.class("w-full p-2 border rounded"),
          attr.placeholder("Your name"),
          // Add input handling
        ])
      ])
    ]
    Some(_) -> []
  }
  
  // ... rest of existing message display code
}
```

### Phase 3: WebSocket Integration

#### 3.1 Room-Specific Subscriptions
The existing WebSocket bridge already supports:
- `convo_message.*` subject pattern
- JetStream subscriptions with filters
- Real-time message forwarding

**Usage:**
```javascript
// Frontend WebSocket message
{
  "op": "js_sub",
  "target": "convo_message",
  "data": {
    "filter": "convo_message.{room_id}",
    "start_seq": 0,
    "batch": 50
  }
}
```

#### 3.2 Message Publishing
```javascript
// Publish message to room
{
  "op": "pub",
  "target": "convo_message.{room_id}",
  "data": {
    "user": "user_id",
    "content": "Hello world",
    "timestamp_ms": 1234567890
  }
}
```

### Phase 4: User Experience Enhancements

#### 4.1 Name Management
- Store user name in localStorage
- Prompt for name on first visit
- Allow name changes in settings

#### 4.2 Room Status
- Show "Waiting for response" when room is empty
- Display participant count
- Show last activity timestamp

#### 4.3 Mobile Optimization
- Responsive design for mobile devices
- Touch-friendly message input
- Optimized for small screens

## Technical Considerations

### Security
- Room IDs are UUIDs (unguessable)
- No authentication required for chat requests
- Rate limiting on request creation
- Input sanitization for messages

### Performance
- NATS JetStream handles message persistence
- KV store for room metadata
- WebSocket connection pooling
- Message batching for large rooms

### Scalability
- Stateless server design
- NATS clustering for high availability
- JetStream replication
- CDN for static assets

## Testing Strategy

### Backend Tests
```go
func TestHandleChatRequest(t *testing.T) {
    // Test room creation
    // Test ntfy notification
    // Test KV storage
    // Test error handling
}
```

### Frontend Tests
```gleam
// Test chat request flow
// Test room navigation
// Test message display
// Test WebSocket integration
```

### Integration Tests
- End-to-end chat request flow
- Cross-browser compatibility
- Mobile device testing
- Performance under load

## Deployment Checklist

### Backend
- [ ] Add new routes to `routes.go`
- [ ] Implement chat request handler
- [ ] Test ntfy service integration
- [ ] Update CORS settings if needed

### Frontend
- [ ] Add request chat button
- [ ] Implement chat request logic
- [ ] Update room page for name collection
- [ ] Add room-specific routing
- [ ] Test WebSocket integration

### Infrastructure
- [ ] Verify NATS JetStream configuration
- [ ] Check ntfy service configuration
- [ ] Monitor error rates and performance

## Future Enhancements

### Phase 2 Features
- Chat request expiration (24 hours)
- Request categories/topics
- User profiles and avatars
- Message reactions and threading
- File sharing capabilities

### Advanced Features
- Video/audio chat integration
- Screen sharing
- Chat history search
- Export chat logs
- Admin moderation tools

## Conclusion

This implementation plan provides a solid foundation for the chat request feature while leveraging the existing infrastructure. The phased approach allows for incremental development and testing, ensuring a robust and user-friendly experience.

The key advantages of this approach:
- Minimal changes to existing codebase
- Leverages proven NATS + WebSocket architecture
- Simple user experience
- Scalable and maintainable design
- Easy to extend with additional features
