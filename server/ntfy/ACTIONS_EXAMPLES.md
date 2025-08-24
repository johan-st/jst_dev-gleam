# NTFY.SH Actions Examples

This document provides examples of how to use the enhanced ntfy.sh notification system with action support.

## Overview

The system now supports interactive notifications with action buttons that can trigger server-side operations. Actions are sent as HTTP headers to ntfy.sh and can include buttons for approval, denial, or other interactive operations.

## Available Endpoints

- `POST /api/notifications` - Send notifications with actions
- `POST /api/ntfy/webhook` - Receive webhooks from ntfy.sh
- `POST /api/ntfy/action` - Execute actions programmatically

## Action Types

### 1. MFA Approval/Denial

Send a notification requesting MFA approval:

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
      "url": "https://your-domain.com/api/ntfy/action",
      "method": "POST",
      "headers": {
        "Content-Type": "application/json"
      },
      "body": "{\"notification_id\":\"{{id}}\",\"action_id\":\"mfa_approve\",\"user_id\":\"{{user_id}}\",\"token\":\"{{token}}\"}",
      "clear": true
    },
    {
      "id": "mfa_deny",
      "action": "http",
      "label": "❌ Deny",
      "url": "https://your-domain.com/api/ntfy/action",
      "method": "POST",
      "headers": {
        "Content-Type": "application/json"
      },
      "body": "{\"notification_id\":\"{{id}}\",\"action_id\":\"mfa_deny\",\"user_id\":\"{{user_id}}\",\"token\":\"{{token}}\"}",
      "clear": true
    }
  ]
}
```

### 2. Registration Request Approval

Send a notification for user registration approval:

```json
POST /api/notifications
{
  "message": "New user registration request: john.doe@example.com",
  "title": "Registration Request",
  "actions": [
    {
      "id": "registration_approve",
      "action": "http",
      "label": "✅ Approve",
      "url": "https://your-domain.com/api/ntfy/action",
      "method": "POST",
      "headers": {
        "Content-Type": "application/json"
      },
      "body": "{\"notification_id\":\"{{id}}\",\"action_id\":\"registration_approve\",\"user_id\":\"{{user_id}}\",\"token\":\"{{token}}\",\"data\":{\"email\":\"john.doe@example.com\"}}",
      "clear": true
    },
    {
      "id": "registration_deny",
      "action": "http",
      "label": "❌ Deny",
      "url": "https://your-domain.com/api/ntfy/action",
      "method": "POST",
      "headers": {
        "Content-Type": "application/json"
      },
      "body": "{\"notification_id\":\"{{id}}\",\"action_id\":\"registration_deny\",\"user_id\":\"{{user_id}}\",\"token\":\"{{token}}\",\"data\":{\"email\":\"john.doe@example.com\"}}",
      "clear": true
    }
  ]
}
```

### 3. Content Moderation

Send a notification for content moderation:

```json
POST /api/notifications
{
  "message": "New article submitted: 'How to Build APIs'",
  "title": "Content Moderation",
  "actions": [
    {
      "id": "content_approve",
      "action": "http",
      "label": "✅ Publish",
      "url": "https://your-domain.com/api/ntfy/action",
      "method": "POST",
      "headers": {
        "Content-Type": "application/json"
      },
      "body": "{\"notification_id\":\"{{id}}\",\"action_id\":\"content_approve\",\"user_id\":\"{{user_id}}\",\"token\":\"{{token}}\",\"data\":{\"article_id\":\"12345\"}}",
      "clear": true
    },
    {
      "id": "content_reject",
      "action": "http",
      "label": "❌ Reject",
      "url": "https://your-domain.com/api/ntfy/action",
      "method": "POST",
      "headers": {
        "Content-Type": "application/json"
      },
      "body": "{\"notification_id\":\"{{id}}\",\"action_id\":\"content_reject\",\"user_id\":\"{{user_id}}\",\"token\":\"{{token}}\",\"data\":{\"article_id\":\"12345\"}}",
      "clear": true
    },
    {
      "id": "content_review",
      "action": "view",
      "label": "👁️ Review",
      "url": "https://your-domain.com/admin/content/12345"
    }
  ]
}
```

### 4. System Alerts with Actions

Send a system alert with recovery actions:

```json
POST /api/notifications
{
  "message": "Database connection pool at 90% capacity",
  "title": "System Alert",
  "priority": "high",
  "actions": [
    {
      "id": "restart_service",
      "action": "http",
      "label": "🔄 Restart Service",
      "url": "https://your-domain.com/api/ntfy/action",
      "method": "POST",
      "headers": {
        "Content-Type": "application/json"
      },
      "body": "{\"notification_id\":\"{{id}}\",\"action_id\":\"restart_service\",\"user_id\":\"{{user_id}}\",\"token\":\"{{token}}\",\"data\":{\"service\":\"database\"}}",
      "clear": false
    },
    {
      "id": "acknowledge",
      "action": "http",
      "label": "✓ Acknowledge",
      "url": "https://your-domain.com/api/ntfy/action",
      "method": "POST",
      "headers": {
        "Content-Type": "application/json"
      },
      "body": "{\"notification_id\":\"{{id}}\",\"action_id\":\"acknowledge\",\"user_id\":\"{{user_id}}\",\"token\":\"{{token}}\"}",
      "clear": true
    }
  ]
}
```

## Action Configuration

### Action Properties

- `id`: Unique identifier for the action (used in webhooks)
- `action`: Type of action (`view`, `http`, `broadcast`)
- `label`: Button text displayed to the user
- `url`: URL for the action (required for `view` and `http`)
- `method`: HTTP method for `http` actions
- `headers`: HTTP headers for `http` actions
- `body`: Request body for `http` actions
- `clear`: Whether to clear the notification after action

### Action Types

1. **view**: Opens a URL in the user's browser
2. **http**: Makes an HTTP request to your server
3. **broadcast**: Broadcasts to all connected clients (advanced usage)

## Webhook Handling

The system automatically receives webhooks from ntfy.sh for:
- `open`: Notification was opened
- `click`: Notification was clicked
- `action`: Action button was pressed
- `delivery_failure`: Notification failed to deliver

## Security Considerations

1. **Token Validation**: Always validate the token in action requests
2. **User Authorization**: Verify the user has permission to perform the action
3. **Rate Limiting**: Implement rate limiting for action endpoints
4. **Input Validation**: Validate all input data in action handlers

## Implementation Notes

### Adding New Actions

To add new action types, extend the `executeAction` method in `ntfy.go`:

```go
func (n *Ntfy) executeAction(req ActionRequest) (*ActionResponse, error) {
    switch req.ActionID {
    case "mfa_approve":
        return n.handleMFAApprove(req)
    case "mfa_deny":
        return n.handleMFADeny(req)
    case "registration_approve":
        return n.handleRegistrationApprove(req)
    case "registration_deny":
        return n.handleRegistrationDeny(req)
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

### Custom Action Handlers

Implement custom action handlers for your specific use cases:

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

## Testing

### Test Action Endpoint

```bash
curl -X POST https://your-domain.com/api/ntfy/action \
  -H "Content-Type: application/json" \
  -d '{
    "notification_id": "test-123",
    "action_id": "mfa_approve",
    "user_id": "user-456",
    "token": "your-secure-token"
  }'
```

### Test Webhook Endpoint

```bash
curl -X POST https://your-domain.com/api/ntfy/webhook \
  -H "Content-Type: application/json" \
  -d '{
    "id": "test-123",
    "event": "action",
    "topic": "test-topic",
    "actions": [{"id": "mfa_approve", "action": "http", "label": "Approve"}]
  }'
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