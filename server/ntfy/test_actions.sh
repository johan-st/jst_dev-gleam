#!/bin/bash

# Test script for NTFY.SH Actions
# Make sure your server is running and accessible

BASE_URL="http://localhost:8080"  # Change this to your server URL
USER_ID="test-user-123"
TOKEN="test-token-456"

echo "🧪 Testing NTFY.SH Actions System"
echo "=================================="
echo ""

# Test 1: Send notification with MFA actions
echo "📱 Test 1: Sending MFA notification with actions..."
curl -X POST "$BASE_URL/api/notifications" \
  -H "Content-Type: application/json" \
  -d "{
    \"message\": \"New login attempt detected. Please approve or deny.\",
    \"title\": \"MFA Request\",
    \"actions\": [
      {
        \"id\": \"mfa_approve\",
        \"action\": \"http\",
        \"label\": \"✅ Approve\",
        \"url\": \"$BASE_URL/api/ntfy/action\",
        \"method\": \"POST\",
        \"headers\": {
          \"Content-Type\": \"application/json\"
        },
        \"body\": \"{\\\"notification_id\\\":\\\"{{id}}\\\",\\\"action_id\\\":\\\"mfa_approve\\\",\\\"user_id\\\":\\\"$USER_ID\\\",\\\"token\\\":\\\"$TOKEN\\\"}\",
        \"clear\": true
      },
      {
        \"id\": \"mfa_deny\",
        \"action\": \"http\",
        \"label\": \"❌ Deny\",
        \"url\": \"$BASE_URL/api/ntfy/action\",
        \"method\": \"POST\",
        \"headers\": {
          \"Content-Type\": \"application/json\"
        },
        \"body\": \"{\\\"notification_id\\\":\\\"{{id}}\\\",\\\"action_id\\\":\\\"mfa_deny\\\",\\\"user_id\\\":\\\"$USER_ID\\\",\\\"token\\\":\\\"$TOKEN\\\"}\",
        \"clear\": true
      }
    ]
  }"
echo ""
echo ""

# Test 2: Send notification with registration actions
echo "📝 Test 2: Sending registration request notification..."
curl -X POST "$BASE_URL/api/notifications" \
  -H "Content-Type: application/json" \
  -d "{
    \"message\": \"New user registration request: john.doe@example.com\",
    \"title\": \"Registration Request\",
    \"actions\": [
      {
        \"id\": \"registration_approve\",
        \"action\": \"http\",
        \"label\": \"✅ Approve\",
        \"url\": \"$BASE_URL/api/ntfy/action\",
        \"method\": \"POST\",
        \"headers\": {
          \"Content-Type\": \"application/json\"
        },
        \"body\": \"{\\\"notification_id\\\":\\\"{{id}}\\\",\\\"action_id\\\":\\\"registration_approve\\\",\\\"user_id\\\":\\\"$USER_ID\\\",\\\"token\\\":\\\"$TOKEN\\\",\\\"data\\\":{\\\"email\\\":\\\"john.doe@example.com\\\"}}\",
        \"clear\": true
      },
      {
        \"id\": \"registration_deny\",
        \"action\": \"http\",
        \"label\": \"❌ Deny\",
        \"url\": \"$BASE_URL/api/ntfy/action\",
        \"method\": \"POST\",
        \"headers\": {
          \"Content-Type\": \"application/json\"
        },
        \"body\": \"{\\\"notification_id\\\":\\\"{{id}}\\\",\\\"action_id\\\":\\\"registration_deny\\\",\\\"user_id\\\":\\\"$USER_ID\\\",\\\"token\\\":\\\"$TOKEN\\\",\\\"data\\\":{\\\"email\\\":\\\"john.doe@example.com\\\"}}\",
        \"clear\": true
      }
    ]
  }"
echo ""
echo ""

# Test 3: Test action execution directly
echo "⚡ Test 3: Testing action execution directly..."
curl -X POST "$BASE_URL/api/ntfy/action" \
  -H "Content-Type: application/json" \
  -d "{
    \"notification_id\": \"test-notification-123\",
    \"action_id\": \"mfa_approve\",
    \"user_id\": \"$USER_ID\",
    \"token\": \"$TOKEN\",
    \"data\": {
      \"ip_address\": \"192.168.1.100\",
      \"user_agent\": \"Mozilla/5.0 (Test Browser)\"
    }
  }"
echo ""
echo ""

# Test 4: Test webhook endpoint
echo "🔗 Test 4: Testing webhook endpoint..."
curl -X POST "$BASE_URL/api/ntfy/webhook" \
  -H "Content-Type: application/json" \
  -d "{
    \"id\": \"webhook-test-123\",
    \"time\": $(date +%s),
    \"event\": \"action\",
    \"topic\": \"test-topic\",
    \"title\": \"Test Notification\",
    \"message\": \"This is a test webhook\",
    \"priority\": 3,
    \"tags\": [\"test\", \"webhook\"],
    \"actions\": [
      {
        \"id\": \"mfa_approve\",
        \"action\": \"http\",
        \"label\": \"Approve\"
      }
    ]
  }"
echo ""
echo ""

echo "✅ All tests completed!"
echo ""
echo "📋 Next steps:"
echo "1. Check your ntfy.sh topic to see the notifications with action buttons"
echo "2. Click the action buttons to trigger the webhooks"
echo "3. Check your server logs to see the action processing"
echo "4. Customize the action handlers for your specific use cases"