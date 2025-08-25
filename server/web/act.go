package web

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"jst_dev/server/jst_log"
	"jst_dev/server/ntfy"

	"github.com/nats-io/nats.go"
)

// Handle action execution requests
func handleAction(l *jst_log.Logger, nc *nats.Conn) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger := l.WithBreadcrumb("handleAction")

		// Extract action ID from URL path
		actionID := r.PathValue("action_id")
		if actionID == "" {
			http.Error(w, "action ID is required", http.StatusBadRequest)
			return
		}

		// Get query parameters
		notificationID := r.URL.Query().Get("nid")
		userID := r.URL.Query().Get("uid")
		token := r.URL.Query().Get("token")

		// Validate required parameters
		if notificationID == "" || userID == "" || token == "" {
			http.Error(w, "missing required parameters: nid, uid, token", http.StatusBadRequest)
			return
		}

		// Create action request
		actionReq := ntfy.ActionRequest{
			NotificationID: notificationID,
			ActionID:       actionID,
			UserID:         userID,
			Token:          token,
			Data:           make(map[string]interface{}),
		}

		// Add any additional query parameters as data
		for key, values := range r.URL.Query() {
			if key != "nid" && key != "uid" && key != "token" {
				if len(values) > 0 {
					actionReq.Data[key] = values[0]
				}
			}
		}

		// Marshal action request
		actionReqBytes, err := json.Marshal(actionReq)
		if err != nil {
			logger.Error("failed to marshal action request: %v", err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
			return
		}

		// Send action request via NATS
		msg, err := nc.Request(ntfy.SubjectAction, actionReqBytes, 10*time.Second)
		if err != nil {
			logger.Error("failed to send action request: %v", err)
			http.Error(w, "failed to process action", http.StatusInternalServerError)
			return
		}

		// Check for service errors
		if msg.Header.Get("Nats-Service-Error") != "" {
			errorCode := msg.Header.Get("Nats-Service-Error-Code")
			if errorCode == "400" {
				http.Error(w, string(msg.Data), http.StatusBadRequest)
				return
			}
			http.Error(w, "action service error", http.StatusInternalServerError)
			return
		}

		// Parse action response
		var actionResp ntfy.ActionResponse
		if err := json.Unmarshal(msg.Data, &actionResp); err != nil {
			logger.Error("failed to unmarshal action response: %v", err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
			return
		}

		// Return simple response
		if actionResp.Success {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.WriteHeader(http.StatusOK)
			fmt.Fprintf(w, `
<!DOCTYPE html>
<html>
<head>
    <title>Action Completed</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
        .success { color: #28a745; }
        .message { margin: 20px 0; }
    </style>
</head>
<body>
    <div class="success">✅ %s</div>
    <div class="message">%s</div>
    <script>setTimeout(() => window.close(), 3000);</script>
</body>
</html>`, actionResp.Message, actionResp.Message)
		} else {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprintf(w, `
<!DOCTYPE html>
<html>
<head>
    <title>Action Failed</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
        .error { color: #dc3545; }
        .message { margin: 20px 0; }
    </style>
</head>
<body>
    <div class="error">❌ %s</div>
    <div class="message">%s</div>
    <script>setTimeout(() => window.close(), 3000);</script>
</body>
</html>`, actionResp.Message, actionResp.Message)
		}
	})
}