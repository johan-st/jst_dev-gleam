# WebSocket Articles API

This document describes the WebSocket-based Articles API that replaces the traditional HTTP endpoints for article operations. The WebSocket API provides real-time capabilities and eliminates the need for polling.

## Overview

The WebSocket Articles API provides the following operations:
- **List Articles** - Get all articles (metadata only)
- **Get Article** - Retrieve a specific article by ID
- **Create Article** - Create a new article
- **Update Article** - Update an existing article
- **Delete Article** - Delete an article
- **Article History** - Get revision history for an article
- **Real-time Updates** - Subscribe to article changes via KV watchers

## Connection

Connect to the WebSocket endpoint:
```
ws://localhost:8080/ws
```

## Message Format

All messages use the unified envelope format:

```json
{
  "op": "operation_name",
  "target": "target_identifier",
  "data": { /* operation-specific data */ },
  "inbox": "correlation_id"
}
```

Responses use the same format with `op: "reply"` and the corresponding `inbox`.

## Operations

### 1. List Articles

**Request:**
```json
{
  "op": "article_list",
  "target": "",
  "data": {},
  "inbox": "list_articles_1"
}
```

**Response:**
```json
{
  "op": "reply",
  "inbox": "list_articles_1",
  "data": {
    "articles": [
      {
        "id": "uuid-string",
        "slug": "article-slug",
        "title": "Article Title",
        "subtitle": "Article Subtitle",
        "leading": "Leading paragraph...",
        "author": "user_id",
        "published_at": 1640995200,
        "tags": ["tag1", "tag2"],
        "revision": 1,
        "struct_version": 1
      }
    ]
  }
}
```

### 2. Get Article

**Request:**
```json
{
  "op": "article_get",
  "target": "",
  "data": {
    "id": "uuid-string"
  },
  "inbox": "get_article_1"
}
```

**Response:**
```json
{
  "op": "reply",
  "inbox": "get_article_1",
  "data": {
    "id": "uuid-string",
    "slug": "article-slug",
    "title": "Article Title",
    "subtitle": "Article Subtitle",
    "leading": "Leading paragraph...",
    "author": "user_id",
    "published_at": 1640995200,
    "tags": ["tag1", "tag2"],
    "content": "Full article content...",
    "revision": 1,
    "struct_version": 1
  }
}
```

### 3. Create Article

**Request:**
```json
{
  "op": "article_create",
  "target": "",
  "data": {
    "title": "New Article Title",
    "subtitle": "Article Subtitle",
    "leading": "Leading paragraph...",
    "content": "Article content...",
    "tags": ["new", "article"],
    "published_at": 1640995200
  },
  "inbox": "create_article_1"
}
```

**Response:**
```json
{
  "op": "reply",
  "inbox": "create_article_1",
  "data": {
    "id": "generated-uuid",
    "slug": "generated-uuid",
    "title": "New Article Title",
    "subtitle": "Article Subtitle",
    "leading": "Leading paragraph...",
    "author": "current_user_id",
    "published_at": 1640995200,
    "tags": ["new", "article"],
    "content": "Article content...",
    "revision": 1,
    "struct_version": 1
  }
}
```

### 4. Update Article

**Request:**
```json
{
  "op": "article_update",
  "target": "",
  "data": {
    "id": "uuid-string",
    "data": {
      "title": "Updated Title",
      "content": "Updated content..."
    }
  },
  "inbox": "update_article_1"
}
```

**Response:**
```json
{
  "op": "reply",
  "inbox": "update_article_1",
  "data": {
    "id": "uuid-string",
    "slug": "article-slug",
    "title": "Updated Title",
    "subtitle": "Article Subtitle",
    "leading": "Leading paragraph...",
    "author": "user_id",
    "published_at": 1640995200,
    "tags": ["tag1", "tag2"],
    "content": "Updated content...",
    "revision": 2,
    "struct_version": 1
  }
}
```

### 5. Delete Article

**Request:**
```json
{
  "op": "article_delete",
  "target": "",
  "data": {
    "id": "uuid-string"
  },
  "inbox": "delete_article_1"
}
```

**Response:**
```json
{
  "op": "reply",
  "inbox": "delete_article_1",
  "data": {
    "status": "deleted"
  }
}
```

### 6. Article History

**Request:**
```json
{
  "op": "article_history",
  "target": "",
  "data": {
    "id": "uuid-string"
  },
  "inbox": "history_1"
}
```

**Response:**
```json
{
  "op": "reply",
  "inbox": "history_1",
  "data": {
    "revisions": [
      {
        "id": "uuid-string",
        "slug": "article-slug",
        "title": "Article Title",
        "subtitle": "Article Subtitle",
        "leading": "Leading paragraph...",
        "author": "user_id",
        "published_at": 1640995200,
        "tags": ["tag1", "tag2"],
        "content": "Article content...",
        "revision": 2,
        "struct_version": 1
      },
      {
        "id": "uuid-string",
        "slug": "article-slug",
        "title": "Original Title",
        "subtitle": "Article Subtitle",
        "leading": "Leading paragraph...",
        "author": "user_id",
        "published_at": 1640995200,
        "tags": ["tag1", "tag2"],
        "content": "Original content...",
        "revision": 1,
        "struct_version": 1
      }
    ]
  }
}
```

### 7. Get Specific Revision

**Request:**
```json
{
  "op": "article_revision",
  "target": "",
  "data": {
    "id": "uuid-string",
    "revision": 1
  },
  "inbox": "revision_1"
}
```

**Response:**
```json
{
  "op": "reply",
  "inbox": "revision_1",
  "data": {
    "id": "uuid-string",
    "slug": "article-slug",
    "title": "Original Title",
    "subtitle": "Article Subtitle",
    "leading": "Leading paragraph...",
    "author": "user_id",
    "published_at": 1640995200,
    "tags": ["tag1", "tag2"],
    "content": "Original content...",
    "revision": 1,
    "struct_version": 1
  }
}
```

## Real-time Updates

Subscribe to article changes to receive real-time notifications:

**Subscribe:**
```json
{
  "op": "kv_sub",
  "target": "article",
  "data": {
    "pattern": ">"
  }
}
```

**Real-time Update Messages:**
```json
{
  "op": "msg",
  "target": "article",
  "data": {
    "key": "article-uuid",
    "value": "article-json",
    "rev": 2,
    "op": "put"
  }
}
```

Operations: `put`, `delete`, `purge`

## Error Handling

All operations return error responses in the same format:

```json
{
  "op": "reply",
  "inbox": "request_inbox",
  "data": {
    "error": "Error description"
  }
}
```

Common errors:
- `insufficient permissions` - User lacks required capabilities
- `article not found` - Article ID doesn't exist
- `failed to access article bucket` - KV store unavailable
- `failed to parse article` - Invalid article data

## Capabilities

The following capabilities are required for article operations:

```json
{
  "subjects": ["time.>"],
  "buckets": {
    "article": [">"]
  },
  "commands": [
    "article_list",
    "article_get", 
    "article_create",
    "article_update",
    "article_delete",
    "article_history",
    "article_revision"
  ],
  "streams": {}
}
```

## Migration from HTTP

The WebSocket API replaces these HTTP endpoints:

| HTTP Endpoint | WebSocket Operation |
|---------------|-------------------|
| `GET /api/articles` | `article_list` |
| `GET /api/articles/{id}` | `article_get` |
| `POST /api/articles` | `article_create` |
| `PUT /api/articles/{id}` | `article_update` |
| `DELETE /api/articles/{id}` | `article_delete` |
| `GET /api/articles/{id}/revisions` | `article_history` |
| `GET /api/articles/{id}/revisions/{revision}` | `article_revision` |

## Benefits

1. **Real-time Updates**: Subscribe to article changes and receive instant notifications
2. **Single Connection**: All operations use one WebSocket connection
3. **Reduced Latency**: No HTTP overhead for each request
4. **Better UX**: Real-time updates improve user experience
5. **Efficient**: Batch operations and real-time subscriptions reduce server load

## Example Usage

See `websocket-articles-example.html` for a complete working example that demonstrates all operations.

## Security

- All operations require proper authentication via JWT
- Capability-based access control ensures users can only access permitted operations
- Real-time subscriptions respect user permissions
- Input validation and sanitization on all operations