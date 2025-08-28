# Contact Availability Feature Implementation Plan

## Overview
This document outlines the implementation plan for a new contact availability feature that allows visitors to request contact with JST and receive real-time responses through ntfy notifications with action buttons.

## Feature Requirements

### Core Functionality
1. **Contact Request Button**: A button on the contact page labeled "See if I am available"
2. **ntfy Notification**: Send notification to topic "jst" with action buttons
3. **Action Buttons**: "Accept" and "Busy" buttons in the notification
4. **Accept Flow**: Redirect to chat interface for real-time communication
5. **Busy Flow**: Send message to requester asking them to email jst@jst.dev

### User Experience Flow
1. Visitor clicks "See if I am available" button
2. System generates unique request ID and sends ntfy notification
3. JST receives notification with Accept/Busy actions
4. Based on JST's choice:
   - **Accept**: Opens chat interface for both parties
   - **Busy**: Sends decline message to requester

## Technical Architecture

### Existing Services to Reuse
- **ntfy Service**: Already handles notifications with NATS integration
- **WebSocket Infrastructure**: Existing real-time communication system with NATS subjects
- **NATS**: Message bus for service communication and chat room subjects
- **User Management**: Existing who service for user identification
- **Notification Page**: Existing UI that can be adapted for contact requests

### New Services Required
- **Combined Chat & Contact Service**: Manages contact requests and chat sessions
- **Contact Page Frontend**: Adapted from existing notification page

## Implementation Options

### Option 1: NATS-Based Request/Response with WebSocket Chat
**Architecture**: Use NATS for request handling and WebSocket for chat sessions

**Pros**:
- Leverages existing NATS infrastructure
- Real-time chat through existing WebSocket system
- Scalable and decoupled architecture
- Reuses existing notification patterns

**Cons**:
- More complex state management
- Requires session persistence across services
- Need to handle WebSocket connection lifecycle

**Implementation**:
```
Contact Request → NATS → ntfy → User Action → NATS → Chat Session Creation → WebSocket
```

### Option 2: HTTP-Based with Server-Sent Events
**Architecture**: HTTP endpoints for requests with Server-Sent Events for chat

**Pros**:
- Simpler HTTP-based implementation
- Easier to implement and debug
- Standard web patterns
- No complex WebSocket state management

**Cons**:
- Less real-time than WebSocket
- Higher server load for long connections
- More complex client-side event handling

**Implementation**:
```
Contact Request → HTTP → ntfy → User Action → HTTP → SSE Chat Stream
```

### Option 3: Hybrid Approach (Recommended)
**Architecture**: NATS for request handling and chat rooms, HTTP for responses, WebSocket for real-time communication

**Pros**:
- Best of both worlds
- Reuses existing WebSocket infrastructure with NATS subjects
- NATS handles both request orchestration and chat room messaging
- HTTP provides simple, stateless response handling
- Chat flows through established WebSocket connections
- Most aligned with existing architecture
- Simplified service structure by combining contact and chat
- No need to track inboxes or maintain complex state

**Cons**:
- Requires careful session management
- Need to handle WebSocket connection lifecycle

**Implementation**:
```
Contact Request → NATS → ntfy → User Action (HTTP) → NATS → Chat Session Creation → WebSocket (chat.room.<session>)
```

## Detailed Implementation Plan

### Phase 1: Backend Services

#### 1.1 Combined Chat & Contact Service
**Location**: `server/chat/`
**Purpose**: Manages both contact requests and chat sessions

**Components**:
- `chat.go`: Main service with NATS microservice
- `contact.go`: Contact request handling
- `session.go`: Chat session management
- `models.go`: Combined data structures

**Key Functions**:
- `CreateContactRequest()`: Generate new contact request
- `HandleContactResponse()`: Process Accept/Busy responses
- `CreateChatSession()`: Initialize chat session after acceptance
- `SendChatMessage()`: Broadcast message to chat room
- `GetSessionStatus()`: Retrieve session status

**NATS Subjects**:
- `chat.request.create` - Create new contact request
- `chat.request.respond` - Handle Accept/Busy response
- `chat.room.<session_id>` - Chat room for specific session
- `chat.request.<request_id>` - Request status, metadata, and updates

**Integration**:
- **Extends existing WebSocket infrastructure** - no new session service needed
- **Uses existing subscription system** - clients subscribe to `chat.room.<session_id>` via existing `sub` operation
- **Leverages existing authorization** - extend `capabilities.Subjects` with pattern matching for chat subjects
- **NATS KV for session state** - store session metadata in `chat.request.<request_id>` bucket
- **Existing WebSocket connection management** - no changes to connection lifecycle

#### 1.2 Enhanced ntfy Service
**Modifications to existing service**:
- Add support for action buttons in notifications
- Implement HTTP callback URLs for Accept/Busy responses
- Support for custom notification data including session IDs
- Generate unique callback URLs for each notification

**New Features**:
- Action button support (Accept/Busy)
- HTTP callback URL handling for actions
- Enhanced notification data structure
- Integration with chat session creation
- Stateless response handling via HTTP endpoints

### Phase 2: Frontend Implementation

#### 2.1 Contact Page
**Location**: `jst_lustre/src/view/contact.gleam`
**Purpose**: Enhanced contact interface (adapted from existing notification page)

**Components**:
- Existing notification form (preserved)
- New "See if I am available" button
- Request status display
- Loading states and error handling
- Chat interface integration

**Features**:
- **Preserved**: Existing notification functionality unchanged
- **New**: "See if I am available" button for chat requests
- Request ID display for chat requests
- Status updates via WebSocket
- Seamless transition to chat interface
- Updated page description to explain both features
- Reuses existing notification page structure and styling

#### 2.2 Chat Interface
**Location**: `jst_lustre/src/view/chat_session.gleam`
**Purpose**: Real-time chat between parties

**Components**:
- Message display area
- Input field for new messages
- Participant information
- Connection status
- Session management

**Features**:
- Real-time message updates via WebSocket
- Typing indicators
- Message history
- Session management
- Integration with existing WebSocket infrastructure
- NATS subject-based chat rooms (`chat.room.<session_id>`)

#### 2.3 Route Updates
**Modifications to `jst_lustre/src/routes.gleam`**:
- Rename `Notifications` route to `Contact` route (keeping same URL)
- Add `ChatSession(id: String)` route
- Update navigation and routing logic
- Maintain existing URL structure where possible

#### 2.4 Frontend Feedback & Optimistic Updates
Implement responsive user feedback by listening on the same subjects we publish to and correlating events via unique IDs in headers or payloads.

- **Correlation ID**: Include a unique `client_msg_id` (UUID) in each published message; echo it back in server-originated events so the client can reconcile.
- **Subject Echo**: The client subscribes to the same subject it publishes to. When it sees its own event (matching `client_msg_id`), it progresses the local UI state.

Frontend request lifecycle (contact request):
1. Button pressed → set state to "sending"; start short timeout for network errors.
2. When the published event is observed locally on the subject (by `client_msg_id`) → set state to "waiting"; start a longer timeout that warns: "this is taking longer than usual".
3. When a response/update arrives (accept/busy) on the same request subject → clear pending state, handle the response (navigate to chat on accept; show busy message on decline).

Chat optimistic messaging:
- On send, immediately render the message as "pending" (greyed out, pinned to bottom) with `client_msg_id`.
- If the message is seen on the room subject with matching `client_msg_id`, convert pending → confirmed (assign server timestamp/id).
- If timeout elapses without confirmation, keep it pending with a retry affordance.

Timeout guidance:
- Network error/retry: ~2–5s for initial send failure.
- Long-running warning: ~10–20s before showing "taking longer than usual".

Error feedback:
- Revert to normal state on hard failure and display a concise error toast.
- For chat, keep failed messages pending with a retry button rather than removing them.

### Phase 3: Integration and Testing

#### 3.1 Service Integration
- Update `server/main.go` to start new services
- Modify `server/web/routes.go` for new endpoints
- Integrate with existing WebSocket handling

#### 3.2 Frontend Integration
- Update main application to include new views
- Integrate with existing session management
- Add navigation to new routes

#### 3.3 Testing Strategy
- Unit tests for new services
- Integration tests for service communication
- End-to-end testing of complete flow
- WebSocket connection testing

## Data Models

### Contact Request
```go
type ContactRequest struct {
    ID          string    `json:"id"`
    RequesterID string    `json:"requester_id"`
    RequesterIP string    `json:"requester_ip"`
    Status      string    `json:"status"` // pending, accepted, declined
    CreatedAt   time.Time `json:"created_at"`
    RespondedAt *time.Time `json:"responded_at,omitempty"`
    Response    string    `json:"response,omitempty"` // accept, busy
    ChatSessionID *string `json:"chat_session_id,omitempty"`
}
```

### Chat Session
```go
type ChatSession struct {
    ID           string    `json:"id"`
    RequestID    string    `json:"request_id"`
    Participants []string  `json:"participants"`
    Status       string    `json:"status"` // active, closed
    CreatedAt    time.Time `json:"created_at"`
    ClosedAt     *time.Time `json:"closed_at,omitempty"`
}
```

### Chat Message
```go
type ChatMessage struct {
    ID        string    `json:"id"`
    SessionID string    `json:"session_id"`
    SenderID  string    `json:"sender_id"`
    Content   string    `json:"content"`
    Timestamp time.Time `json:"timestamp"`
}
```

### WebSocket Session Management
**Current Implementation**: The existing WebSocket system already handles subscriptions through the `rtClient` struct with:
- `subs map[string]*nats.Subscription` - tracks NATS subscriptions
- `caps capabilities` - authorization and allowed subjects
- `id string` - client identification

**Enhanced Approach**: Extend the existing system rather than create a separate session service:
- **No new WebSocketSession struct needed** - leverage existing `rtClient`
- **Chat rooms flow through existing subscription system** - clients subscribe to `chat.room.<session_id>`
- **Request metadata stored in NATS KV** - `chat.request.<request_id>` for status and metadata
- **Existing authorization system** - extend `capabilities.Subjects` with pattern matching for chat subjects

**Pattern Matching Strategy**:
- **Status Updates**: Post to subject, listen for changes on same subject
- **Authorization Patterns**: Use `<session>` and `<user>` placeholders for dynamic access
- **Example Patterns**: `chat.room.<session>`, `chat.request.<user>`, `chat.room.*`

**Status Update Strategy**:
- **Single Subject Approach**: Post status changes to the same subject that clients listen to
- **Real-time Updates**: Clients receive immediate updates when status changes
- **Simplified Architecture**: No need for separate "status" subjects
- **Example Flow**: 
  - Status change → `chat.request.<request_id>` → All listeners get update
  - Chat message → `chat.room.<session_id>` → All room participants get message

**Benefits**:
- Reuses proven WebSocket infrastructure
- No duplicate session management
- Leverages existing authorization and subscription patterns
- Simpler implementation with fewer moving parts
- Consistent subject naming convention
- Unified status and message handling

## API Endpoints

### Contact Requests
- `POST /api/contact/request` - Create new contact request
- `GET /api/contact/request/{id}` - Get request status

### Contact Responses (HTTP Callbacks)
- `POST /api/contact/respond/{requestId}/accept` - Accept contact request
- `POST /api/contact/respond/{requestId}/busy` - Decline contact request
- `GET /api/contact/status/{requestId}` - Get current request status

### Chat Sessions
- `GET /api/chat/session/{id}` - Get chat session details
- `POST /api/chat/session/{id}/message` - Send message to session
- `GET /api/chat/session/{id}/messages` - Get message history
- `DELETE /api/chat/session/{id}` - Close chat session

### WebSocket Endpoints
- `/ws` - Existing WebSocket endpoint (chat flows through NATS subjects)

## Security Considerations

### Authentication & Authorization
- Contact requests: No authentication required (public endpoint)
- Contact responses: No authentication required (public callback endpoints)
- Chat sessions: Require valid session ID and participant verification
- Admin actions: No authentication required for Accept/Busy responses (simplified for development)

### Rate Limiting
- Limit contact requests per IP address
- Prevent spam and abuse
- Implement exponential backoff for repeated requests

### Data Privacy
- Minimal data collection for contact requests
- Secure chat session handling
- Automatic cleanup of old sessions and messages

## Deployment Considerations

### Environment Variables
- `CONTACT_REQUEST_LIMIT` - Max requests per IP per hour
- `CHAT_SESSION_TIMEOUT` - Inactive session timeout
- `NTFY_TOPIC_CONTACT` - ntfy topic for contact notifications

### Monitoring & Observability
- Log all contact requests and responses
- Track chat session metrics
- Monitor WebSocket connection health
- Alert on service failures

### Scaling Considerations
- NATS handles horizontal scaling
- WebSocket connections can be load balanced
- Chat sessions stored in distributed storage
- Consider Redis for session state if needed

## Implementation Timeline

### Week 1: Backend Foundation
- Implement Combined Chat & Contact Service
- Enhance ntfy Service for HTTP callbacks
- Basic data models and storage
- HTTP callback endpoints for Accept/Busy

### Week 2: Chat Infrastructure
- Implement chat session management
- NATS subject-based chat rooms (`chat.room.<session_id>`)
- Extend existing WebSocket authorization with pattern matching (`<session>`, `<user>`)
- Basic message handling
- NATS KV integration for request state (`chat.request.<request_id>`)

### Week 3: Frontend Development
- Enhance notification page with chat request functionality
- Chat interface implementation
- Route integration and updates

### Week 4: Integration & Testing
- Service integration
- End-to-end testing
- Bug fixes and refinements

## Success Metrics

### Functional Requirements
- [ ] Contact request button works
- [ ] ntfy notifications sent with action buttons
- [ ] Accept action opens chat interface
- [ ] Busy action sends decline message
- [ ] Real-time chat functionality works
- [ ] Session management handles disconnections

### Performance Requirements
- [ ] Contact request response time < 2 seconds
- [ ] ntfy notification delivery < 5 seconds
- [ ] Chat message latency < 100ms
- [ ] Support 100+ concurrent chat sessions

### User Experience Requirements
- [ ] Intuitive contact request flow
- [ ] Clear status feedback
- [ ] Responsive chat interface
- [ ] Graceful error handling

## Future Enhancements

### Phase 2 Features
- Contact request scheduling
- Availability calendar integration
- Chat history persistence
- File sharing in chat
- Mobile push notifications

### Phase 3 Features
- Multi-party chat support
- Chat room management
- Advanced notification preferences
- Analytics and reporting
- Integration with external chat platforms

## Conclusion

The recommended implementation approach (Option 3: Hybrid) provides the best balance of leveraging existing infrastructure while maintaining simplicity and scalability. The NATS-based architecture ensures reliable message delivery, while the WebSocket integration provides real-time chat capabilities that align with the existing system design.

By using HTTP for responses instead of tracking inboxes, we simplify the architecture and eliminate the need for complex state management. The existing WebSocket infrastructure handles real-time communication through NATS subjects, creating a clean separation of concerns.

This implementation will create a seamless contact experience that integrates naturally with the current ntfy notification system and provides a foundation for future real-time communication features. The combination of NATS for orchestration, HTTP for responses, and WebSocket for chat creates a robust and maintainable system.