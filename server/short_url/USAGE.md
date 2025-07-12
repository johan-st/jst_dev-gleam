# Short URL Service Usage Guide

The short URL service is now integrated into the web server and provides RESTful endpoints for managing short URLs.

## RESTful Endpoints

### Create Short URL
```http
POST /api/shorturls
Content-Type: application/json

{
  "shortCode": "my-link",
  "targetUrl": "https://example.com/very-long-url"
}
```

**Response:**
```json
{
  "id": "uuid",
  "shortCode": "my-link",
  "targetUrl": "https://example.com/very-long-url",
  "createdBy": "user-id",
  "createdAt": "2024-01-01T00:00:00Z",
  "updatedAt": "2024-01-01T00:00:00Z",
  "accessCount": 0,
  "isActive": true
}
```

### List Short URLs
```http
GET /api/shorturls?limit=10&offset=0&createdBy=user-id
```

**Response:**
```json
{
  "shortUrls": [...],
  "total": 25,
  "limit": 10,
  "offset": 0
}
```

### Get Short URL
```http
GET /api/shorturls/{id}
```

### Update Short URL
```http
PUT /api/shorturls/{id}
Content-Type: application/json

{
  "shortCode": "new-code",
  "targetUrl": "https://new-url.com",
  "isActive": false
}
```

### Delete Short URL
```http
DELETE /api/shorturls/{id}
```

### Redirect (Public)
```http
GET /s/{shortCode}
```

This will redirect to the target URL and increment the access count.

## Authentication

All endpoints except the redirect endpoint (`/s/{shortCode}`) require authentication. The service uses JWT tokens from cookies set by the auth service.

## Examples

### Create a short URL
```bash
curl -X POST http://localhost:8080/api/shorturls \
  -H "Content-Type: application/json" \
  -H "Cookie: jst_dev_who=your-jwt-token" \
  -d '{
    "shortCode": "docs",
    "targetUrl": "https://docs.example.com"
  }'
```

### Access a short URL
```bash
curl -L http://localhost:8080/s/docs
```

### List your short URLs
```bash
curl http://localhost:8080/api/shorturls \
  -H "Cookie: jst_dev_who=your-jwt-token"
```

## Features

- ✅ Create, read, update, delete short URLs
- ✅ Track access counts
- ✅ Case-insensitive short codes
- ✅ Pagination support
- ✅ User-based filtering
- ✅ Active/inactive status
- ✅ Automatic redirects
- ✅ NATS-based persistence
- ✅ Real-time updates

## Error Handling

The service returns appropriate HTTP status codes:

- `200` - Success
- `201` - Created
- `400` - Bad Request (validation errors)
- `401` - Unauthorized
- `404` - Not Found
- `409` - Conflict (short code already exists)
- `410` - Gone (inactive short URL)
- `500` - Internal Server Error 