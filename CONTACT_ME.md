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
- **WebSocket Infrastructure**: Existing real-time communication system
- **NATS**: Message bus for service communication
- **User Management**: Existing who service for user identification

### New Services Required
- **Contact Request Service**: Manages contact requests and responses
- **Chat Session Service**: Handles real-time chat between parties
- **Contact Page Frontend**: UI for contact requests

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
**Architecture**: NATS for request handling, WebSocket for chat, HTTP for status updates

**Pros**:
- Best of both worlds
- Reuses existing WebSocket infrastructure
- NATS handles request orchestration
- HTTP provides simple status endpoints
- Most aligned with existing architecture

**Cons**:
- Slightly more complex than pure HTTP
- Requires careful state synchronization

**Implementation**:
```
Contact Request → NATS → ntfy → User Action → NATS → WebSocket Chat + HTTP Status
```

## Detailed Implementation Plan

### Phase 1: Backend Services

#### 1.1 Contact Request Service
**Location**: `server/contact/`
**Purpose**: Manages contact request lifecycle

**Components**:
- `contact.go`: Main service with NATS microservice
- `models.go`: Request/response data structures
- `handlers.go`: Request processing logic

**Key Functions**:
- `CreateRequest()`: Generate new contact request
- `HandleResponse()`: Process Accept/Busy responses
- `GetRequestStatus()`: Retrieve request status

**NATS Subjects**:
- `contact.request.create` - Create new request
- `contact.request.respond` - Handle Accept/Busy response
- `contact.request.status` - Get request status

#### 1.2 Chat Session Service
**Location**: `server/chat/`
**Purpose**: Manages real-time chat sessions

**Components**:
- `chat.go`: Chat session management
- `session.go`: Individual chat session logic
- `websocket.go`: WebSocket upgrade and handling

**Key Functions**:
- `CreateSession()`: Initialize chat session
- `JoinSession()`: Add participant to session
- `SendMessage()`: Broadcast message to session
- `CloseSession()`: Clean up session resources

**Integration**:
- Extends existing WebSocket infrastructure
- Uses NATS for session coordination
- Integrates with existing user authentication

#### 1.3 Enhanced ntfy Service
**Modifications to existing service**:
- Add support for action buttons in notifications
- Implement action callback handling
- Support for custom notification data

**New Features**:
- Action button support (Accept/Busy)
- Callback URL handling for actions
- Enhanced notification data structure

### Phase 2: Frontend Implementation

#### 2.1 Contact Page
**Location**: `jst_lustre/src/view/contact.gleam`
**Purpose**: Contact request interface

**Components**:
- Contact form with availability button
- Request status display
- Loading states and error handling

**Features**:
- "See if I am available" button
- Request ID display
- Status updates via WebSocket

#### 2.2 Chat Interface
**Location**: `jst_lustre/src/view/chat_session.gleam`
**Purpose**: Real-time chat between parties

**Components**:
- Message display area
- Input field for new messages
- Participant information
- Connection status

**Features**:
- Real-time message updates
- Typing indicators
- Message history
- Session management

#### 2.3 Route Updates
**Modifications to `jst_lustre/src/routes.gleam`**:
- Add `Contact` route
- Add `ChatSession(id: String)` route
- Update navigation and routing logic

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

## API Endpoints

### Contact Requests
- `POST /api/contact/request` - Create new contact request
- `GET /api/contact/request/{id}` - Get request status
- `POST /api/contact/request/{id}/respond` - Respond to request (Accept/Busy)

### Chat Sessions
- `GET /api/chat/session/{id}` - Get chat session details
- `POST /api/chat/session/{id}/message` - Send message to session
- `GET /api/chat/session/{id}/messages` - Get message history
- `DELETE /api/chat/session/{id}` - Close chat session

### WebSocket Endpoints
- `/ws/chat/{sessionId}` - Chat session WebSocket connection

## Security Considerations

### Authentication & Authorization
- Contact requests: No authentication required (public endpoint)
- Chat sessions: Require valid session ID and participant verification
- Admin actions: Require JST authentication for Accept/Busy responses

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
- Implement Contact Request Service
- Enhance ntfy Service for actions
- Basic data models and storage

### Week 2: Chat Infrastructure
- Implement Chat Session Service
- WebSocket integration
- Basic message handling

### Week 3: Frontend Development
- Contact page implementation
- Chat interface
- Route integration

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

This implementation will create a seamless contact experience that integrates naturally with the current ntfy notification system and provides a foundation for future real-time communication features.