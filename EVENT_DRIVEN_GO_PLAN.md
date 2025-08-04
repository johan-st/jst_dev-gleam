# Event-Driven Go Server Migration Plan

## Overview

This plan transforms your current Go server from a request-response architecture to an event-driven system while maintaining all existing functionality and improving real-time capabilities.

## Current Architecture Analysis

### Existing Components
- **HTTP Server**: RESTful API endpoints
- **WebSocket Hub**: Real-time communication
- **NATS Integration**: Message bus (already in place)
- **Services**: Articles, Auth, URL Shortener
- **Database**: Direct database access

### Current Flow
```
Client Request → HTTP Handler → Service → Database → Response
```

## Target Event-Driven Architecture

### New Flow
```
Client Request → HTTP Handler → Command → Event Store → Event Handlers → Database → Events → Real-time Updates
```

### Architecture Diagram
```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   HTTP Layer    │    │  Command Layer  │    │  Event Store    │
│                 │    │                 │    │                 │
│ • REST API      │───►│ • Commands      │───►│ • Event Log     │
│ • WebSocket     │    │ • Validation    │    │ • Event Bus     │
│ • Middleware    │    │ • Authorization │    │ • NATS          │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                                       │
                                                       ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Event Handlers │    │   Read Models   │    │   Projections   │
│                 │    │                 │    │                 │
│ • Business Logic│◄───│ • Query Models  │◄───│ • Event Replay  │
│ • Side Effects  │    │ • Cached Data   │    │ • State Updates │
│ • Notifications │    │ • Optimized     │    │ • Consistency   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

## Phase 1: Foundation Setup (Week 1-2)

### 1.1 Event Infrastructure

```go
// server/events/types.go
package events

import (
    "encoding/json"
    "time"
    "github.com/google/uuid"
)

type Event struct {
    ID        string          `json:"id"`
    Type      string          `json:"type"`
    Data      json.RawMessage `json:"data"`
    Metadata  EventMetadata   `json:"metadata"`
    Timestamp time.Time       `json:"timestamp"`
    Version   int64           `json:"version"`
}

type EventMetadata struct {
    UserID    string `json:"user_id,omitempty"`
    SessionID string `json:"session_id,omitempty"`
    Source    string `json:"source"`
    TraceID   string `json:"trace_id,omitempty"`
}

type EventStore interface {
    Append(streamID string, events []Event) error
    GetEvents(streamID string, fromVersion int64) ([]Event, error)
    Subscribe(streamID string, handler EventHandler) error
}

type EventHandler func(event Event) error
```

### 1.2 Command Infrastructure

```go
// server/commands/types.go
package commands

import (
    "context"
    "time"
)

type Command interface {
    CommandType() string
    Validate() error
    Authorized(userID string) bool
}

type CommandHandler interface {
    Handle(ctx context.Context, cmd Command) ([]Event, error)
}

type CommandBus interface {
    Dispatch(ctx context.Context, cmd Command) error
    RegisterHandler(cmdType string, handler CommandHandler)
}

// server/commands/bus.go
type commandBus struct {
    handlers map[string]CommandHandler
    eventStore EventStore
    logger     *jst_log.Logger
}

func (b *commandBus) Dispatch(ctx context.Context, cmd Command) error {
    handler, exists := b.handlers[cmd.CommandType()]
    if !exists {
        return fmt.Errorf("no handler for command type: %s", cmd.CommandType())
    }
    
    events, err := handler.Handle(ctx, cmd)
    if err != nil {
        return err
    }
    
    // Store events
    streamID := b.getStreamID(cmd)
    return b.eventStore.Append(streamID, events)
}
```

### 1.3 NATS Event Store Implementation

```go
// server/events/nats_store.go
package events

import (
    "encoding/json"
    "fmt"
    "github.com/nats-io/nats.go"
)

type NATSEventStore struct {
    nc     *nats.Conn
    logger *jst_log.Logger
}

func NewNATSEventStore(nc *nats.Conn, logger *jst_log.Logger) *NATSEventStore {
    return &NATSEventStore{
        nc:     nc,
        logger: logger,
    }
}

func (s *NATSEventStore) Append(streamID string, events []Event) error {
    for _, event := range events {
        data, err := json.Marshal(event)
        if err != nil {
            return fmt.Errorf("marshal event: %w", err)
        }
        
        subject := fmt.Sprintf("events.%s", streamID)
        err = s.nc.Publish(subject, data)
        if err != nil {
            return fmt.Errorf("publish event: %w", err)
        }
        
        s.logger.Debug("published event: %s", event.Type)
    }
    return nil
}

func (s *NATSEventStore) Subscribe(streamID string, handler EventHandler) error {
    subject := fmt.Sprintf("events.%s", streamID)
    
    _, err := s.nc.Subscribe(subject, func(msg *nats.Msg) {
        var event Event
        if err := json.Unmarshal(msg.Data, &event); err != nil {
            s.logger.Error("unmarshal event: %v", err)
            return
        }
        
        if err := handler(event); err != nil {
            s.logger.Error("handle event: %v", err)
        }
    })
    
    return err
}
```

## Phase 2: Article Service Migration (Week 3-4)

### 2.1 Article Commands

```go
// server/articles/commands.go
package articles

import (
    "time"
    "github.com/google/uuid"
)

type CreateArticleCommand struct {
    Title     string `json:"title" validate:"required,max=200"`
    Content   string `json:"content" validate:"required,max=10000"`
    AuthorID  string `json:"author_id" validate:"required"`
    UserID    string `json:"-"` // From auth context
}

func (c CreateArticleCommand) CommandType() string { return "create_article" }

func (c CreateArticleCommand) Validate() error {
    if c.Title == "" {
        return fmt.Errorf("title is required")
    }
    if len(c.Title) > 200 {
        return fmt.Errorf("title too long")
    }
    if c.Content == "" {
        return fmt.Errorf("content is required")
    }
    if len(c.Content) > 10000 {
        return fmt.Errorf("content too long")
    }
    return nil
}

func (c CreateArticleCommand) Authorized(userID string) bool {
    return c.AuthorID == userID
}

type UpdateArticleCommand struct {
    ID        string `json:"id" validate:"required"`
    Title     string `json:"title" validate:"required,max=200"`
    Content   string `json:"content" validate:"required,max=10000"`
    UserID    string `json:"-"` // From auth context
}

func (c UpdateArticleCommand) CommandType() string { return "update_article" }

type DeleteArticleCommand struct {
    ID     string `json:"id" validate:"required"`
    UserID string `json:"-"` // From auth context
}

func (c DeleteArticleCommand) CommandType() string { return "delete_article" }
```

### 2.2 Article Events

```go
// server/articles/events.go
package articles

import (
    "encoding/json"
    "time"
)

type ArticleCreatedEvent struct {
    ID        string    `json:"id"`
    Title     string    `json:"title"`
    Content   string    `json:"content"`
    AuthorID  string    `json:"author_id"`
    CreatedAt time.Time `json:"created_at"`
}

type ArticleUpdatedEvent struct {
    ID        string    `json:"id"`
    Title     string    `json:"title"`
    Content   string    `json:"content"`
    UpdatedAt time.Time `json:"updated_at"`
    Version   int64     `json:"version"`
}

type ArticleDeletedEvent struct {
    ID        string    `json:"id"`
    DeletedAt time.Time `json:"deleted_at"`
}

type ArticleRevisionCreatedEvent struct {
    ID        string    `json:"id"`
    ArticleID string    `json:"article_id"`
    Content   string    `json:"content"`
    CreatedAt time.Time `json:"created_at"`
}
```

### 2.3 Article Command Handler

```go
// server/articles/handler.go
package articles

import (
    "context"
    "time"
    "github.com/google/uuid"
)

type ArticleCommandHandler struct {
    repo       ArticleRepo
    logger     *jst_log.Logger
}

func NewArticleCommandHandler(repo ArticleRepo, logger *jst_log.Logger) *ArticleCommandHandler {
    return &ArticleCommandHandler{
        repo:   repo,
        logger: logger,
    }
}

func (h *ArticleCommandHandler) Handle(ctx context.Context, cmd Command) ([]Event, error) {
    switch c := cmd.(type) {
    case CreateArticleCommand:
        return h.handleCreateArticle(ctx, c)
    case UpdateArticleCommand:
        return h.handleUpdateArticle(ctx, c)
    case DeleteArticleCommand:
        return h.handleDeleteArticle(ctx, c)
    default:
        return nil, fmt.Errorf("unknown command type: %T", cmd)
    }
}

func (h *ArticleCommandHandler) handleCreateArticle(ctx context.Context, cmd CreateArticleCommand) ([]Event, error) {
    // Validate command
    if err := cmd.Validate(); err != nil {
        return nil, err
    }
    
    // Check authorization
    if !cmd.Authorized(cmd.UserID) {
        return nil, fmt.Errorf("unauthorized")
    }
    
    // Create article
    article := &Article{
        ID:        uuid.New().String(),
        Title:     cmd.Title,
        Content:   cmd.Content,
        AuthorID:  cmd.AuthorID,
        CreatedAt: time.Now(),
        UpdatedAt: time.Now(),
    }
    
    // Save to database
    if err := h.repo.Create(article); err != nil {
        return nil, fmt.Errorf("create article: %w", err)
    }
    
    // Create events
    event := ArticleCreatedEvent{
        ID:        article.ID,
        Title:     article.Title,
        Content:   article.Content,
        AuthorID:  article.AuthorID,
        CreatedAt: article.CreatedAt,
    }
    
    eventData, _ := json.Marshal(event)
    
    return []Event{{
        ID:        uuid.New().String(),
        Type:      "article.created",
        Data:      eventData,
        Timestamp: time.Now(),
        Version:   1,
    }}, nil
}
```

### 2.4 Article Event Handlers

```go
// server/articles/event_handlers.go
package articles

import (
    "encoding/json"
    "fmt"
)

type ArticleEventHandler struct {
    readModel ArticleReadModel
    hub       *web.Hub
    logger    *jst_log.Logger
}

func NewArticleEventHandler(readModel ArticleReadModel, hub *web.Hub, logger *jst_log.Logger) *ArticleEventHandler {
    return &ArticleEventHandler{
        readModel: readModel,
        hub:       hub,
        logger:    logger,
    }
}

func (h *ArticleEventHandler) Handle(event Event) error {
    switch event.Type {
    case "article.created":
        return h.handleArticleCreated(event)
    case "article.updated":
        return h.handleArticleUpdated(event)
    case "article.deleted":
        return h.handleArticleDeleted(event)
    default:
        h.logger.Debug("ignoring unknown event type: %s", event.Type)
        return nil
    }
}

func (h *ArticleEventHandler) handleArticleCreated(event Event) error {
    var articleEvent ArticleCreatedEvent
    if err := json.Unmarshal(event.Data, &articleEvent); err != nil {
        return fmt.Errorf("unmarshal article created event: %w", err)
    }
    
    // Update read model
    article := &Article{
        ID:        articleEvent.ID,
        Title:     articleEvent.Title,
        Content:   articleEvent.Content,
        AuthorID:  articleEvent.AuthorID,
        CreatedAt: articleEvent.CreatedAt,
        UpdatedAt: articleEvent.CreatedAt,
    }
    
    if err := h.readModel.Create(article); err != nil {
        return fmt.Errorf("update read model: %w", err)
    }
    
    // Notify real-time clients
    h.hub.Broadcast(&web.WebSocketMessage{
        Type:    "article.created",
        Data:    article,
        UserID:  articleEvent.AuthorID,
    })
    
    return nil
}
```

## Phase 3: HTTP Layer Integration (Week 5-6)

### 3.1 Updated HTTP Handlers

```go
// server/web/routes.go (updated)
func handleArticleNew(l *jst_log.Logger, cmdBus commands.CommandBus) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Parse request
        var req struct {
            Title   string `json:"title"`
            Content string `json:"content"`
        }
        
        if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
            http.Error(w, "invalid request body", http.StatusBadRequest)
            return
        }
        
        // Get user from context
        user, ok := r.Context().Value(who.UserKey).(whoApi.User)
        if !ok {
            http.Error(w, "unauthorized", http.StatusUnauthorized)
            return
        }
        
        // Create command
        cmd := articles.CreateArticleCommand{
            Title:    req.Title,
            Content:  req.Content,
            AuthorID: user.ID,
            UserID:   user.ID,
        }
        
        // Dispatch command
        if err := cmdBus.Dispatch(r.Context(), cmd); err != nil {
            l.Error("dispatch command: %v", err)
            http.Error(w, "internal server error", http.StatusInternalServerError)
            return
        }
        
        // Return success (events will handle the rest)
        w.WriteHeader(http.StatusAccepted)
        json.NewEncoder(w).Encode(map[string]string{
            "status": "accepted",
            "message": "article creation in progress",
        })
    })
}
```

### 3.2 Query Handlers

```go
// server/articles/queries.go
package articles

type ArticleQueries struct {
    readModel ArticleReadModel
}

func (q *ArticleQueries) List() ([]*Article, error) {
    return q.readModel.List()
}

func (q *ArticleQueries) GetByID(id string) (*Article, error) {
    return q.readModel.GetByID(id)
}

func (q *ArticleQueries) GetByAuthor(authorID string) ([]*Article, error) {
    return q.readModel.GetByAuthor(authorID)
}

// server/web/routes.go (query handlers)
func handleArticleList(l *jst_log.Logger, queries *articles.ArticleQueries) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        articles, err := queries.List()
        if err != nil {
            l.Error("list articles: %v", err)
            http.Error(w, "internal server error", http.StatusInternalServerError)
            return
        }
        
        json.NewEncoder(w).Encode(articles)
    })
}
```

## Phase 4: Real-time Integration (Week 7-8)

### 4.1 Enhanced WebSocket Hub

```go
// server/web/socket.go (updated)
func (h *Hub) handleEvent(event events.Event) {
    // Convert event to WebSocket message
    msg := &WebSocketMessage{
        Type:      event.Type,
        Data:      event.Data,
        UserID:    event.Metadata.UserID,
        Timestamp: event.Timestamp.Unix(),
    }
    
    // Broadcast to relevant clients
    switch event.Type {
    case "article.created", "article.updated", "article.deleted":
        h.broadcastToArticleSubscribers(event, msg)
    case "user.logged_in", "user.logged_out":
        h.broadcastToUserSubscribers(event, msg)
    default:
        h.Broadcast(msg)
    }
}

func (h *Hub) broadcastToArticleSubscribers(event events.Event, msg *WebSocketMessage) {
    // Extract article ID from event
    var articleID string
    switch event.Type {
    case "article.created":
        var articleEvent articles.ArticleCreatedEvent
        json.Unmarshal(event.Data, &articleEvent)
        articleID = articleEvent.ID
    case "article.updated":
        var articleEvent articles.ArticleUpdatedEvent
        json.Unmarshal(event.Data, &articleEvent)
        articleID = articleEvent.ID
    }
    
    // Send to clients subscribed to this article
    h.mu.RLock()
    for client := range h.clients {
        if client.Topics[fmt.Sprintf("article:%s", articleID)] {
            select {
            case client.Send <- msg.ToJSON():
            default:
                close(client.Send)
                delete(h.clients, client)
            }
        }
    }
    h.mu.RUnlock()
}
```

### 4.2 Event Subscription

```go
// server/web/hub.go (updated)
func (h *Hub) Run() {
    // Subscribe to events
    h.subscribeToEvents()
    
    for {
        select {
        case client := <-h.register:
            h.mu.Lock()
            h.clients[client] = true
            h.mu.Unlock()
            h.logger.Info("Client registered: %s", client.ID)
            
        case client := <-h.unregister:
            h.mu.Lock()
            if _, ok := h.clients[client]; ok {
                delete(h.clients, client)
                close(client.Send)
            }
            h.mu.Unlock()
            h.logger.Info("Client unregistered: %s", client.ID)
            
        case message := <-h.broadcast:
            h.broadcastMessage(message)
        }
    }
}

func (h *Hub) subscribeToEvents() {
    // Subscribe to article events
    h.eventStore.Subscribe("articles", func(event events.Event) error {
        h.handleEvent(event)
        return nil
    })
    
    // Subscribe to user events
    h.eventStore.Subscribe("users", func(event events.Event) error {
        h.handleEvent(event)
        return nil
    })
}
```

## Phase 5: Migration Strategy (Week 9-10)

### 5.1 Gradual Migration

```go
// server/main.go (updated)
func run(ctx context.Context) error {
    // ... existing setup ...
    
    // Initialize event-driven components
    eventStore := events.NewNATSEventStore(nc, lRoot.WithBreadcrumb("events"))
    cmdBus := commands.NewCommandBus(eventStore, lRoot.WithBreadcrumb("commands"))
    
    // Register command handlers
    articleHandler := articles.NewArticleCommandHandler(articleRepo, lRoot.WithBreadcrumb("articles"))
    cmdBus.RegisterHandler("create_article", articleHandler)
    cmdBus.RegisterHandler("update_article", articleHandler)
    cmdBus.RegisterHandler("delete_article", articleHandler)
    
    // Initialize event handlers
    articleEventHandler := articles.NewArticleEventHandler(articleRepo, hub, lRoot.WithBreadcrumb("article_events"))
    eventStore.Subscribe("articles", articleEventHandler.Handle)
    
    // Initialize queries
    articleQueries := &articles.ArticleQueries{ReadModel: articleRepo}
    
    // Update HTTP server with new handlers
    httpServer := web.New(ctx, nc, conf.WebJwtSecret, lRoot.WithBreadcrumb("http"), 
        articleQueries, cmdBus, conf.Flags.ProxyFrontend)
    
    // ... rest of setup ...
}
```

### 5.2 Feature Flags

```go
// server/conf.go (updated)
type Flags struct {
    NatsEmbedded  bool
    ProxyFrontend bool
    LogLevel      string
    EventDriven   bool // New flag
}

// server/web/routes.go (conditional handlers)
func routes(mux *http.ServeMux, l *jst_log.Logger, repo articles.ArticleRepo, 
    queries *articles.ArticleQueries, cmdBus commands.CommandBus, nc *nats.Conn, 
    embeddedFS fs.FS, jwtSecret string, dev bool, eventDriven bool) {
    
    if eventDriven {
        // Use event-driven handlers
        mux.Handle("POST /api/articles", handleArticleNew(l, cmdBus))
        mux.Handle("GET /api/articles", handleArticleList(l, queries))
    } else {
        // Use traditional handlers
        mux.Handle("POST /api/articles", handleArticleNew(l, repo, nc))
        mux.Handle("GET /api/articles", handleArticleList(l, repo))
    }
    
    // ... other routes ...
}
```

## Phase 6: Testing & Validation (Week 11-12)

### 6.1 Event Testing

```go
// server/articles/events_test.go
func TestArticleEventHandling(t *testing.T) {
    // Setup
    repo := &MockArticleRepo{}
    hub := &MockHub{}
    handler := NewArticleEventHandler(repo, hub, &MockLogger{})
    
    // Test article created event
    event := Event{
        Type: "article.created",
        Data: json.RawMessage(`{
            "id": "test-id",
            "title": "Test Article",
            "content": "Test content",
            "author_id": "user-1",
            "created_at": "2024-01-01T00:00:00Z"
        }`),
    }
    
    err := handler.Handle(event)
    assert.NoError(t, err)
    
    // Verify read model was updated
    assert.True(t, repo.CreateCalled)
    
    // Verify real-time notification was sent
    assert.True(t, hub.BroadcastCalled)
}
```

### 6.2 Command Testing

```go
// server/articles/commands_test.go
func TestCreateArticleCommand(t *testing.T) {
    // Setup
    repo := &MockArticleRepo{}
    handler := NewArticleCommandHandler(repo, &MockLogger{})
    
    cmd := CreateArticleCommand{
        Title:    "Test Article",
        Content:  "Test content",
        AuthorID: "user-1",
        UserID:   "user-1",
    }
    
    events, err := handler.Handle(context.Background(), cmd)
    assert.NoError(t, err)
    assert.Len(t, events, 1)
    assert.Equal(t, "article.created", events[0].Type)
}
```

## Benefits of Event-Driven Architecture

### 1. **Real-time Capabilities**
- Events automatically trigger real-time updates
- Better user experience with live updates
- Reduced polling and WebSocket complexity

### 2. **Scalability**
- Events can be processed asynchronously
- Easy to add new event handlers
- Better separation of concerns

### 3. **Audit Trail**
- Complete history of all changes
- Easy to debug and trace issues
- Compliance and regulatory requirements

### 4. **Flexibility**
- Easy to add new features
- Event replay for testing
- Event sourcing capabilities

### 5. **Performance**
- Asynchronous processing
- Better caching opportunities
- Reduced database load

## Migration Checklist

### Phase 1: Foundation
- [ ] Implement Event and Command types
- [ ] Create NATS Event Store
- [ ] Implement Command Bus
- [ ] Add event subscription mechanism

### Phase 2: Article Service
- [ ] Create Article commands
- [ ] Implement Article events
- [ ] Create command handlers
- [ ] Implement event handlers
- [ ] Update read models

### Phase 3: HTTP Integration
- [ ] Update HTTP handlers to use commands
- [ ] Implement query handlers
- [ ] Add feature flags for gradual migration
- [ ] Update WebSocket integration

### Phase 4: Real-time Features
- [ ] Enhance WebSocket hub
- [ ] Implement event broadcasting
- [ ] Add topic-based subscriptions
- [ ] Test real-time updates

### Phase 5: Migration
- [ ] Add feature flags
- [ ] Gradual rollout
- [ ] Monitor performance
- [ ] Validate functionality

### Phase 6: Testing
- [ ] Unit tests for commands
- [ ] Unit tests for events
- [ ] Integration tests
- [ ] Performance testing

## Conclusion

This event-driven migration provides:
- **Better real-time capabilities** with automatic event broadcasting
- **Improved scalability** through asynchronous processing
- **Complete audit trail** of all system changes
- **Easier feature development** with event-driven patterns
- **Gradual migration** with feature flags

The key is to implement this incrementally, starting with the foundation and gradually migrating services one by one while maintaining backward compatibility. 