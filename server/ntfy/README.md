# NTFY.SH Actions - Simplified

A simple action system for ntfy.sh notifications that uses a single endpoint for all actions.

## How It Works

1. **Send notification with actions** - Include action buttons in your ntfy.sh notifications
2. **User taps action** - ntfy.sh makes an HTTP request to your server
3. **Server processes action** - Your server handles the action and returns a response
4. **User sees result** - Simple HTML page shows success/failure

## Single Endpoint

```
GET /api/act/{action_id}?nid={notification_id}&uid={user_id}&token={token}&{additional_data}
```

### Parameters

- `{action_id}` - The action to execute (e.g., `mfa_approve`, `registration_deny`)
- `nid` - Notification ID (required)
- `uid` - User ID (required) 
- `token` - Security token (required)
- Additional parameters are passed as data to the action

## Quick Start

### 1. Send a notification with actions

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

### 2. When user taps the action button

ntfy.sh will make a GET request to your server, and the action will be processed automatically.

## Available Actions

The system comes with these built-in actions:

- `mfa_approve` - Approve MFA request
- `mfa_deny` - Deny MFA request  
- `registration_approve` - Approve user registration
- `registration_deny` - Deny user registration

## Adding New Actions

### 1. Extend the action handler

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

### 2. Implement the handler

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

Use the provided test script:

```bash
./test_simple_actions.sh
```

Or test actions directly:

```bash
curl "https://your-domain.com/api/act/mfa_approve?nid=test-123&uid=user-456&token=test-token"
```

## ntfy.sh Action Types

ntfy.sh supports these action types:

- **`view`** - Opens a URL in browser/app
- **`http`** - Makes an HTTP request to your server (defaults to POST, but we use GET)
- **`broadcast`** - Sends Android broadcast (Android only)

We use the **`http`** action type with GET method for simplicity.

## Benefits

1. **Simple**: Single endpoint for all actions
2. **GET requests**: Easy to use with ntfy.sh http actions
3. **No webhooks**: Direct HTTP calls from ntfy.sh
4. **Clean URLs**: Easy to understand and debug
5. **Extensible**: Easy to add new action types
6. **User-friendly**: Simple HTML responses

## Security

- **Token validation**: All actions require a valid security token
- **User authorization**: Actions are validated against user permissions
- **Input validation**: All parameters are validated

## Examples

See `SIMPLE_ACTIONS.md` for comprehensive examples and use cases. 