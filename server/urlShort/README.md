# Short URL Service

A microservice for managing short URLs using NATS JetStream for persistence and NATS Micro for service communication.

## Features

- Create, read, update, delete short URLs
- Track access counts
- Case-insensitive short code lookup
- Pagination support for listing
- NATS KV store persistence
- Real-time updates via NATS watchers

## API Endpoints

The service exposes the following NATS Micro endpoints:

### Create Short URL
- **Subject**: `svc.shorturl.urls.create`
- **Request**: `ShortUrlCreateRequest`
- **Response**: `ShortUrl`

### Get Short URL
- **Subject**: `svc.shorturl.urls.get`
- **Request**: `ShortUrlGetRequest` (ID or ShortCode)
- **Response**: `ShortUrl`

### Update Short URL
- **Subject**: `svc.shorturl.urls.update`
- **Request**: `ShortUrlUpdateRequest`
- **Response**: `ShortUrl`

### Delete Short URL
- **Subject**: `svc.shorturl.urls.delete`
- **Request**: `ShortUrlDeleteRequest`
- **Response**: `ShortUrlDeleteResponse`

### List Short URLs
- **Subject**: `svc.shorturl.urls.list`
- **Request**: `ShortUrlListRequest`
- **Response**: `ShortUrlListResponse`

## Usage

```go
import (
    "context"
    "jst_dev/server/jst_log"
    "jst_dev/server/short_url"
    "github.com/nats-io/nats.go"
)

// Create service
nc, _ := nats.Connect(nats.DefaultURL)
logger := &jst_log.Logger{}
ctx := context.Background()

conf := &shorturl.Conf{
    NatsConn: nc,
    Logger:   logger,
}

service, err := shorturl.New(ctx, conf)
if err != nil {
    log.Fatal(err)
}

// Start service
err = service.Start(ctx)
if err != nil {
    log.Fatal(err)
}
```

## Data Model

```go
type ShortUrl struct {
    ID          string `json:"id"`
    ShortCode   string `json:"shortCode"`
    TargetURL   string `json:"targetUrl"`
    CreatedBy   string `json:"createdBy"`
    CreatedAt   int64  `json:"createdAt"`   // Unix seconds
    UpdatedAt   int64  `json:"updatedAt"`   // Unix seconds
    AccessCount int64  `json:"accessCount"`
    IsActive    bool   `json:"isActive"`
}
```

## Testing

Run tests with:
```bash
go test -v ./urlShort
```

Tests require a NATS server running on the default URL (`nats://localhost:4222`).

## Storage

The service uses NATS JetStream Key-Value store with:
- Bucket: `url_short`
- Storage: File-based
- Max value size: 1KB
- Max bucket size: 50MB
- History: 1 entries
- Compression: disabled

## TODO

- when responding and redirecting we should rely on the local shortCodes and urls to maintaion speed. We should also post a message (access log) to a topic (which is read at most once) and the reader should update the access count in the KV.
  