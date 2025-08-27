#!/bin/bash

# Test script for Simple NTFY.SH Actions
# Make sure your server is running and accessible

BASE_URL="http://localhost:8080"  # Change this to your server URL
USER_ID="test-user-123"
TOKEN="test-token-456"

echo "🧪 Testing Simple NTFY.SH Actions System"
echo "========================================="
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
        \"url\": \"$BASE_URL/api/act/mfa_approve?nid={{id}}&uid=$USER_ID&token=$TOKEN\",
        \"method\": \"GET\",
        \"clear\": true
      },
      {
        \"id\": \"mfa_deny\",
        \"action\": \"http\",
        \"label\": \"❌ Deny\",
        \"url\": \"$BASE_URL/api/act/mfa_deny?nid={{id}}&uid=$USER_ID&token=$TOKEN\",
        \"method\": \"GET\",
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
        \"url\": \"$BASE_URL/api/act/registration_approve?nid={{id}}&uid=$USER_ID&token=$TOKEN&email=john.doe@example.com\",
        \"method\": \"GET\",
        \"clear\": true
      },
      {
        \"id\": \"registration_deny\",
        \"action\": \"http\",
        \"label\": \"❌ Deny\",
        \"url\": \"$BASE_URL/api/act/registration_deny?nid={{id}}&uid=$USER_ID&token=$TOKEN&email=john.doe@example.com\",
        \"method\": \"GET\",
        \"clear\": true
      }
    ]
  }"
echo ""
echo ""

# Test 3: Test action endpoints directly
echo "⚡ Test 3: Testing action endpoints directly..."
echo "Testing MFA approve:"
curl -s "$BASE_URL/api/act/mfa_approve?nid=test-notification-123&uid=$USER_ID&token=$TOKEN" | head -5
echo ""
echo ""

echo "Testing MFA deny:"
curl -s "$BASE_URL/api/act/mfa_deny?nid=test-notification-123&uid=$USER_ID&token=$TOKEN" | head -5
echo ""
echo ""

echo "Testing registration approve:"
curl -s "$BASE_URL/api/act/registration_approve?nid=test-notification-123&uid=$USER_ID&token=$TOKEN&email=test@example.com" | head -5
echo ""
echo ""

echo "✅ All tests completed!"
echo ""
echo "📋 Next steps:"
echo "1. Check your ntfy.sh topic to see the notifications with action buttons"
echo "2. Click the action buttons to trigger the actions"
echo "3. Check your server logs to see the action processing"
echo "4. The actions will open in a browser tab and auto-close after 3 seconds"
echo ""
echo "🔗 Action URLs will look like:"
echo "   $BASE_URL/api/act/mfa_approve?nid=123&uid=456&token=789"
echo "   $BASE_URL/api/act/registration_deny?nid=123&uid=456&token=789&email=user@example.com"