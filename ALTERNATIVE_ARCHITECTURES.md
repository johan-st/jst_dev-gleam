# Alternative Architectures and Considerations

## 1. Event Sourcing Architecture

### Overview
Store all state changes as events and reconstruct state by replaying events.

```gleam
// src/events/types.gleam
pub type Event {
  ArticleCreated(ArticleCreatedEvent)
  ArticleUpdated(ArticleUpdatedEvent)
  UserLoggedIn(UserLoggedInEvent)
  UrlShortened(UrlShortenedEvent)
}

pub type ArticleCreatedEvent {
  ArticleCreatedEvent(
    id: String,
    title: String,
    content: String,
    author_id: String,
    timestamp: Int,
  )
}

// Event store
pub type EventStore {
  EventStore(
    events: List(Event),
    version: Int,
  )
}

pub fn apply_event(state: State, event: Event) -> State {
  case event {
    ArticleCreated(event) -> {
      let new_articles = [event_to_article(event), ..state.articles]
      State(
        articles: new_articles,
        users: state.users,
        urls: state.urls,
      )
    }
    ArticleUpdated(event) -> {
      let updated_articles = list.map(state.articles, fn(article) {
        case article.id == event.article_id {
          True -> update_article(article, event)
          False -> article
        }
      })
      State(
        articles: updated_articles,
        users: state.users,
        urls: state.urls,
      )
    }
  }
}
```

### Benefits
- **Audit Trail**: Complete history of all changes
- **Temporal Queries**: Can query state at any point in time
- **Debugging**: Easy to replay events to reproduce issues
- **Scalability**: Events can be processed asynchronously

### Drawbacks
- **Complexity**: More complex than simple state updates
- **Performance**: Event replay can be expensive for large histories
- **Storage**: Requires more storage space

## 2. CQRS (Command Query Responsibility Segregation)

### Overview
Separate read and write operations into different models.

```gleam
// Commands (Write Model)
pub type Command {
  CreateArticle(CreateArticleCommand)
  UpdateArticle(UpdateArticleCommand)
  DeleteArticle(DeleteArticleCommand)
}

pub type CreateArticleCommand {
  CreateArticleCommand(
    title: String,
    content: String,
    author_id: String,
  )
}

// Queries (Read Model)
pub type Query {
  GetArticle(GetArticleQuery)
  ListArticles(ListArticlesQuery)
  SearchArticles(SearchArticlesQuery)
}

pub type GetArticleQuery {
  GetArticleQuery(
    id: String,
    include_revisions: Bool,
  )
}

// Command Handler
pub fn handle_command(command: Command, context: Context) -> Result(Nil, String) {
  case command {
    CreateArticle(cmd) -> {
      // Validate command
      validate_create_article(cmd)?
      
      // Apply business logic
      let article = create_article_entity(cmd)
      
      // Persist to write model
      save_article(article, context)?
      
      // Update read model
      update_read_model(article, context)?
      
      // Publish event
      publish_event(ArticleCreated(article), context)
      
      Ok(Nil)
    }
  }
}

// Query Handler
pub fn handle_query(query: Query, context: Context) -> Result(QueryResult, String) {
  case query {
    GetArticle(q) -> {
      let article = get_article_from_read_model(q.id, context)?
      case q.include_revisions {
        True -> {
          let revisions = get_article_revisions(q.id, context)?
          Ok(ArticleWithRevisions(article, revisions))
        }
        False -> Ok(ArticleOnly(article))
      }
    }
  }
}
```

### Benefits
- **Performance**: Optimized read and write models
- **Scalability**: Can scale reads and writes independently
- **Flexibility**: Different read models for different use cases
- **Consistency**: Eventual consistency with strong consistency for writes

### Drawbacks
- **Complexity**: More complex than traditional CRUD
- **Consistency**: Eventual consistency challenges
- **Development Time**: More upfront design required

## 3. Microservices with Gleam

### Overview
Break down the application into smaller, focused services.

```gleam
// src/services/articles/service.gleam
pub type ArticlesService {
  ArticlesService(
    repo: ArticleRepo,
    event_bus: EventBus,
    logger: Logger,
  )
}

pub fn create_article_service(context: Context) -> ArticlesService {
  ArticlesService(
    repo: create_article_repo(context),
    event_bus: create_event_bus(context),
    logger: context.logger,
  )
}

// src/services/auth/service.gleam
pub type AuthService {
  AuthService(
    user_repo: UserRepo,
    jwt_secret: String,
    logger: Logger,
  )
}

// src/services/urls/service.gleam
pub type UrlService {
  UrlService(
    url_repo: UrlRepo,
    logger: Logger,
  )
}

// Service communication via NATS
pub fn service_discovery() -> Effect(ServiceMsg) {
  effect.subscribe_to_nats("service.discovery")
}

pub fn call_service(service: String, method: String, payload: String) -> Effect(ServiceMsg) {
  effect.publish_to_nats("service.{service}.{method}", payload)
}
```

### Benefits
- **Independent Deployment**: Services can be deployed separately
- **Technology Diversity**: Different services can use different tech stacks
- **Team Autonomy**: Teams can work on services independently
- **Fault Isolation**: Service failures don't bring down entire system

### Drawbacks
- **Distributed System Complexity**: Network failures, latency, etc.
- **Data Consistency**: Harder to maintain consistency across services
- **Operational Overhead**: More infrastructure to manage

## 4. GraphQL with Gleam

### Overview
Use GraphQL for flexible data querying and real-time subscriptions.

```gleam
// src/graphql/schema.gleam
pub type GraphQLSchema {
  GraphQLSchema(
    queries: List(QueryField),
    mutations: List(MutationField),
    subscriptions: List(SubscriptionField),
  )
}

pub type QueryField {
  QueryField(
    name: String,
    resolver: GraphQLResolver,
  )
}

pub fn articles_query() -> QueryField {
  QueryField(
    name: "articles",
    resolver: articles_resolver,
  )
}

pub fn articles_resolver(args: GraphQLArgs, context: Context) -> Result(GraphQLValue, String) {
  case args.get("limit") {
    Some(limit) -> {
      let articles = get_articles_with_limit(limit, context)?
      Ok(encode_articles(articles))
    }
    None -> {
      let articles = get_all_articles(context)?
      Ok(encode_articles(articles))
    }
  }
}

// Real-time subscriptions
pub fn article_subscription() -> SubscriptionField {
  SubscriptionField(
    name: "articleUpdates",
    resolver: article_updates_resolver,
  )
}

pub fn article_updates_resolver(args: GraphQLArgs, context: Context) -> Result(Subscription, String) {
  let article_id = args.get("articleId")?
  let subscription = subscribe_to_article_updates(article_id, context)?
  Ok(subscription)
}
```

### Benefits
- **Flexible Queries**: Clients can request exactly what they need
- **Real-time Subscriptions**: Built-in support for live updates
- **Type Safety**: GraphQL schema provides type safety
- **Documentation**: Self-documenting API

### Drawbacks
- **Complexity**: More complex than REST APIs
- **Performance**: Over-fetching and N+1 query problems
- **Learning Curve**: Team needs to learn GraphQL

## 5. Actor Model with Gleam

### Overview
Use actor-based concurrency for state management.

```gleam
// src/actors/article_actor.gleam
pub type ArticleActor {
  ArticleActor(
    id: String,
    state: ArticleState,
    mailbox: Mailbox(ArticleMsg),
  )
}

pub type ArticleState {
  ArticleState(
    article: Option(Article),
    editors: List(String), // user_ids
    version: Int,
  )
}

pub type ArticleMsg {
  GetArticle(String) // request_id
  UpdateArticle(UpdateArticleRequest)
  AddEditor(String) // user_id
  RemoveEditor(String) // user_id
}

pub fn article_actor_loop(actor: ArticleActor) -> Nil {
  case receive_message(actor.mailbox) {
    GetArticle(request_id) -> {
      let response = case actor.state.article {
        Some(article) -> Ok(article)
        None -> Error("Article not found")
      }
      send_response(request_id, response)
      article_actor_loop(actor)
    }
    UpdateArticle(request) -> {
      case actor.state.article {
        Some(article) -> {
          let updated_article = update_article(article, request)
          let new_state = ArticleState(
            article: Some(updated_article),
            editors: actor.state.editors,
            version: actor.state.version + 1,
          )
          let new_actor = ArticleActor(
            id: actor.id,
            state: new_state,
            mailbox: actor.mailbox,
          )
          publish_state_update(updated_article)
          article_actor_loop(new_actor)
        }
        None -> {
          // Handle error
          article_actor_loop(actor)
        }
      }
    }
  }
}
```

### Benefits
- **Concurrency**: Natural concurrency model
- **State Isolation**: Each actor has isolated state
- **Fault Tolerance**: Actor failures don't affect others
- **Scalability**: Easy to distribute actors across nodes

### Drawbacks
- **Complexity**: More complex than traditional threading
- **Debugging**: Harder to debug distributed state
- **Performance**: Message passing overhead

## 6. Considerations for All Architectures

### Performance Considerations

#### 1. **Caching Strategy**
```gleam
// src/cache/strategy.gleam
pub type CacheStrategy {
  WriteThrough
  WriteBehind
  ReadThrough
  CacheAside
}

pub fn cache_article(article: Article, strategy: CacheStrategy, context: Context) -> Result(Nil, String) {
  case strategy {
    WriteThrough -> {
      // Write to cache and database simultaneously
      cache.set("article:{article.id}", article)?
      database.save_article(article)?
      Ok(Nil)
    }
    WriteBehind -> {
      // Write to cache first, database later
      cache.set("article:{article.id}", article)?
      queue_background_write(article)
      Ok(Nil)
    }
  }
}
```

#### 2. **Database Optimization**
```gleam
// src/database/optimization.gleam
pub fn optimize_queries() -> List(QueryOptimization) {
  [
    QueryOptimization(
      name: "article_by_author_index",
      query: "CREATE INDEX idx_articles_author ON articles(author_id)",
    ),
    QueryOptimization(
      name: "article_search_index",
      query: "CREATE INDEX idx_articles_search ON articles USING gin(to_tsvector('english', title || ' ' || content))",
    ),
  ]
}
```

### Security Considerations

#### 1. **Authentication & Authorization**
```gleam
// src/security/auth.gleam
pub type Permission {
  ReadArticle(String) // article_id
  WriteArticle(String) // article_id
  DeleteArticle(String) // article_id
  Admin
}

pub fn check_permission(user: User, permission: Permission, context: Context) -> Result(Bool, String) {
  case permission {
    ReadArticle(article_id) -> {
      let article = get_article(article_id, context)?
      Ok(article.is_public || article.author_id == user.id || user.has_role(Admin))
    }
    WriteArticle(article_id) -> {
      let article = get_article(article_id, context)?
      Ok(article.author_id == user.id || user.has_role(Admin))
    }
  }
}
```

#### 2. **Input Validation**
```gleam
// src/validation/input.gleam
pub fn validate_article_input(input: ArticleInput) -> Result(Article, String) {
  // Title validation
  case input.title {
    "" -> Error("Title cannot be empty")
    title if string.length(title) > 200 -> Error("Title too long")
    _ -> Ok(Nil)
  }?
  
  // Content validation
  case input.content {
    "" -> Error("Content cannot be empty")
    content if string.length(content) > 10000 -> Error("Content too long")
    _ -> Ok(Nil)
  }?
  
  // Sanitize content
  let sanitized_content = sanitize_html(input.content)
  
  Ok(Article(
    id: uuid.generate(),
    title: input.title,
    content: sanitized_content,
    author_id: input.author_id,
    created_at: timestamp_now(),
    updated_at: timestamp_now(),
  ))
}
```

### Monitoring & Observability

#### 1. **Metrics Collection**
```gleam
// src/monitoring/metrics.gleam
pub type Metric {
  Counter(name: String, value: Int)
  Gauge(name: String, value: Float)
  Histogram(name: String, value: Float)
}

pub fn record_metric(metric: Metric, context: Context) -> Nil {
  case metric {
    Counter(name, value) -> {
      context.metrics.increment(name, value)
    }
    Gauge(name, value) -> {
      context.metrics.set_gauge(name, value)
    }
    Histogram(name, value) -> {
      context.metrics.record_histogram(name, value)
    }
  }
}

pub fn track_request_duration(start_time: Int, endpoint: String, context: Context) -> Nil {
  let duration = timestamp_now() - start_time
  record_metric(Histogram("request_duration", float.from_int(duration)), context)
}
```

#### 2. **Distributed Tracing**
```gleam
// src/monitoring/tracing.gleam
pub type Trace {
  Trace(
    id: String,
    parent_id: Option(String),
    operation: String,
    start_time: Int,
    end_time: Option(Int),
    tags: Map(String, String),
  )
}

pub fn start_trace(operation: String, parent_id: Option(String)) -> Trace {
  Trace(
    id: uuid.generate(),
    parent_id: parent_id,
    operation: operation,
    start_time: timestamp_now(),
    end_time: None,
    tags: map.new(),
  )
}

pub fn end_trace(trace: Trace) -> Trace {
  Trace(
    id: trace.id,
    parent_id: trace.parent_id,
    operation: trace.operation,
    start_time: trace.start_time,
    end_time: Some(timestamp_now()),
    tags: trace.tags,
  )
}
```

### Deployment Considerations

#### 1. **Containerization**
```dockerfile
# Dockerfile for Gleam application
FROM gleamlang/gleam:latest as builder

WORKDIR /app
COPY . .
RUN gleam build

FROM erlang:24-alpine
WORKDIR /app
COPY --from=builder /app/build/erlang/ /app/
EXPOSE 8080
CMD ["erl", "-noshell", "-s", "jst_dev_server", "start"]
```

#### 2. **Configuration Management**
```gleam
// src/config/environment.gleam
pub type Environment {
  Development
  Staging
  Production
}

pub fn load_config(env: Environment) -> Result(Config, String) {
  case env {
    Development -> load_dev_config()
    Staging -> load_staging_config()
    Production -> load_production_config()
  }
}

pub fn load_production_config() -> Result(Config, String) {
  let nats_jwt = get_env_var("NATS_JWT")?
  let nats_nkey = get_env_var("NATS_NKEY")?
  let jwt_secret = get_env_var("JWT_SECRET")?
  
  Ok(Config(
    nats_jwt: nats_jwt,
    nats_nkey: nats_nkey,
    web_jwt_secret: jwt_secret,
    web_hash_salt: get_env_var("WEB_HASH_SALT")?,
    web_port: get_env_var("PORT")?,
    app_name: get_env_var("FLY_APP_NAME")?,
    flags: Flags(False, False, "info"),
  ))
}
```

## Recommendation

For your use case, I'd recommend a **hybrid approach**:

1. **Start with the subject-per-session architecture** (from the previous document)
2. **Add CQRS for complex queries** (article search, filtering)
3. **Use event sourcing for audit trails** (article revisions, user actions)
4. **Implement proper monitoring and security** from the start

This gives you:
- ✅ Immediate benefits from Omnimessage
- ✅ Scalability for complex queries
- ✅ Audit trails for compliance
- ✅ Type safety throughout
- ✅ Gradual migration path

The key is to start simple and add complexity only when needed, rather than implementing everything upfront. 