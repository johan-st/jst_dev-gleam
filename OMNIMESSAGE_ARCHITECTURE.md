# Omnimessage Architecture: Subject-per-Session with State Messages

## Overview

This document outlines an architecture where each user session gets its own NATS subject, and messages represent complete state updates. This approach leverages Omnimessage for real-time communication while allowing the Go server to continue managing state updates.

## Architecture Pattern

### 1. Subject-per-Session Model

```
NATS Subjects:
- session.{user_id}.{session_id}.state    # Complete state updates
- session.{user_id}.{session_id}.events   # Event stream (optional)
- session.{user_id}.{session_id}.control  # Control messages (auth, etc.)
```

### 2. State Message Structure

```gleam
// src/omni/types.gleam
pub type SessionState {
  SessionState(
    user_id: String,
    session_id: String,
    timestamp: Int,
    data: StateData,
  )
}

pub type StateData {
  ArticlesState(ArticlesState)
  ChatState(ChatState)
  UrlState(UrlState)
  UserState(UserState)
}

pub type ArticlesState {
  ArticlesState(
    articles: List(Article),
    current_article: Option(Article),
    revisions: List(Revision),
  )
}

pub type ChatState {
  ChatState(
    messages: List(ChatMessage),
    participants: List(User),
    typing_indicators: List(String), // user_ids
  )
}
```

## Implementation Approaches

### Approach 1: Pure Omnimessage (Recommended)

```gleam
// src/omni/server.gleam
import omnimessage_server as omni

pub fn session_app() -> omni.App(SessionState, SessionMsg) {
  omni.app(
    init,
    update,
    view,
    encoder_decoder,
  )
}

fn init(session_id: String, user_id: String) -> #(SessionState, Effect(SessionMsg)) {
  let initial_state = SessionState(
    user_id: user_id,
    session_id: session_id,
    timestamp: timestamp_now(),
    data: ArticlesState(ArticlesState([], None, [])),
  )
  
  #(initial_state, effect.batch([
    effect.subscribe_to_nats("session.{user_id}.{session_id}.state"),
    effect.subscribe_to_nats("session.{user_id}.{session_id}.events"),
  ]))
}

fn update(state: SessionState, msg: SessionMsg) -> #(SessionState, Effect(SessionMsg)) {
  case msg {
    NatsMessage(subject, payload) -> {
      case subject {
        "session.{user_id}.{session_id}.state" -> {
          let new_state = decode_state(payload)
          #(new_state, effect.none())
        }
        "session.{user_id}.{session_id}.events" -> {
          let event = decode_event(payload)
          let updated_state = apply_event(state, event)
          #(updated_state, effect.none())
        }
      }
    }
    UserAction(action) -> {
      // Handle user actions, publish to Go server
      let effect = effect.publish_to_nats("user.actions.{user_id}", encode_action(action))
      #(state, effect)
    }
  }
}
```

### Approach 2: Hybrid Go + Omnimessage

```gleam
// src/omni/hybrid.gleam
pub fn hybrid_session_app() -> omni.App(HybridState, HybridMsg) {
  omni.app(
    init_hybrid,
    update_hybrid,
    view_hybrid,
    encoder_decoder,
  )
}

type HybridState {
  HybridState(
    session_id: String,
    user_id: String,
    local_state: LocalState,
    server_state: Option(ServerState),
  )
}

type LocalState {
  LocalState(
    ui_state: UiState,
    pending_actions: List(UserAction),
  )
}

fn update_hybrid(state: HybridState, msg: HybridMsg) -> #(HybridState, Effect(HybridMsg)) {
  case msg {
    ServerStateUpdate(server_state) -> {
      let new_state = HybridState(
        session_id: state.session_id,
        user_id: state.user_id,
        local_state: state.local_state,
        server_state: Some(server_state),
      )
      #(new_state, effect.none())
    }
    UserAction(action) -> {
      // Add to pending actions, send to Go server
      let updated_local = LocalState(
        ui_state: state.local_state.ui_state,
        pending_actions: [action, ..state.local_state.pending_actions],
      )
      let new_state = HybridState(
        session_id: state.session_id,
        user_id: state.user_id,
        local_state: updated_local,
        server_state: state.server_state,
      )
      let effect = effect.publish_to_nats("user.actions.{state.user_id}", encode_action(action))
      #(new_state, effect)
    }
  }
}
```

## Go Server Integration

### 1. State Management Service

```go
// server/state/manager.go
type StateManager struct {
    nc     *nats.Conn
    logger *jst_log.Logger
}

func (sm *StateManager) PublishState(userID, sessionID string, state interface{}) error {
    subject := fmt.Sprintf("session.%s.%s.state", userID, sessionID)
    data, err := json.Marshal(state)
    if err != nil {
        return err
    }
    return sm.nc.Publish(subject, data)
}

func (sm *StateManager) PublishEvent(userID, sessionID string, event interface{}) error {
    subject := fmt.Sprintf("session.%s.%s.events", userID, sessionID)
    data, err := json.Marshal(event)
    if err != nil {
        return err
    }
    return sm.nc.Publish(subject, data)
}
```

### 2. Article Service Integration

```go
// server/articles/service.go
func (as *ArticleService) UpdateArticle(articleID string, updates map[string]interface{}) error {
    // Update in database
    article, err := as.repo.Update(articleID, updates)
    if err != nil {
        return err
    }
    
    // Publish state update to all sessions of affected users
    affectedUsers := as.getAffectedUsers(articleID)
    for _, userID := range affectedUsers {
        sessions := as.getUserSessions(userID)
        for _, sessionID := range sessions {
            state := as.buildArticleState(userID, sessionID)
            as.stateManager.PublishState(userID, sessionID, state)
        }
    }
    
    return nil
}
```

## Benefits of This Approach

### 1. **Separation of Concerns**
- Go server handles business logic and data persistence
- Omnimessage handles real-time communication and UI state
- Clear boundaries between server and client responsibilities

### 2. **Scalability**
- Each session is isolated on its own subject
- Easy to add/remove sessions without affecting others
- NATS handles message routing efficiently

### 3. **State Consistency**
- Complete state snapshots ensure consistency
- Event stream provides audit trail
- Easy to replay state for new connections

### 4. **Development Flexibility**
- Can gradually migrate from Go WebSocket to Omnimessage
- Existing Go services continue working
- Frontend can evolve independently

## Implementation Strategy

### Phase 1: Foundation
```gleam
// src/omni/foundation.gleam
pub fn setup_session_subscription(user_id: String, session_id: String) -> Effect(SessionMsg) {
  effect.subscribe_to_nats("session.{user_id}.{session_id}.state")
}

pub fn publish_user_action(user_id: String, action: UserAction) -> Effect(SessionMsg) {
  effect.publish_to_nats("user.actions.{user_id}", encode_action(action))
}
```

### Phase 2: State Synchronization
```gleam
// src/omni/sync.gleam
pub fn sync_article_state(article_id: String, context: Context) -> Result(Nil, String) {
  let article = get_article(article_id, context)?
  let state = build_article_state(article)
  
  // Publish to all user sessions
  publish_state_to_user_sessions(article.author_id, state, context)
  Ok(Nil)
}
```

### Phase 3: Real-time Features
```gleam
// src/omni/realtime.gleam
pub fn chat_component() -> omni.Component(ChatState, ChatMsg) {
  omni.component(
    init_chat,
    update_chat,
    view_chat,
    chat_encoder_decoder,
  )
}

fn update_chat(state: ChatState, msg: ChatMsg) -> #(ChatState, Effect(ChatMsg)) {
  case msg {
    SendMessage(content) -> {
      let effect = effect.publish_to_nats("chat.messages", encode_message(content))
      #(state, effect)
    }
    MessageReceived(message) -> {
      let new_messages = [message, ..state.messages]
      let new_state = ChatState(
        messages: new_messages,
        participants: state.participants,
        typing_indicators: state.typing_indicators,
      )
      #(new_state, effect.none())
    }
  }
}
```

## Migration Path

### Step 1: Add Omnimessage alongside existing WebSocket
- Keep current Go WebSocket implementation
- Add Omnimessage server for new features
- Use same NATS subjects for both

### Step 2: Gradual Feature Migration
- Start with read-only features (article viewing)
- Add real-time updates for specific components
- Migrate user interactions one by one

### Step 3: Full Omnimessage Migration
- Remove Go WebSocket code
- All real-time features use Omnimessage
- Go server focuses on business logic only

## Example: Article Editing Flow

```gleam
// User starts editing an article
fn handle_edit_start(article_id: String, user_id: String, context: Context) -> Effect(SessionMsg) {
  effect.batch([
    // Notify server about edit session
    effect.publish_to_nats("article.edit.start", encode_edit_start(article_id, user_id)),
    // Subscribe to article updates
    effect.subscribe_to_nats("article.{article_id}.updates"),
  ])
}

// Server publishes state update
fn handle_article_update(article: Article, context: Context) -> Result(Nil, String) {
  let state = build_article_state(article)
  
  // Publish to all editors
  let editors = get_article_editors(article.id, context)?
  for editor in editors {
    publish_state_to_user_sessions(editor.id, state, context)?
  }
  
  Ok(Nil)
}
```

## Conclusion

This architecture provides the best of both worlds:
- **Go server** continues handling business logic, data persistence, and complex operations
- **Omnimessage** provides modern, type-safe real-time communication
- **Subject-per-session** ensures clean separation and scalability
- **State messages** guarantee consistency and make debugging easier

The hybrid approach allows for gradual migration while maintaining system stability and providing immediate benefits from Omnimessage's type safety and developer experience. 