# Minimal Event-Driven Architecture

## Overview

A **minimal event-driven system** focuses on the essential components needed to achieve event-driven patterns with the fewest moving parts. This architecture prioritizes simplicity while maintaining the core benefits of event-driven design.

## Core Principles

### **1. Minimal Moving Parts**
- **Commands**: What you want to happen
- **Events**: What actually happened
- **Handlers**: How to respond to events
- **Store**: Where events are persisted

### **2. Clear Separation of Concerns**
- **Commands** trigger actions
- **Events** represent facts
- **Handlers** react to events
- **No complex orchestration**

### **3. Simple Mental Model**
- **Command** → **Handler** → **Event** → **Other Handlers**
- **Linear flow** with clear causality
- **Easy to trace** and debug

## Minimal Architecture Components

### **1. Command**
```go
// What you want to happen
type CreateArticleCommand struct {
    Title   string `json:"title"`
    Content string `json:"content"`
    UserID  string `json:"user_id"`
}
```

### **2. Event**
```go
// What actually happened (immutable fact)
type ArticleCreatedEvent struct {
    ID        string    `json:"id"`
    Title     string    `json:"title"`
    Content   string    `json:"content"`
    UserID    string    `json:"user_id"`
    CreatedAt time.Time `json:"created_at"`
}
```

### **3. Handler**
```go
// How to process commands and produce events
type ArticleHandler struct {
    repo ArticleRepository
}

func (h *ArticleHandler) Handle(cmd CreateArticleCommand) ([]Event, error) {
    // 1. Validate command
    if cmd.Title == "" {
        return nil, errors.New("title is required")
    }
    
    // 2. Create article
    article := &Article{
        ID:        uuid.New().String(),
        Title:     cmd.Title,
        Content:   cmd.Content,
        UserID:    cmd.UserID,
        CreatedAt: time.Now(),
    }
    
    // 3. Save to database
    if err := h.repo.Create(article); err != nil {
        return nil, err
    }
    
    // 4. Return event
    event := ArticleCreatedEvent{
        ID:        article.ID,
        Title:     article.Title,
        Content:   article.Content,
        UserID:    article.UserID,
        CreatedAt: article.CreatedAt,
    }
    
    return []Event{event}, nil
}
```

### **4. Event Store**
```go
// Simple in-memory event store
type EventStore struct {
    events []Event
    mu     sync.RWMutex
}

func (es *EventStore) Append(events []Event) error {
    es.mu.Lock()
    defer es.mu.Unlock()
    
    es.events = append(es.events, events...)
    return nil
}

func (es *EventStore) GetEvents(aggregateID string) []Event {
    es.mu.RLock()
    defer es.mu.RUnlock()
    
    var result []Event
    for _, event := range es.events {
        if event.AggregateID == aggregateID {
            result = append(result, event)
        }
    }
    return result
}
```

### **5. Event Handlers**
```go
// How to react to events
type NotificationHandler struct {
    emailService EmailService
}

func (h *NotificationHandler) Handle(event Event) error {
    switch e := event.(type) {
    case ArticleCreatedEvent:
        return h.emailService.SendNotification(
            e.UserID,
            "Article created: "+e.Title,
        )
    }
    return nil
}

type WebSocketHandler struct {
    hub *WebSocketHub
}

func (h *WebSocketHandler) Handle(event Event) error {
    // Broadcast to all connected clients
    h.hub.Broadcast(&WebSocketMessage{
        Type: event.Type(),
        Data: event,
    })
    return nil
}
```

## Minimal Implementation

### **1. Command Bus**
```go
// Simple command bus
type CommandBus struct {
    handlers map[string]CommandHandler
}

func (cb *CommandBus) Register(commandType string, handler CommandHandler) {
    cb.handlers[commandType] = handler
}

func (cb *CommandBus) Execute(command Command) error {
    handler, exists := cb.handlers[command.Type()]
    if !exists {
        return errors.New("no handler for command: " + command.Type())
    }
    
    events, err := handler.Handle(command)
    if err != nil {
        return err
    }
    
    // Store events
    if err := cb.eventStore.Append(events); err != nil {
        return err
    }
    
    // Publish events to handlers
    for _, event := range events {
        for _, eventHandler := range cb.eventHandlers {
            if err := eventHandler.Handle(event); err != nil {
                // Log error but don't fail the command
                log.Printf("Event handler error: %v", err)
            }
        }
    }
    
    return nil
}
```

### **2. HTTP Handler**
```go
// Simple HTTP endpoint
func (h *Handler) CreateArticle(w http.ResponseWriter, r *http.Request) {
    var cmd CreateArticleCommand
    if err := json.NewDecoder(r.Body).Decode(&cmd); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }
    
    // Add user ID from context
    cmd.UserID = getUserIDFromContext(r.Context())
    
    // Execute command
    if err := h.commandBus.Execute(cmd); err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }
    
    w.WriteHeader(http.StatusCreated)
}
```

### **3. WebSocket Hub**
```go
// Simple WebSocket for real-time updates
type WebSocketHub struct {
    clients map[*Client]bool
    mu      sync.RWMutex
}

func (h *WebSocketHub) Broadcast(message *WebSocketMessage) {
    h.mu.RLock()
    defer h.mu.RUnlock()
    
    for client := range h.clients {
        client.Send(message)
    }
}
```

## Complete Minimal System

### **Main Application**
```go
func main() {
    // Initialize components
    eventStore := &EventStore{events: []Event{}}
    commandBus := &CommandBus{
        handlers:     make(map[string]CommandHandler),
        eventStore:   eventStore,
        eventHandlers: []EventHandler{},
    }
    
    // Register command handlers
    articleHandler := &ArticleHandler{repo: &ArticleRepository{}}
    commandBus.Register("create_article", articleHandler)
    
    // Register event handlers
    notificationHandler := &NotificationHandler{emailService: &EmailService{}}
    websocketHandler := &WebSocketHandler{hub: &WebSocketHub{}}
    commandBus.RegisterEventHandlers(notificationHandler, websocketHandler)
    
    // Set up HTTP server
    handler := &Handler{commandBus: commandBus}
    
    http.HandleFunc("/api/articles", handler.CreateArticle)
    http.ListenAndServe(":8080", nil)
}
```

## Minimal Event-Driven Flow

### **1. Command Flow**
```
HTTP Request → CreateArticleCommand → ArticleHandler → ArticleCreatedEvent
```

### **2. Event Flow**
```
ArticleCreatedEvent → EventStore → NotificationHandler → EmailService
                   → WebSocketHandler → WebSocketHub → Clients
```

### **3. Complete Example**
```go
// 1. Client sends HTTP request
POST /api/articles
{
  "title": "My Article",
  "content": "Article content"
}

// 2. HTTP handler creates command
CreateArticleCommand{
  Title: "My Article",
  Content: "Article content",
  UserID: "user123"
}

// 3. Command handler processes command
ArticleHandler.Handle(command) → ArticleCreatedEvent

// 4. Event is stored
EventStore.Append([ArticleCreatedEvent])

// 5. Event handlers react
NotificationHandler.Handle(event) → Send email
WebSocketHandler.Handle(event) → Broadcast to clients

// 6. Clients receive real-time update
WebSocket message: {
  "type": "article_created",
  "data": {
    "id": "article123",
    "title": "My Article",
    "content": "Article content",
    "user_id": "user123",
    "created_at": "2024-01-01T00:00:00Z"
  }
}
```

## Key Benefits of Minimal Approach

### **1. Simple to Understand**
- **Linear flow**: Command → Handler → Event → Handlers
- **Clear causality**: Each event has a clear cause
- **Easy debugging**: Trace events through the system

### **2. Easy to Extend**
- **Add new commands**: Register new command handlers
- **Add new events**: Create new event types
- **Add new handlers**: Register new event handlers

### **3. Testable**
- **Unit test commands**: Test command handlers in isolation
- **Unit test events**: Test event handlers in isolation
- **Integration test**: Test complete flows

### **4. Scalable**
- **Add more handlers**: Without changing existing code
- **Add more commands**: Without changing existing code
- **Add more events**: Without changing existing code

## Minimal vs Complex Event-Driven

### **Minimal Approach**
```go
// Simple command handler
func (h *Handler) Handle(cmd CreateArticleCommand) ([]Event, error) {
    article := createArticle(cmd)
    saveToDatabase(article)
    return []Event{ArticleCreatedEvent{Article: article}}, nil
}

// Simple event handler
func (h *Handler) Handle(event Event) error {
    switch e := event.(type) {
    case ArticleCreatedEvent:
        sendNotification(e)
        broadcastToClients(e)
    }
    return nil
}
```

### **Complex Approach**
```go
// Complex command handler with saga, compensation, etc.
func (h *Handler) Handle(cmd CreateArticleCommand) ([]Event, error) {
    // Start saga
    saga := h.sagaManager.Start("create_article_saga")
    
    // Multiple steps with compensation
    step1 := saga.AddStep("validate_user", validateUser)
    step2 := saga.AddStep("create_article", createArticle)
    step3 := saga.AddStep("send_notification", sendNotification)
    
    // Complex orchestration
    if err := saga.Execute(); err != nil {
        saga.Compensate()
        return nil, err
    }
    
    return saga.Events(), nil
}
```

## Implementation Guidelines

### **1. Start Simple**
- **One command type** at a time
- **One event type** at a time
- **One handler** at a time

### **2. Keep Events Immutable**
- **Events are facts** - they never change
- **Events are append-only** - never modify existing events
- **Events have clear causality** - each event has a clear cause

### **3. Handle Failures Gracefully**
- **Command failures**: Return error, don't create events
- **Event handler failures**: Log error, don't fail the command
- **System failures**: Replay events from event store

### **4. Use Simple Patterns**
- **Command-Query Separation**: Commands change state, queries read state
- **Event Sourcing**: Store events, rebuild state from events
- **CQRS**: Separate read and write models

## Conclusion

A **minimal event-driven system** focuses on the essential components:

1. **Commands** - What you want to happen
2. **Events** - What actually happened
3. **Handlers** - How to respond
4. **Store** - Where events are kept

The key is to **start simple** and **add complexity only when needed**. A minimal event-driven system provides:

- **Clear separation** of concerns
- **Easy testing** and debugging
- **Simple extension** patterns
- **Real-time capabilities** by default

This approach is perfect for your situation because it provides event-driven benefits with minimal complexity, leveraging your existing Go backend and Gleam frontend expertise. 