# Go to Gleam Backend Migration Plan

## Overview

This document outlines the migration strategy for rewriting the existing Go backend into a Gleam application using Wisp, GWT, Lustre, Modem, and Omnimessage libraries.

## Current Architecture Analysis

### Existing Go Services
- **HTTP Server**: Web routes, static file serving, CORS, JWT auth
- **User Management (who)**: Authentication, user CRUD, JWT handling
- **Articles**: Blog post management with revisions
- **URL Shortener**: Short URL creation and redirection
- **NATS Integration**: Message bus for service communication
- **Logging**: Structured logging with breadcrumbs
- **WebSocket**: Real-time communication

### Key Features
- JWT-based authentication
- RESTful API endpoints
- Static file serving
- WebSocket support for real-time features
- NATS message bus integration
- CORS handling
- Development/production environment switching

## Migration Strategy

### Phase 1: Foundation Setup

#### 1.1 Update Gleam Dependencies
```toml
[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
wisp = ">= 1.8.0 and < 2.0.0"
gwt = ">= 2.1.1 and < 3.0.0"
lustre = ">= 5.2.1 and < 6.0.0"
modem = ">= 2.1.0 and < 3.0.0"
omnimessage_lustre = ">= 0.3.0 and < 1.0.0"
omnimessage_server = ">= 0.3.0 and < 1.0.0"
gleam_http = ">= 4.0.0 and < 5.0.0"
gleam_json = ">= 2.3.0 and < 3.0.0"
gleam_uri = ">= 1.0.0 and < 2.0.0"
```

#### 1.2 Core Types and Configuration
```gleam
// src/types.gleam
pub type Config {
  Config(
    nats_jwt: String,
    nats_nkey: String,
    web_jwt_secret: String,
    web_hash_salt: String,
    web_port: String,
    app_name: String,
    flags: Flags,
  )
}

pub type Flags {
  Flags(
    nats_embedded: Bool,
    proxy_frontend: Bool,
    log_level: String,
  )
}

pub type Context {
  Context(
    config: Config,
    nats_conn: Option(NatsConnection),
    logger: Logger,
  )
}
```

### Phase 2: Authentication System (who service)

#### 2.1 JWT Handling with GWT
```gleam
// src/auth/jwt.gleam
import gwt.{type Jwt, type Verified, type Unverified}

pub fn create_jwt(user_id: String, secret: String) -> Result(String, String) {
  let jwt_builder =
    gwt.new()
    |> gwt.set_subject(user_id)
    |> gwt.set_audience("jst_dev.who")
    |> gwt.set_expiration(timestamp_plus_hours(24))
  
  gwt.to_signed_string(jwt_builder, gwt.HS256, secret)
}

pub fn verify_jwt(token: String, secret: String) -> Result(Verified, String) {
  gwt.from_signed_string(token, secret)
}
```

#### 2.2 User Management
```gleam
// src/auth/user.gleam
pub type User {
  User(
    id: String,
    email: String,
    username: String,
    permissions: List(Permission),
  )
}

pub type Permission {
  Admin
  Editor
  Viewer
}

pub fn authenticate_user(email: String, password: String, context: Context) -> Result(User, String) {
  // Implementation using NATS for user lookup
}
```

### Phase 3: HTTP Server with Wisp

#### 3.1 Main Server Setup
```gleam
// src/server.gleam
import wisp.{type Request, type Response}

pub fn start_server(context: Context) -> Nil {
  let app = wisp.application(init, update, view)
  let assert Ok(_) = wisp.start(app, "#app", context)
}

pub fn init(context: Context) -> #(State, Effect(Msg)) {
  #(State(context), effect.none())
}

pub type State {
  State(context: Context)
}

pub type Msg {
  HttpRequest(Request)
  AuthMessage(AuthMsg)
  ArticleMessage(ArticleMsg)
  UrlMessage(UrlMsg)
}
```

#### 3.2 Route Handlers
```gleam
// src/routes.gleam
pub fn handle_articles(request: Request, context: Context) -> Response {
  case request.method {
    "GET" -> get_articles(request, context)
    "POST" -> create_article(request, context)
    "PUT" -> update_article(request, context)
    "DELETE" -> delete_article(request, context)
    _ -> wisp.method_not_allowed()
  }
}

pub fn handle_auth(request: Request, context: Context) -> Response {
  case request.method {
    "POST" -> login_user(request, context)
    "GET" -> check_auth(request, context)
    "DELETE" -> logout_user(request, context)
    _ -> wisp.method_not_allowed()
  }
}
```

### Phase 4: Articles Service

#### 4.1 Article Types
```gleam
// src/articles/types.gleam
pub type Article {
  Article(
    id: String,
    title: String,
    content: String,
    author_id: String,
    created_at: Int,
    updated_at: Int,
    revisions: List(Revision),
  )
}

pub type Revision {
  Revision(
    id: String,
    content: String,
    created_at: Int,
  )
}
```

#### 4.2 Article Repository
```gleam
// src/articles/repository.gleam
pub type ArticleRepo {
  ArticleRepo(
    nats_conn: NatsConnection,
    logger: Logger,
  )
}

pub fn create_article(article: Article, repo: ArticleRepo) -> Result(Article, String) {
  // NATS-based article creation
}

pub fn get_article(id: String, repo: ArticleRepo) -> Result(Article, String) {
  // NATS-based article retrieval
}
```

### Phase 5: URL Shortener Service

#### 5.1 URL Types
```gleam
// src/url_shortener/types.gleam
pub type ShortUrl {
  ShortUrl(
    id: String,
    original_url: String,
    short_code: String,
    created_by: String,
    created_at: Int,
    clicks: Int,
  )
}
```

#### 5.2 URL Service
```gleam
// src/url_shortener/service.gleam
pub fn create_short_url(original_url: String, user_id: String, context: Context) -> Result(ShortUrl, String) {
  let short_code = generate_short_code()
  let short_url = ShortUrl(
    id: uuid.generate(),
    original_url: original_url,
    short_code: short_code,
    created_by: user_id,
    created_at: timestamp_now(),
    clicks: 0,
  )
  
  // Save via NATS
  save_short_url(short_url, context)
}
```

### Phase 6: Real-time Communication with Omnimessage

#### 6.1 Client-Side Integration
```gleam
// jst_lustre/src/omni_client.gleam
import omnimessage_lustre as omniclient

pub fn chat_component() {
  omniclient.component(
    init,
    update,
    view,
    dict.new(),
    encoder_decoder,
    transports.websocket("ws://localhost:8080/omni-ws"),
    TransportState,
  )
}

pub type Msg {
  UserSendMessage(content: String)
  ServerMessage(ServerMessage)
  TransportState(TransportState)
}
```

#### 6.2 Server-Side Integration
```gleam
// src/omni_server.gleam
import omnimessage_server as omniserver

pub fn handle_websocket(request: Request, context: Context) -> Response {
  case request.path_segments(request.path), request.method {
    ["omni-ws"], "GET" ->
      omniserver.mist_websocket_application(
        request,
        chat.app(),
        context,
        fn(_) { Nil }
      )
    _ -> wisp.not_found()
  }
}
```

### Phase 7: Frontend Integration with Lustre

#### 7.1 Navigation with Modem
```gleam
// jst_lustre/src/navigation.gleam
import modem

pub fn init_navigation() -> #(Route, Effect(Msg)) {
  let route =
    modem.initial_uri()
    |> result.map(fn(uri) { uri.path_segments(uri.path) })
    |> fn(path) {
      case path {
        Ok(["articles"]) -> Articles
        Ok(["auth"]) -> Auth
        Ok(["urls"]) -> Urls
        _ -> Home
      }
    }

  #(route, modem.init(on_url_change))
}

pub type Route {
  Home
  Articles
  Auth
  Urls
}
```

## Implementation Phases

### Phase 1: Core Infrastructure (Week 1-2)
- [ ] Set up Gleam project structure
- [ ] Configure dependencies
- [ ] Implement configuration loading
- [ ] Set up basic Wisp server
- [ ] Implement logging system

### Phase 2: Authentication (Week 3-4)
- [ ] Implement JWT handling with GWT
- [ ] Create user management system
- [ ] Set up NATS integration for auth
- [ ] Implement login/logout endpoints
- [ ] Add middleware for JWT verification

### Phase 3: Articles Service (Week 5-6)
- [ ] Implement article types and repository
- [ ] Create CRUD endpoints
- [ ] Add revision system
- [ ] Implement NATS-based article operations
- [ ] Add article list and detail views

### Phase 4: URL Shortener (Week 7-8)
- [ ] Implement short URL types
- [ ] Create URL shortening logic
- [ ] Add redirect handling
- [ ] Implement click tracking
- [ ] Add URL management endpoints

### Phase 5: Real-time Features (Week 9-10)
- [ ] Set up Omnimessage server
- [ ] Implement WebSocket handling
- [ ] Add real-time chat functionality
- [ ] Integrate with frontend Lustre app
- [ ] Test real-time communication

### Phase 6: Frontend Integration (Week 11-12)
- [ ] Update Lustre app with Modem navigation
- [ ] Integrate with new backend APIs
- [ ] Add real-time features to frontend
- [ ] Implement proper error handling
- [ ] Add loading states and UX improvements

### Phase 7: Testing & Deployment (Week 13-14)
- [ ] Comprehensive testing
- [ ] Performance optimization
- [ ] Security audit
- [ ] Deployment configuration
- [ ] Documentation updates

## Key Benefits of Migration

### 1. Type Safety
- Gleam's strong type system prevents runtime errors
- Compile-time guarantees for data structures
- Better refactoring support

### 2. Functional Programming
- Immutable data structures
- Pure functions for better testing
- Pattern matching for cleaner code

### 3. Modern Web Stack
- Lustre for reactive frontend
- Wisp for type-safe HTTP handling
- Omnimessage for seamless real-time communication

### 4. Developer Experience
- Better error messages
- Hot reloading with Lustre dev tools
- Unified language for frontend and backend

## Migration Risks and Mitigation

### 1. Learning Curve
- **Risk**: Team needs to learn Gleam
- **Mitigation**: Start with small, isolated components

### 2. Ecosystem Maturity
- **Risk**: Smaller ecosystem than Go
- **Mitigation**: Focus on core functionality first

### 3. Performance
- **Risk**: Potential performance differences
- **Mitigation**: Benchmark critical paths early

### 4. Deployment Complexity
- **Risk**: Different deployment requirements
- **Mitigation**: Use existing Docker infrastructure

## Success Metrics

- [ ] All existing endpoints functional
- [ ] Real-time features working
- [ ] Performance comparable to Go version
- [ ] Type safety improvements
- [ ] Reduced bug count in production
- [ ] Faster development velocity

## Conclusion

This migration plan provides a structured approach to rewriting the Go backend in Gleam while maintaining all existing functionality and adding modern web development capabilities. The phased approach allows for incremental progress and risk mitigation throughout the process. 