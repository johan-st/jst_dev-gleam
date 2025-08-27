# Web Package

This package contains the HTTP server and routing logic for the application.

## Structure

- `routes.go` - Main routing configuration and HTTP handlers
- `act.go` - Action handling logic for ntfy.sh interactive notifications
- `socket.go` - WebSocket handling for real-time communication
- `web.go` - Web server setup and configuration

## Action System

The action system is implemented in `act.go` and provides a simple endpoint for handling ntfy.sh action buttons:

```
GET /api/act/{action_id}?nid={notification_id}&uid={user_id}&token={token}&{additional_data}
```

### How It Works

1. **ntfy.sh sends notification** with action buttons
2. **User taps action button** → ntfy.sh makes HTTP request to `/api/act/{action_id}`
3. **Server processes action** → Routes to appropriate action handler via NATS
4. **User sees result** → Simple HTML page shows success/failure

### Example Usage

```json
POST /api/notifications
{
  "message": "New login attempt detected. Please approve or deny.",
  "title": "MFA Request",
  "actions": [
    {
      "id": "mfa_approve",
      "action": "http",
      "label": "✅ Approve",
      "url": "https://your-domain.com/api/act/mfa_approve?nid={{id}}&uid={{user_id}}&token={{token}}",
      "method": "GET",
      "clear": true
    }
  ]
}
```

### Available Actions

- `mfa_approve` - Approve MFA request
- `mfa_deny` - Deny MFA request
- `registration_approve` - Approve user registration
- `registration_deny` - Deny user registration

### Adding New Actions

1. **Extend the action handler** in `server/ntfy/ntfy.go`
2. **Implement the handler** function
3. **The web endpoint automatically routes** to the correct handler

## Routes

The main routes are defined in `routes.go`:

- `POST /api/notifications` - Send notifications with actions
- `GET /api/act/{action_id}` - Execute actions
- `GET /api/article/*` - Article management
- `POST /api/auth/*` - Authentication
- `GET /api/users/*` - User management
- `GET /api/url/*` - URL shortening
- `GET /ws` - WebSocket endpoint

## Dependencies

- NATS for inter-service communication
- JWT for authentication
- WebSocket for real-time features