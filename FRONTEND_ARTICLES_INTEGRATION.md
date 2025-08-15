# Frontend Articles Integration with WebSocket

This document describes the frontend integration that uses the existing WebSocket subscription to load articles and store them as the source of truth for both the article list view and individual article view.

## Overview

The frontend has been updated to:

1. **Subscribe to Article Changes**: Use the existing WebSocket subscription to the "article" KV bucket
2. **Store Articles in Cache**: Maintain a dictionary of current articles in the main model
3. **Use Cache as Source of Truth**: Prioritize cached articles over HTTP API responses
4. **Real-time Updates**: Automatically update the UI when articles change via WebSocket

## Changes Made

### 1. Updated Main Model

Added `article_cache` field to store articles from WebSocket:

```gleam
type Model {
  // ... existing fields ...
  
  // Article cache from WebSocket
  article_cache: Dict(String, realtime.ArticleResponse),
}
```

### 2. New Message Types

Added new message types for handling article operations:

```gleam
// WebSocket Article Operations
ArticleListRequested
ArticleListReceived(List(realtime.ArticleResponse))
ArticleCacheUpdated(String, realtime.ArticleResponse) // id, article
ArticleCacheDeleted(String) // id
```

### 3. Enhanced Realtime Message Handling

Updated the `RealtimeMsg` handler to:

- Convert realtime article messages to main model messages
- Handle article list responses, updates, and deletions
- Maintain the article cache in real-time

### 4. Helper Functions

Added helper functions to work with the article cache:

```gleam
// Convert cached articles to the format expected by views
fn get_articles_from_cache(model: Model) -> List(Article)
fn convert_article_response_to_article(article_response: realtime.ArticleResponse) -> Article
fn get_article_from_cache_by_slug(model: Model, slug: String) -> Option(Article)
```

### 5. Updated Page Resolution

Modified `page_from_model` to prioritize cached articles:

- **Articles Route**: Use cached articles if available, fall back to HTTP API
- **Article Route**: Use cached article if available, fall back to HTTP API

### 6. Enhanced Realtime Module

Updated the realtime module to:

- Handle article list responses with proper inbox tracking
- Parse article update messages from WebSocket
- Dispatch appropriate messages for article operations

## How It Works

### 1. Initial Load

1. On app startup, the WebSocket connects and subscribes to the "article" KV bucket
2. An article list request is sent via WebSocket
3. The response populates the `article_cache` dictionary
4. Views use the cached articles instead of making HTTP requests

### 2. Real-time Updates

1. When articles change (create/update/delete), the WebSocket receives updates
2. Updates are parsed and converted to main model messages
3. The article cache is updated accordingly
4. UI automatically reflects the changes

### 3. Fallback to HTTP API

If the article cache is empty or doesn't contain the requested article:
1. The system falls back to the existing HTTP API
2. This ensures backward compatibility and handles edge cases

## Benefits

### 1. **Real-time Updates**
- Articles appear instantly when created/updated/deleted
- No need to refresh the page to see changes
- Consistent with the real-time nature of the application

### 2. **Performance**
- Articles load from memory instead of HTTP requests
- Faster page navigation and article display
- Reduced server load

### 3. **Consistency**
- Single source of truth for article data
- All views use the same data
- No synchronization issues between different data sources

### 4. **User Experience**
- Instant feedback when articles change
- Smooth navigation between articles
- No loading states for cached articles

## API Usage

### WebSocket Subscription

The frontend automatically subscribes to article changes:

```gleam
// Subscribe to article KV bucket
dispatch(RealtimeMsg(realtime.kv_subscribe("article")))

// Request article list
dispatch(RealtimeMsg(realtime.article_list()))
```

### Article Cache Access

Views can access articles from the cache:

```gleam
// Get all articles
let articles = get_articles_from_cache(model)

// Get specific article by slug
case get_article_from_cache_by_slug(model, slug) {
  Some(article) -> // Use cached article
  None -> // Fall back to HTTP API
}
```

## Data Flow

```
WebSocket → realtime module → main model → views
    ↓              ↓            ↓         ↓
article updates → parse → cache → display
```

## Error Handling

- WebSocket connection failures fall back to HTTP API
- Invalid article data is logged and ignored
- Cache misses trigger HTTP API requests
- Graceful degradation ensures the app remains functional

## Future Enhancements

1. **Offline Support**: Cache articles in localStorage for offline viewing
2. **Optimistic Updates**: Update UI immediately, then sync with server
3. **Conflict Resolution**: Handle concurrent edits with proper conflict resolution
4. **Batch Operations**: Support for bulk article operations
5. **Search Integration**: Add full-text search capabilities to cached articles

## Testing

The integration can be tested by:

1. Starting the server with WebSocket support
2. Opening the frontend in a browser
3. Creating/updating/deleting articles via the WebSocket API
4. Observing real-time updates in the UI

## Conclusion

The frontend now successfully uses the WebSocket subscription as the primary source of truth for articles, providing real-time updates and improved performance while maintaining backward compatibility with the HTTP API. The integration ensures that both the article list view and individual article views are always up-to-date with the latest data from the server.
