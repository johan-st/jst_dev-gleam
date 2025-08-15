# WebSocket Articles Integration with Article Repository

This document describes the integration of the WebSocket Articles API with the article repository, making it the single source of truth for article operations.

## Overview

The WebSocket Articles API has been successfully integrated with the article repository (`articles.ArticleRepo`) instead of using direct JetStream KV operations. This ensures:

1. **Consistent Data Model**: All article operations use the same `Article` struct
2. **Centralized Business Logic**: Article operations go through the repository layer
3. **Real-time Updates**: WebSocket clients can subscribe to article changes via the repository's `WatchAll()` method
4. **Proper Error Handling**: Repository-level error handling and validation

## Changes Made

### 1. Updated WebSocket Server Structure

- Modified `server` struct to include `articleRepo articles.ArticleRepo`
- Updated `rtClient` struct to include `articleRepo articles.ArticleRepo`
- Modified `HandleRealtimeWebSocket` function to accept and pass the article repository

### 2. Replaced Direct JetStream Operations

All article handlers now use the article repository instead of direct JetStream KV operations:

- **`handleArticleList`**: Uses `repo.AllNoContent()` instead of manual KV iteration
- **`handleArticleGet`**: Uses `repo.Get(id)` instead of direct KV get
- **`handleArticleCreate`**: Uses `repo.Create(article)` instead of manual KV create
- **`handleArticleUpdate`**: Uses `repo.Update(article)` instead of manual KV update
- **`handleArticleDelete`**: Uses `repo.Delete(id)` instead of direct KV delete
- **`handleArticleRevision`**: Uses `repo.GetHistory(id)` and `repo.GetRevision(id, rev)` instead of manual KV history

### 3. Enhanced Real-time Updates

- Added `handleArticleKVSub` function for article-specific real-time subscriptions
- Uses `repo.WatchAll()` to monitor article changes
- Provides structured article data in real-time update messages
- Supports pattern-based filtering for article subscriptions

### 4. Type Safety Improvements

- Updated `kvWatchers` map to handle both `nats.KeyWatcher` and `jetstream.KeyWatcher` types
- Added proper type assertions for watcher operations
- Ensured compatibility between different watcher implementations

## API Usage

### Real-time Article Subscriptions

Clients can subscribe to article changes using:

```json
{
  "op": "kv_sub",
  "target": "article",
  "data": {
    "pattern": ">"
  }
}
```

This will:
1. Use the article repository's `WatchAll()` method
2. Provide real-time updates for all article operations (create, update, delete)
3. Include structured article data in update messages

### Article Operations

All article operations now go through the repository:

- **List Articles**: `article_list` → `repo.AllNoContent()`
- **Get Article**: `article_get` → `repo.Get(id)`
- **Create Article**: `article_create` → `repo.Create(article)`
- **Update Article**: `article_update` → `repo.Update(article)`
- **Delete Article**: `article_delete` → `repo.Delete(id)`
- **Article History**: `article_history` → `repo.GetHistory(id)`
- **Specific Revision**: `article_revision` → `repo.GetRevision(id, rev)`

## Benefits

### 1. **Data Consistency**
- All article operations use the same data model
- Repository ensures proper validation and business logic
- Consistent error handling across all operations

### 2. **Real-time Synchronization**
- WebSocket clients receive instant updates when articles change
- Updates include full article data, not just keys
- Pattern-based filtering for targeted subscriptions

### 3. **Maintainability**
- Single source of truth for article operations
- Easier to add new features or modify existing behavior
- Centralized logging and error handling

### 4. **Performance**
- Repository can implement caching if needed
- Efficient batch operations for article listing
- Optimized database queries through the repository layer

## Testing

A test script has been created at `test_websocket_articles.go` that verifies:

1. Article repository creation and basic operations
2. WebSocket article handlers integration
3. Real-time update functionality via `WatchAll()`
4. Article lifecycle (create, read, update, delete, history)

To run the test:

```bash
cd server/web
go run test_websocket_articles.go
```

## Example WebSocket Client Usage

```javascript
// Connect to WebSocket
const ws = new WebSocket('ws://localhost:8080/ws');

// Subscribe to article changes
ws.send(JSON.stringify({
  op: 'kv_sub',
  target: 'article',
  data: { pattern: '>' }
}));

// Listen for real-time updates
ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  if (msg.op === 'msg' && msg.target === 'article') {
    console.log('Article update:', msg.data);
    // Handle article change (create, update, delete)
  }
};

// Create an article
ws.send(JSON.stringify({
  op: 'article_create',
  target: '',
  data: {
    title: 'New Article',
    subtitle: 'Article Subtitle',
    leading: 'Leading paragraph...',
    content: 'Article content...',
    tags: ['new', 'article'],
    published_at: Date.now()
  },
  inbox: 'create_1'
}));
```

## Migration Notes

### From Direct JetStream Operations

The integration maintains backward compatibility while providing these improvements:

- **Same WebSocket API**: No changes needed for existing clients
- **Enhanced Real-time Updates**: Better structured data in update messages
- **Improved Error Handling**: More descriptive error messages from repository
- **Better Performance**: Repository can optimize operations

### From HTTP API

The WebSocket API now provides the same functionality as the HTTP endpoints but with real-time capabilities:

| HTTP Endpoint | WebSocket Operation | Repository Method |
|---------------|-------------------|------------------|
| `GET /api/articles` | `article_list` | `repo.AllNoContent()` |
| `GET /api/articles/{id}` | `article_get` | `repo.Get(id)` |
| `POST /api/articles` | `article_create` | `repo.Create(article)` |
| `PUT /api/articles/{id}` | `article_update` | `repo.Update(article)` |
| `DELETE /api/articles/{id}` | `article_delete` | `repo.Delete(id)` |
| `GET /api/articles/{id}/revisions` | `article_history` | `repo.GetHistory(id)` |
| `GET /api/articles/{id}/revisions/{revision}` | `article_revision` | `repo.GetRevision(id, rev)` |

## Future Enhancements

1. **Caching Layer**: Add in-memory caching for frequently accessed articles
2. **Batch Operations**: Support for bulk article operations
3. **Advanced Filtering**: Pattern-based article queries
4. **Audit Trail**: Enhanced logging for article operations
5. **Search Integration**: Full-text search capabilities

## Conclusion

The WebSocket Articles API is now fully integrated with the article repository, providing a robust, real-time solution for article management. The integration ensures data consistency, improves maintainability, and provides enhanced real-time capabilities while maintaining backward compatibility.
