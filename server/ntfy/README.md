# NTFY.SH Integration

This package provides integration with [ntfy.sh](https://ntfy.sh) for sending push notifications with action support.

## Features

- Send notifications via ntfy.sh
- Support for notification actions (buttons)
- Webhook handling for action events
- NATS-based service architecture
- Configurable priority levels
- Action execution with security tokens

## Configuration

### Environment Variables

```bash
# ntfy.sh server (defaults to https://ntfy.sh)
NTFY_SERVER=https://ntfy.sh

# Optional authentication token
NTFY_TOKEN=your_ntfy_token
```

### Server Configuration

The ntfy service is automatically started with the main server and provides:

- NATS microservice endpoints
- HTTP webhook handling
- Action execution

## API Endpoints

### 1. Send Notification with Actions

```http
POST /api/notifications
Content-Type: application/json

{
  "message": "New login attempt detected. Please approve or deny.",
  "title": "MFA Request",
  "actions": [
    {
      "id": "mfa_approve",
      "action": "http",
      "label": "✅ Approve",
      "url": "https://your-domain.com/api/ntfy/action",
      "method": "POST",
      "headers": {
        "Content-Type": "application/json"
      },
      "body": "{\"notification_id\":\"{{id}}\",\"action_id\":\"mfa_approve\",\"user_id\":\"{{user_id}}\",\"token\":\"{{token}}\"}",
      "clear": true
    }
  ]
}
```

### 2. Webhook Endpoint

```http
POST /api/ntfy/webhook
Content-Type: application/json

{
  "id": "notification-id",
  "event": "action",
  "topic": "your-topic",
  "actions": [...]
}
```

### 3. Action Execution

```http
POST /api/ntfy/action
Content-Type: application/json

{
  "notification_id": "notification-id",
  "action_id": "mfa_approve",
  "user_id": "user-id",
  "token": "security-token",
  "data": {
    "additional": "data"
  }
}
```

## Action Types

### Built-in Actions

- `mfa_approve` - Approve MFA request
- `mfa_deny` - Deny MFA request
- `registration_approve` - Approve user registration
- `registration_deny` - Deny user registration

### Action Properties

- `id`: Unique action identifier
- `action`: Action type (`view`, `http`, `broadcast`)
- `label`: Button text
- `url`: Action URL (for `view` and `http`)
- `method`: HTTP method (for `http`)
- `headers`: HTTP headers (for `http`)
- `body`: Request body (for `http`)
- `clear`: Clear notification after action

## Usage Examples

### MFA Approval Flow

1. **Send notification with actions:**
```go
notification := ntfy.Notification{
    ID:        "mfa-123",
    UserID:    "user-456",
    Title:     "MFA Request",
    Message:   "New login attempt detected",
    Actions: []ntfy.Action{
        {
            ID:      "mfa_approve",
            Action:  "http",
            Label:   "✅ Approve",
            URL:     "https://your-domain.com/api/ntfy/action",
            Method:  "POST",
            Headers: map[string]string{"Content-Type": "application/json"},
            Body:    `{"notification_id":"{{id}}","action_id":"mfa_approve","user_id":"{{user_id}}","token":"{{token}}"}`,
            Clear:   true,
        },
        {
            ID:      "mfa_deny",
            Action:  "http",
            Label:   "❌ Deny",
            URL:     "https://your-domain.com/api/ntfy/action",
            Method:  "POST",
            Headers: map[string]string{"Content-Type": "application/json"},
            Body:    `{"notification_id":"{{id}}","action_id":"mfa_deny","user_id":"{{user_id}}","token":"{{token}}"}`,
            Clear:   true,
        },
    },
}
```

2. **Handle action execution:**
```go
// The action will be automatically routed to handleMFAApprove or handleMFADeny
// based on the action_id in the request
```

### Registration Approval Flow

1. **Send notification:**
```go
notification := ntfy.Notification{
    ID:        "reg-789",
    UserID:    "admin-123",
    Title:     "Registration Request",
    Message:   "New user: john.doe@example.com",
    Actions: []ntfy.Action{
        {
            ID:      "registration_approve",
            Action:  "http",
            Label:   "✅ Approve",
            URL:     "https://your-domain.com/api/ntfy/action",
            Method:  "POST",
            Headers: map[string]string{"Content-Type": "application/json"},
            Body:    `{"notification_id":"{{id}}","action_id":"registration_approve","user_id":"{{user_id}}","token":"{{token}}","data":{"email":"john.doe@example.com"}}`,
            Clear:   true,
        },
        {
            ID:      "registration_deny",
            Action:  "http",
            Label:   "❌ Deny",
            URL:     "https://your-domain.com/api/ntfy/action",
            Method:  "POST",
            Headers: map[string]string{"Content-Type": "application/json"},
            Body:    `{"notification_id":"{{id}}","action_id":"registration_deny","user_id":"{{user_id}}","token":"{{token}}","data":{"email":"john.doe@example.com"}}`,
            Clear:   true,
        },
    },
}
```

## Security

### Token Validation

All action requests must include a valid token:

```json
{
  "notification_id": "notification-id",
  "action_id": "action-id",
  "user_id": "user-id",
  "token": "your-secure-token"
}
```

### User Authorization

The system validates that the user has permission to perform the requested action.

## Testing

Use the provided test script to verify functionality:

```bash
./test_actions.sh
```

Make sure to update the `BASE_URL` variable in the script to match your server.

## Webhook Configuration

To receive webhooks from ntfy.sh:

1. **Enable webhooks in your ntfy.sh topic:**
```bash
# Subscribe to topic with webhooks enabled
ntfy subscribe your-topic --webhook https://your-domain.com/api/ntfy/webhook
```

2. **Webhook events received:**
- `open`: Notification opened
- `click`: Notification clicked
- `action`: Action button pressed
- `delivery_failure`: Delivery failed

## Extending Actions

### Add New Action Types

1. **Extend the action handler:**
```go
func (n *Ntfy) executeAction(req ActionRequest) (*ActionResponse, error) {
    switch req.ActionID {
    case "mfa_approve":
        return n.handleMFAApprove(req)
    case "your_new_action":
        return n.handleYourNewAction(req)
    default:
        return &ActionResponse{
            Success: false,
            Message: fmt.Sprintf("unknown action: %s", req.ActionID),
        }, nil
    }
}
```

2. **Implement the handler:**
```go
func (n *Ntfy) handleYourNewAction(req ActionRequest) (*ActionResponse, error) {
    // Your custom logic here
    return &ActionResponse{
        Success: true,
        Message: "Action completed successfully",
        Data: map[string]interface{}{
            "action": "your_new_action",
            "user_id": req.UserID,
            "timestamp": time.Now().Unix(),
        },
    }, nil
}
```

## Troubleshooting

### Common Issues

1. **Actions not appearing**: Check that the `Actions` header is properly formatted JSON
2. **Webhooks not received**: Verify your ntfy.sh topic has webhooks enabled
3. **Action execution fails**: Check the server logs for detailed error messages
4. **Token validation fails**: Ensure the token in the action request matches your expected format

### Debug Mode

Enable debug logging to see detailed information about action processing:

```go
logger := l.WithBreadcrumb("handleNtfyAction")
logger.Debug("processing action", "request", req)
```

## Best Practices

1. **Use descriptive action IDs**: Make action IDs meaningful and consistent
2. **Implement proper error handling**: Always handle errors gracefully
3. **Log all actions**: Maintain audit trails for security and debugging
4. **Use appropriate priorities**: Set notification priority based on urgency
5. **Clear notifications appropriately**: Use the `clear` flag to manage notification lifecycle
6. **Validate all inputs**: Never trust data from external sources
7. **Implement rate limiting**: Prevent abuse of action endpoints
8. **Use secure tokens**: Implement proper authentication for action execution

## Examples

See `ACTIONS_EXAMPLES.md` for comprehensive examples of different use cases and configurations. 