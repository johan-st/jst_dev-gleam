# Pure Gleam Migration: Omnimessage-Only Architecture

## Overview

This document outlines a migration to **pure Gleam** where we eliminate all HTTP CRUD endpoints and rely solely on **Omnimessage** for all communication between frontend and backend. This creates a **message-driven architecture** where every interaction is a message exchange.

## Current Architecture vs Pure Gleam

### **Current Architecture**
```
Gleam Frontend (Lustre) ←→ HTTP API ←→ Go Backend
                ↓
        WebSocket (real-time only)
```

### **Pure Gleam Architecture**
```
Gleam Frontend (Lustre) ←→ Omnimessage ←→ Gleam Backend (Wisp)
                ↓
        All communication via messages
```

## Key Benefits of Pure Gleam + Omnimessage

### **1. Single Language Stack**
- **Backend**: Gleam with Wisp
- **Frontend**: Gleam with Lustre
- **Communication**: Omnimessage
- **Types**: Shared across entire stack

### **2. Message-Driven Architecture**
- **No HTTP endpoints** - Everything is a message
- **Real-time by default** - All updates are live
- **Type-safe messages** - Compile-time guarantees
- **Unified patterns** - Same message handling everywhere

### **3. Simplified Mental Model**
- **Commands**: "Create Article", "Update User"
- **Events**: "Article Created", "User Updated"
- **Queries**: "Get Articles", "Get User"
- **All via Omnimessage**

## Migration Plan

### **Phase 1: Foundation (Week 1)**

#### **1.1 Set up Gleam Backend with Wisp**
```bash
# Create new Gleam backend
gleam new server_gleam
cd server_gleam

# Add dependencies
gleam add wisp
gleam add omnimessage_server
gleam add gleam_json
gleam add gleam_http
```

#### **1.2 Define Shared Message Types**
```gleam
// shared/types.gleam
pub type Article = {
  id: String,
  title: String,
  content: String,
  created_at: String,
}

pub type CreateArticleCommand = {
  title: String,
  content: String,
}

pub type UpdateArticleCommand = {
  id: String,
  title: Option(String),
  content: Option(String),
}

pub type DeleteArticleCommand = {
  id: String,
}

pub type GetArticlesQuery = {
  limit: Option(Int),
  offset: Option(Int),
}

pub type GetArticleQuery = {
  id: String,
}

pub type ArticleCreatedEvent = {
  article: Article,
}

pub type ArticleUpdatedEvent = {
  article: Article,
}

pub type ArticleDeletedEvent = {
  id: String,
}

pub type ArticlesQueryResult = {
  articles: List(Article),
  total: Int,
}

pub type ArticleQueryResult = {
  article: Option(Article),
}
```

#### **1.3 Set up Omnimessage Server**
```gleam
// server/omnimessage_server.gleam
import gleam/io
import gleam/result
import omnimessage_server
import wisp

pub fn start_server() -> Result(Nil, wisp.Error) {
  let app = omnimessage_server.new()
  
  // Register message handlers
  let app = omnimessage_server.handle_command(app, "create_article", handle_create_article)
  let app = omnimessage_server.handle_command(app, "update_article", handle_update_article)
  let app = omnimessage_server.handle_command(app, "delete_article", handle_delete_article)
  let app = omnimessage_server.handle_query(app, "get_articles", handle_get_articles)
  let app = omnimessage_server.handle_query(app, "get_article", handle_get_article)
  
  // Start server
  omnimessage_server.start(app, port: 8080)
}
```

### **Phase 2: Message Handlers (Week 2)**

#### **2.1 Command Handlers**
```gleam
// server/handlers/command_handlers.gleam
import gleam/result
import gleam/io
import shared/types

pub fn handle_create_article(
  command: CreateArticleCommand,
  context: Context,
) -> Result(ArticleCreatedEvent, String) {
  // Generate ID
  let id = generate_uuid()
  
  // Create article
  let article = Article(
    id: id,
    title: command.title,
    content: command.content,
    created_at: timestamp_now(),
  )
  
  // Save to database
  case save_article(article, context) {
    Ok(_) -> Ok(ArticleCreatedEvent(article: article))
    Error(err) -> Error("Failed to create article: " <> err)
  }
}

pub fn handle_update_article(
  command: UpdateArticleCommand,
  context: Context,
) -> Result(ArticleUpdatedEvent, String) {
  // Get existing article
  case get_article_by_id(command.id, context) {
    Ok(Some(existing)) -> {
      // Update fields
      let updated = Article(
        id: existing.id,
        title: command.title |> option.unwrap(existing.title),
        content: command.content |> option.unwrap(existing.content),
        created_at: existing.created_at,
      )
      
      // Save to database
      case update_article(updated, context) {
        Ok(_) -> Ok(ArticleUpdatedEvent(article: updated))
        Error(err) -> Error("Failed to update article: " <> err)
      }
    }
    Ok(None) -> Error("Article not found")
    Error(err) -> Error("Failed to get article: " <> err)
  }
}

pub fn handle_delete_article(
  command: DeleteArticleCommand,
  context: Context,
) -> Result(ArticleDeletedEvent, String) {
  // Check if article exists
  case get_article_by_id(command.id, context) {
    Ok(Some(_)) -> {
      // Delete from database
      case delete_article(command.id, context) {
        Ok(_) -> Ok(ArticleDeletedEvent(id: command.id))
        Error(err) -> Error("Failed to delete article: " <> err)
      }
    }
    Ok(None) -> Error("Article not found")
    Error(err) -> Error("Failed to get article: " <> err)
  }
}
```

#### **2.2 Query Handlers**
```gleam
// server/handlers/query_handlers.gleam
import gleam/result
import gleam/io
import shared/types

pub fn handle_get_articles(
  query: GetArticlesQuery,
  context: Context,
) -> Result(ArticlesQueryResult, String) {
  let limit = query.limit |> option.unwrap(10)
  let offset = query.offset |> option.unwrap(0)
  
  case get_articles(limit, offset, context) {
    Ok(articles) -> {
      case get_articles_count(context) {
        Ok(total) -> Ok(ArticlesQueryResult(articles: articles, total: total))
        Error(err) -> Error("Failed to get count: " <> err)
      }
    }
    Error(err) -> Error("Failed to get articles: " <> err)
  }
}

pub fn handle_get_article(
  query: GetArticleQuery,
  context: Context,
) -> Result(ArticleQueryResult, String) {
  case get_article_by_id(query.id, context) {
    Ok(article) -> Ok(ArticleQueryResult(article: article))
    Error(err) -> Error("Failed to get article: " <> err)
  }
}
```

### **Phase 3: Frontend Migration (Week 3)**

#### **3.1 Update Frontend Dependencies**
```toml
# frontend/gleam.toml
[dependencies]
lustre = ">= 5.2.1 and < 6.0.0"
omnimessage_lustre = ">= 0.3.0 and < 1.0.0"
gleam_json = ">= 2.3.0 and < 3.0.0"
```

#### **3.2 Create Omnimessage Client**
```gleam
// frontend/omnimessage_client.gleam
import gleam/io
import gleam/result
import omnimessage_lustre
import shared/types

pub type Client = omnimessage_lustre.Client

pub fn connect() -> Result(Client, String) {
  omnimessage_lustre.connect("ws://localhost:8080/omnimessage")
}

pub fn create_article(
  client: Client,
  title: String,
  content: String,
) -> Result(Nil, String) {
  let command = CreateArticleCommand(title: title, content: content)
  omnimessage_lustre.send_command(client, "create_article", command)
}

pub fn update_article(
  client: Client,
  id: String,
  title: Option(String),
  content: Option(String),
) -> Result(Nil, String) {
  let command = UpdateArticleCommand(id: id, title: title, content: content)
  omnimessage_lustre.send_command(client, "update_article", command)
}

pub fn delete_article(
  client: Client,
  id: String,
) -> Result(Nil, String) {
  let command = DeleteArticleCommand(id: id)
  omnimessage_lustre.send_command(client, "delete_article", command)
}

pub fn get_articles(
  client: Client,
  limit: Option(Int),
  offset: Option(Int),
) -> Result(ArticlesQueryResult, String) {
  let query = GetArticlesQuery(limit: limit, offset: offset)
  omnimessage_lustre.send_query(client, "get_articles", query)
}

pub fn get_article(
  client: Client,
  id: String,
) -> Result(ArticleQueryResult, String) {
  let query = GetArticleQuery(id: id)
  omnimessage_lustre.send_query(client, "get_article", query)
}
```

#### **3.3 Update Lustre Application**
```gleam
// frontend/app.gleam
import gleam/io
import gleam/result
import lustre
import lustre/element
import lustre/element/html
import omnimessage_lustre
import shared/types

pub type Model = {
  client: Option(omnimessage_lustre.Client),
  articles: List(Article),
  loading: Bool,
  error: Option(String),
}

pub type Msg {
  Connected(omnimessage_lustre.Client)
  ConnectionFailed(String)
  ArticlesLoaded(ArticlesQueryResult)
  ArticlesLoadFailed(String)
  ArticleCreated(ArticleCreatedEvent)
  ArticleUpdated(ArticleUpdatedEvent)
  ArticleDeleted(ArticleDeletedEvent)
  CreateArticle(String, String)
  UpdateArticle(String, String, String)
  DeleteArticle(String)
  LoadArticles
}

pub fn init() -> Model {
  Model(
    client: None,
    articles: [],
    loading: False,
    error: None,
  )
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    Connected(client) -> {
      Model(..model, client: Some(client))
      |> load_articles()
    }
    
    ConnectionFailed(error) -> {
      Model(..model, error: Some(error))
    }
    
    ArticlesLoaded(result) -> {
      Model(..model, articles: result.articles, loading: False)
    }
    
    ArticlesLoadFailed(error) -> {
      Model(..model, error: Some(error), loading: False)
    }
    
    ArticleCreated(event) -> {
      let new_articles = [event.article, ..model.articles]
      Model(..model, articles: new_articles)
    }
    
    ArticleUpdated(event) -> {
      let updated_articles = list.map(model.articles, fn(article) {
        case article.id == event.article.id {
          True -> event.article
          False -> article
        }
      })
      Model(..model, articles: updated_articles)
    }
    
    ArticleDeleted(event) -> {
      let filtered_articles = list.filter(model.articles, fn(article) {
        article.id != event.id
      })
      Model(..model, articles: filtered_articles)
    }
    
    CreateArticle(title, content) -> {
      case model.client {
        Some(client) -> {
          case omnimessage_lustre.send_command(client, "create_article", 
            CreateArticleCommand(title: title, content: content)) {
            Ok(_) -> model
            Error(err) -> Model(..model, error: Some(err))
          }
        }
        None -> Model(..model, error: Some("Not connected"))
      }
    }
    
    UpdateArticle(id, title, content) -> {
      case model.client {
        Some(client) -> {
          case omnimessage_lustre.send_command(client, "update_article",
            UpdateArticleCommand(id: id, title: Some(title), content: Some(content))) {
            Ok(_) -> model
            Error(err) -> Model(..model, error: Some(err))
          }
        }
        None -> Model(..model, error: Some("Not connected"))
      }
    }
    
    DeleteArticle(id) -> {
      case model.client {
        Some(client) -> {
          case omnimessage_lustre.send_command(client, "delete_article",
            DeleteArticleCommand(id: id)) {
            Ok(_) -> model
            Error(err) -> Model(..model, error: Some(err))
          }
        }
        None -> Model(..model, error: Some("Not connected"))
      }
    }
    
    LoadArticles -> {
      case model.client {
        Some(client) -> {
          case omnimessage_lustre.send_query(client, "get_articles",
            GetArticlesQuery(limit: Some(50), offset: Some(0))) {
            Ok(_) -> Model(..model, loading: True)
            Error(err) -> Model(..model, error: Some(err))
          }
        }
        None -> Model(..model, error: Some("Not connected"))
      }
    }
  }
}

fn load_articles(model: Model) -> Model {
  case model.client {
    Some(client) -> {
      case omnimessage_lustre.send_query(client, "get_articles",
        GetArticlesQuery(limit: Some(50), offset: Some(0))) {
        Ok(_) -> Model(..model, loading: True)
        Error(err) -> Model(..model, error: Some(err))
      }
    }
    None -> model
  }
}

pub fn view(model: Model) -> element.Element(Msg) {
  div([], [
    h1([], [text("Articles")]),
    
    // Error display
    case model.error {
      Some(error) -> div([class("error")], [text(error)])
      None -> div([], [])
    },
    
    // Loading indicator
    case model.loading {
      True -> div([class("loading")], [text("Loading...")])
      False -> div([], [])
    },
    
    // Articles list
    div([class("articles")], [
      list.map(model.articles, fn(article) {
        article_card(article)
      })
    ]),
    
    // Create article form
    create_article_form(),
  ])
}

fn article_card(article: Article) -> element.Element(Msg) {
  div([class("article-card")], [
    h3([], [text(article.title)]),
    p([], [text(article.content)]),
    div([class("actions")], [
      button([on_click(fn(_) { UpdateArticle(article.id, article.title, article.content) })], [
        text("Edit")
      ]),
      button([on_click(fn(_) { DeleteArticle(article.id) })], [
        text("Delete")
      ]),
    ]),
  ])
}

fn create_article_form() -> element.Element(Msg) {
  // Simplified form - in real app you'd use proper form handling
  div([class("create-form")], [
    h3([], [text("Create New Article")]),
    button([on_click(fn(_) { CreateArticle("New Article", "Content here") })], [
      text("Create Article")
    ]),
  ])
}
```

### **Phase 4: Database Integration (Week 4)**

#### **4.1 Database Layer**
```gleam
// server/database.gleam
import gleam/result
import gleam/io
import shared/types

pub type Context = {
  db_connection: String, // Simplified for example
}

pub fn save_article(article: Article, context: Context) -> Result(Nil, String) {
  // Database implementation
  io.println("Saving article: " <> article.title)
  Ok(Nil)
}

pub fn get_articles(limit: Int, offset: Int, context: Context) -> Result(List(Article), String) {
  // Database implementation
  io.println("Getting articles with limit: " <> int.to_string(limit))
  Ok([
    Article(
      id: "1",
      title: "Sample Article",
      content: "This is a sample article",
      created_at: "2024-01-01T00:00:00Z",
    )
  ])
}

pub fn get_article_by_id(id: String, context: Context) -> Result(Option(Article), String) {
  // Database implementation
  io.println("Getting article by id: " <> id)
  Ok(None)
}

pub fn update_article(article: Article, context: Context) -> Result(Nil, String) {
  // Database implementation
  io.println("Updating article: " <> article.title)
  Ok(Nil)
}

pub fn delete_article(id: String, context: Context) -> Result(Nil, String) {
  // Database implementation
  io.println("Deleting article: " <> id)
  Ok(Nil)
}

pub fn get_articles_count(context: Context) -> Result(Int, String) {
  // Database implementation
  Ok(1)
}
```

## Architecture Benefits

### **1. Type Safety Across Stack**
```gleam
// Same types used everywhere
pub type Article = {
  id: String,
  title: String,
  content: String,
  created_at: String,
}

// Backend validates these types
// Frontend uses these types
// Messages contain these types
// Compile-time guarantees everywhere
```

### **2. Real-time by Default**
```gleam
// Every action is real-time
CreateArticle("Title", "Content") 
  → ArticleCreatedEvent 
  → All connected clients updated

UpdateArticle("id", "New Title", "Content")
  → ArticleUpdatedEvent
  → All connected clients updated

DeleteArticle("id")
  → ArticleDeletedEvent
  → All connected clients updated
```

### **3. Simplified API Surface**
```gleam
// No HTTP endpoints to maintain
// No REST conventions to follow
// No status codes to handle
// Just messages and events
```

### **4. Unified Error Handling**
```gleam
// All errors handled the same way
pub type Result(a, b) = {
  Ok(a)
  Error(b)
}

// Backend returns Result
// Frontend handles Result
// Same pattern everywhere
```

## Migration Steps Summary

### **Week 1: Foundation**
1. Set up Gleam backend with Wisp
2. Define shared message types
3. Set up Omnimessage server

### **Week 2: Message Handlers**
1. Implement command handlers (Create, Update, Delete)
2. Implement query handlers (Get, List)
3. Add database integration

### **Week 3: Frontend Migration**
1. Update frontend dependencies
2. Create Omnimessage client
3. Update Lustre application
4. Remove HTTP API calls

### **Week 4: Polish & Deploy**
1. Add error handling
2. Add loading states
3. Test real-time updates
4. Deploy and monitor

## Comparison with Current Architecture

| Aspect | Current (Go + HTTP) | Pure Gleam (Omnimessage) |
|--------|-------------------|-------------------------|
| **Languages** | Go + Gleam | Gleam only |
| **Communication** | HTTP + WebSocket | Omnimessage only |
| **Type Safety** | Partial (JSON) | Full (shared types) |
| **Real-time** | WebSocket only | Everything real-time |
| **API Surface** | REST endpoints | Message handlers |
| **Error Handling** | HTTP status codes | Result types |
| **Deployment** | Two services | One service |
| **Development** | Context switching | Single language |

## Conclusion

A **pure Gleam migration with Omnimessage-only communication** provides:

1. **Single language stack** - Gleam everywhere
2. **Type safety across stack** - Shared types
3. **Real-time by default** - All updates live
4. **Simplified architecture** - No HTTP endpoints
5. **Unified patterns** - Same message handling everywhere

The key insight is that **Omnimessage eliminates the need for HTTP CRUD endpoints entirely** - every interaction becomes a message exchange, creating a truly unified and type-safe architecture.

This approach is particularly well-suited for your situation because:
- You already know Gleam (frontend)
- You want simplicity
- You want real-time updates
- You want type safety

The migration can be done gradually, starting with one resource (articles) and expanding to others, while maintaining the existing Go backend during transition. 