# Minimal Articles Integration with WebSocket

This document describes the minimal changes made to hook up the WebSocket stream to the articles.

## Overview

The integration is minimal and leverages the fact that KV subscriptions automatically catch up the client with current key values, after which only updates are sent.

## Changes Made

### 1. Added Article Cache to Main Model

```gleam
type Model {
  // ... existing fields ...
  
  // Article cache from WebSocket KV stream
  article_cache: Dict(String, realtime.ArticleResponse),
}
```

### 2. Initialize Article Cache

```gleam
// In init function
article_cache: dict.new(),
```

### 3. Subscribe to Article KV Stream

```gleam
// Automatically subscribe to article changes on startup
let subscribe_article_kv =
  effect.from(fn(dispatch) {
    dispatch(RealtimeMsg(realtime.kv_subscribe("article")))
  })
```

### 4. Helper Functions

```gleam
// Convert cached articles to view format
fn get_articles_from_cache(model: Model) -> List(Article)
fn convert_article_response_to_article(article_response: realtime.ArticleResponse) -> Article
fn get_article_from_cache_by_slug(model: Model, slug: String) -> Option(Article)
```

### 5. Updated Page Resolution

The `page_from_model` function now checks the cache first:

- **Articles Route**: Use cached articles if available, fall back to HTTP API
- **Article Route**: Use cached article if available, fall back to HTTP API

## How It Works

1. **Automatic Catch-up**: KV subscription automatically sends all current article values
2. **Real-time Updates**: Subsequent changes (create/update/delete) are sent as they happen
3. **Cache Priority**: Views use cached data when available
4. **Fallback**: HTTP API is used when cache is empty

## Benefits

- **Minimal Code**: Only essential changes needed
- **Automatic**: KV subscription handles catch-up automatically
- **Real-time**: Updates appear instantly
- **Fallback**: HTTP API ensures compatibility

## No Changes Needed

- **Go Backend**: No changes required
- **WebSocket Protocol**: Uses existing KV subscription mechanism
- **Article Operations**: Existing create/update/delete operations work unchanged

## Conclusion

This minimal integration provides real-time article updates with very little code change, leveraging the existing WebSocket infrastructure and KV subscription capabilities.
