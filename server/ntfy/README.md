# Notification Service (ntfy)

A flexible notification service built on NATS JetStream that supports multiple channels and user preferences, with full integration with ntfy.sh for push notifications.

## Features

- **ntfy.sh Integration**: Full integration with ntfy.sh for push notifications
- **Multi-channel support**: Email, Push, SMS, Webhooks, Slack, Discord, etc.
- **User preferences**: Per-user channel and category preferences
- **Quiet hours**: Configurable do-not-disturb periods
- **Priority levels**: Low, Normal, High, Urgent
- **Category filtering**: Enable/disable notifications by category
- **Acknowledgment tracking**: Track delivery status per channel
- **Persistent storage**: JetStream KV for preferences and notifications

## Architecture

### NATS Subjects

- `ntfy.user.preferences` - User preference updates
- `ntfy.notification` - Incoming notifications
- `ntfy.notification.ack` - Delivery acknowledgments

### Queue Groups

- `ntfy.workers` - Load-balanced notification processing

### KV Storage

- `KV_ntfy` bucket stores:
  - User preferences: `prefs:{user_id}`
  - Notifications: `notification:{notification_id}`
  - Acknowledgments: `ack:{notification_id}:{channel}`

## Usage

### Initialize Service

```go
ntfy, err := NewNtfy(ctx, nc, logger)
if err != nil {
    log.Fatal(err)
}

err = ntfy.Start(ctx)
if err != nil {
    log.Fatal(err)
}
```

### Update User Preferences

```go
prefs := UserPreferences{
    UserID: "user123",
    Email:  true,
    Push:   true,
    SMS:    false,
    NtfyTopic: "my-app-notifications", // User's ntfy.sh topic
    Channels: map[string]bool{
        "slack": true,
    },
    Categories: map[string]bool{
        "system":   true,
        "alerts":   true,
        "updates":  false,
    },
    QuietHours: &QuietHours{
        Start:    "22:00",
        End:      "08:00",
        Timezone: "UTC",
        Enabled:  true,
    },
}

ntfy.UpdateUserPreferences(prefs)
```

### Send Notification

```go
notification := Notification{
    ID:       uuid.New().String(),
    UserID:   "user123",
    Title:    "System Alert",
    Message:  "Your account has been updated",
    Category: "system",
    Priority: PriorityNormal,
    Data: map[string]interface{}{
        "account_id": "acc456",
    },
}

ntfy.SendNotification(notification)
```

## Notification Categories

- `system` - System notifications
- `security` - Security alerts
- `alerts` - General alerts
- `updates` - Update notifications
- `onboarding` - Welcome/onboarding messages
- `marketing` - Marketing messages

## Priority Levels

- `low` - Non-urgent notifications
- `normal` - Standard notifications
- `high` - Important notifications
- `urgent` - Critical notifications (bypasses quiet hours)

## ntfy.sh Integration

The service includes full integration with ntfy.sh for push notifications:

### Setup

1. **User Configuration**: Users set their ntfy.sh topic in preferences
2. **Automatic Sending**: Notifications are automatically sent to ntfy.sh
3. **Priority Mapping**: Our priority levels are mapped to ntfy.sh priorities
4. **Rich Notifications**: Support for titles, tags, and custom data

### User Setup

Users need to subscribe to their topic:

```bash
# Install ntfy client
# macOS: brew install ntfy
# Linux: See https://ntfy.sh/docs/install/

# Subscribe to your topic
ntfy subscribe my-app-notifications

# Or use the web interface
# https://ntfy.sh/my-app-notifications
```

### Mobile Apps

- **iOS**: ntfy app from App Store
- **Android**: ntfy app from Google Play
- Subscribe to the same topic for notifications

### Features

- **Cross-platform**: Works on desktop, mobile, and web
- **Real-time**: Instant push notifications
- **Rich content**: Titles, messages, priorities, tags
- **Custom data**: Additional JSON data in headers
- **Privacy**: No account required, topic-based subscriptions

## Channel Integration

The service is designed to be extended with actual channel implementations:

- **ntfy.sh**: ✅ Fully implemented
- **Email**: Integrate with SendGrid, AWS SES, etc.
- **Push**: Firebase Cloud Messaging, Apple Push Notifications
- **SMS**: Twilio, AWS SNS
- **Webhooks**: Custom HTTP endpoints
- **Slack**: Slack Webhook API
- **Discord**: Discord Webhook API

## Scaling

- **Horizontal**: Multiple service instances join the same queue group
- **Vertical**: Increase worker goroutines per instance
- **Channel-specific**: Scale different channels independently

## Monitoring

Track notification delivery through:
- NATS acknowledgments
- KV storage queries
- Service logs
- Custom metrics

## Configuration

### Environment Variables

```bash
# ntfy.sh server (optional, defaults to https://ntfy.sh)
NTFY_SERVER=https://ntfy.sh

# Custom ntfy.sh instance (if self-hosted)
NTFY_SERVER=https://ntfy.yourdomain.com
```

### Custom ntfy.sh Server

If you want to use your own ntfy.sh instance:

```go
// Use custom server
ntfy, err := NewNtfyWithConfig(ctx, nc, logger, "https://ntfy.yourdomain.com")
if err != nil {
    log.Fatal(err)
}
```

## Security

- User isolation through user_id filtering
- Channel-specific credentials
- Rate limiting per user/channel
- Audit trail via acknowledgments
- ntfy.sh topics are user-specific and private 