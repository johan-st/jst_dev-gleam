package core

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	"jst_dev/server/jst_log"

	"github.com/gorilla/websocket"
	"github.com/nats-io/nats.go"
)

// WebSocketConfig holds configuration for WebSocket connections
type WebSocketConfig struct {
	ReadBufferSize  int `json:"read_buffer_size"`
	WriteBufferSize int `json:"write_buffer_size"`
	CheckOrigin     func(r *http.Request) bool
	PingPeriod      time.Duration `json:"ping_period"`
	PongWait        time.Duration `json:"pong_wait"`
	WriteWait       time.Duration `json:"write_wait"`
}

// WebSocketMessage represents a message sent over WebSocket
type WebSocketMessage struct {
	Type      string                 `json:"type"`
	Subject   string                 `json:"subject,omitempty"`
	Data      interface{}            `json:"data,omitempty"`
	RequestID string                 `json:"request_id,omitempty"`
	ClientID  string                 `json:"client_id,omitempty"`
	Metadata  map[string]interface{} `json:"metadata,omitempty"`
}

// WebSocketClient represents a connected WebSocket client
type WebSocketClient struct {
	ID              string
	Conn            *websocket.Conn
	Send            chan []byte
	Subscriptions   map[string]*ClientSubscription
	RealtimeManager *RealtimeManager
	Logger          *jst_log.Logger
	mu              sync.RWMutex
	lastPing        time.Time
}

// WebSocketHandler manages WebSocket connections and real-time updates
type WebSocketHandler struct {
	realtimeManager *RealtimeManager
	config          WebSocketConfig
	logger          *jst_log.Logger
	clients         map[string]*WebSocketClient
	clientsMu       sync.RWMutex
	upgrader        websocket.Upgrader
}

// NewWebSocketHandler creates a new WebSocket handler
func NewWebSocketHandler(realtimeManager *RealtimeManager, config WebSocketConfig, logger *jst_log.Logger) *WebSocketHandler {
	if config.ReadBufferSize == 0 {
		config.ReadBufferSize = 1024
	}
	if config.WriteBufferSize == 0 {
		config.WriteBufferSize = 1024
	}
	if config.PingPeriod == 0 {
		config.PingPeriod = 54 * time.Second
	}
	if config.PongWait == 0 {
		config.PongWait = 60 * time.Second
	}
	if config.WriteWait == 0 {
		config.WriteWait = 10 * time.Second
	}
	if config.CheckOrigin == nil {
		config.CheckOrigin = func(r *http.Request) bool {
			return true // Allow all origins in development
		}
	}

	upgrader := websocket.Upgrader{
		ReadBufferSize:  config.ReadBufferSize,
		WriteBufferSize: config.WriteBufferSize,
		CheckOrigin:     config.CheckOrigin,
	}

	return &WebSocketHandler{
		realtimeManager: realtimeManager,
		config:          config,
		logger:          logger,
		clients:         make(map[string]*WebSocketClient),
		upgrader:        upgrader,
	}
}

// HandleWebSocket handles WebSocket connections
func (wsh *WebSocketHandler) HandleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := wsh.upgrader.Upgrade(w, r, nil)
	if err != nil {
		wsh.logger.Error("failed to upgrade connection: %v", err)
		return
	}

	clientID := r.Header.Get("X-Client-ID")
	if clientID == "" {
		clientID = fmt.Sprintf("client_%d", time.Now().UnixNano())
	}

	client := &WebSocketClient{
		ID:              clientID,
		Conn:            conn,
		Send:            make(chan []byte, 256),
		Subscriptions:   make(map[string]*ClientSubscription),
		RealtimeManager: wsh.realtimeManager,
		Logger:          wsh.logger.WithBreadcrumb("websocket").WithBreadcrumb(clientID),
		lastPing:        time.Now(),
	}

	wsh.clientsMu.Lock()
	wsh.clients[clientID] = client
	wsh.clientsMu.Unlock()

	wsh.logger.Info("client %s connected", clientID)

	// Start goroutines for reading and writing
	go client.writePump()
	go client.readPump()

	// Send welcome message
	welcomeMsg := WebSocketMessage{
		Type:     "connected",
		ClientID: clientID,
		Data: map[string]interface{}{
			"message": "Connected to real-time updates",
			"time":    time.Now(),
		},
	}
	client.sendMessage(welcomeMsg)
}

// readPump handles reading messages from the WebSocket
func (client *WebSocketClient) readPump() {
	defer func() {
		client.Conn.Close()
		client.cleanup()
	}()

	client.Conn.SetReadLimit(512)
	client.Conn.SetReadDeadline(time.Now().Add(client.RealtimeManager.config.CacheConfig.DefaultTTL))
	client.Conn.SetPongHandler(func(string) error {
		client.mu.Lock()
		client.lastPing = time.Now()
		client.mu.Unlock()
		client.Conn.SetReadDeadline(time.Now().Add(client.RealtimeManager.config.CacheConfig.DefaultTTL))
		return nil
	})

	for {
		var msg WebSocketMessage
		err := client.Conn.ReadJSON(&msg)
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				client.Logger.Error("websocket error: %v", err)
			}
			break
		}

		client.handleMessage(msg)
	}
}

// writePump handles writing messages to the WebSocket
func (client *WebSocketClient) writePump() {
	ticker := time.NewTicker(client.RealtimeManager.config.CacheConfig.DefaultTTL)
	defer func() {
		ticker.Stop()
		client.Conn.Close()
	}()

	for {
		select {
		case message, ok := <-client.Send:
			client.Conn.SetWriteDeadline(time.Now().Add(client.RealtimeManager.config.CacheConfig.DefaultTTL))
			if !ok {
				client.Conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}

			w, err := client.Conn.NextWriter(websocket.TextMessage)
			if err != nil {
				return
			}
			w.Write(message)

			// Add queued messages to the current websocket message
			n := len(client.Send)
			for i := 0; i < n; i++ {
				w.Write([]byte{'\n'})
				w.Write(<-client.Send)
			}

			if err := w.Close(); err != nil {
				return
			}
		case <-ticker.C:
			client.Conn.SetWriteDeadline(time.Now().Add(client.RealtimeManager.config.CacheConfig.DefaultTTL))
			if err := client.Conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

// handleMessage processes incoming WebSocket messages
func (client *WebSocketClient) handleMessage(msg WebSocketMessage) {
	client.Logger.Debug("received message: %s", msg.Type)

	switch msg.Type {
	case "subscribe":
		client.handleSubscribe(msg)
	case "unsubscribe":
		client.handleUnsubscribe(msg)
	case "request":
		client.handleRequest(msg)
	case "ping":
		client.handlePing(msg)
	default:
		client.Logger.Warn("unknown message type: %s", msg.Type)
		client.sendError("unknown_message_type", "Unknown message type", msg.RequestID)
	}
}

// handleSubscribe handles subscription requests
func (client *WebSocketClient) handleSubscribe(msg WebSocketMessage) {
	subject, ok := msg.Data.(string)
	if !ok {
		client.sendError("invalid_subject", "Subject must be a string", msg.RequestID)
		return
	}

	subscriptionID := fmt.Sprintf("%s_%d", client.ID, time.Now().UnixNano())

	// Create subscription with real-time manager
	sub, err := client.RealtimeManager.CreateClientSubscription(
		client.ID,
		subscriptionID,
		[]string{subject},
		nil,
	)
	if err != nil {
		client.Logger.Error("failed to create subscription: %v", err)
		client.sendError("subscription_failed", "Failed to create subscription", msg.RequestID)
		return
	}

	// Store subscription
	client.mu.Lock()
	client.Subscriptions[subscriptionID] = sub
	client.mu.Unlock()

	// Subscribe to NATS subject
	natsSub, err := client.RealtimeManager.nc.Subscribe(subject, func(natsMsg *nats.Msg) {
		// Forward NATS message to WebSocket client
		updateMsg := WebSocketMessage{
			Type:     "update",
			Subject:  subject,
			Data:     json.RawMessage(natsMsg.Data),
			ClientID: client.ID,
		}
		client.sendMessage(updateMsg)
	})

	if err != nil {
		client.Logger.Error("failed to subscribe to NATS: %v", err)
		client.sendError("nats_subscription_failed", "Failed to subscribe to NATS", msg.RequestID)
		return
	}

	// Store NATS subscription for cleanup
	client.mu.Lock()
	client.Subscriptions[subscriptionID].NatsSub = natsSub
	client.mu.Unlock()

	// Send confirmation
	response := WebSocketMessage{
		Type:      "subscribed",
		Subject:   subject,
		RequestID: msg.RequestID,
		Data: map[string]interface{}{
			"subscription_id": subscriptionID,
			"subject":         subject,
		},
	}
	client.sendMessage(response)

	client.Logger.Info("subscribed to %s", subject)
}

// handleUnsubscribe handles unsubscription requests
func (client *WebSocketClient) handleUnsubscribe(msg WebSocketMessage) {
	subscriptionID, ok := msg.Data.(string)
	if !ok {
		client.sendError("invalid_subscription_id", "Subscription ID must be a string", msg.RequestID)
		return
	}

	client.mu.Lock()
	sub, exists := client.Subscriptions[subscriptionID]
	if exists {
		if sub.NatsSub != nil {
			sub.NatsSub.Unsubscribe()
		}
		delete(client.Subscriptions, subscriptionID)
	}
	client.mu.Unlock()

	if !exists {
		client.sendError("subscription_not_found", "Subscription not found", msg.RequestID)
		return
	}

	// Send confirmation
	response := WebSocketMessage{
		Type:      "unsubscribed",
		RequestID: msg.RequestID,
		Data: map[string]interface{}{
			"subscription_id": subscriptionID,
		},
	}
	client.sendMessage(response)

	client.Logger.Info("unsubscribed from %s", subscriptionID)
}

// handleRequest handles request/response messages
func (client *WebSocketClient) handleRequest(msg WebSocketMessage) {
	// This would handle request/response patterns
	// For now, just echo back the request
	response := WebSocketMessage{
		Type:      "response",
		RequestID: msg.RequestID,
		Data: map[string]interface{}{
			"echo": msg.Data,
		},
	}
	client.sendMessage(response)
}

// handlePing handles ping messages
func (client *WebSocketClient) handlePing(msg WebSocketMessage) {
	response := WebSocketMessage{
		Type: "pong",
		Data: map[string]interface{}{
			"timestamp": time.Now(),
		},
	}
	client.sendMessage(response)
}

// sendMessage sends a message to the client
func (client *WebSocketClient) sendMessage(msg WebSocketMessage) {
	data, err := json.Marshal(msg)
	if err != nil {
		client.Logger.Error("failed to marshal message: %v", err)
		return
	}

	select {
	case client.Send <- data:
	default:
		client.Logger.Warn("client send channel full, dropping message")
	}
}

// sendError sends an error message to the client
func (client *WebSocketClient) sendError(code, message, requestID string) {
	errorMsg := WebSocketMessage{
		Type:      "error",
		RequestID: requestID,
		Data: map[string]interface{}{
			"code":    code,
			"message": message,
		},
	}
	client.sendMessage(errorMsg)
}

// cleanup removes the client from the handler
func (client *WebSocketClient) cleanup() {
	// Unsubscribe from all NATS subscriptions
	client.mu.Lock()
	for _, sub := range client.Subscriptions {
		if sub.NatsSub != nil {
			sub.NatsSub.Unsubscribe()
		}
	}
	client.mu.Unlock()

	// Remove from handler
	client.RealtimeManager.clientsMu.Lock()
	delete(client.RealtimeManager.clients, client.ID)
	client.RealtimeManager.clientsMu.Unlock()

	client.Logger.Info("client %s disconnected", client.ID)
}

// BroadcastToClients broadcasts a message to all connected clients
func (wsh *WebSocketHandler) BroadcastToClients(msg WebSocketMessage) {
	wsh.clientsMu.RLock()
	defer wsh.clientsMu.RUnlock()

	for _, client := range wsh.clients {
		client.sendMessage(msg)
	}
}

// BroadcastToSubject broadcasts a message to clients subscribed to a specific subject
func (wsh *WebSocketHandler) BroadcastToSubject(subject string, msg WebSocketMessage) {
	wsh.clientsMu.RLock()
	defer wsh.clientsMu.RUnlock()

	for _, client := range wsh.clients {
		client.mu.RLock()
		for _, sub := range client.Subscriptions {
			for _, subSubject := range sub.Subjects {
				if subSubject == subject {
					client.sendMessage(msg)
					break
				}
			}
		}
		client.mu.RUnlock()
	}
}

// GetClientCount returns the number of connected clients
func (wsh *WebSocketHandler) GetClientCount() int {
	wsh.clientsMu.RLock()
	defer wsh.clientsMu.RUnlock()
	return len(wsh.clients)
}

// GetClients returns all connected clients
func (wsh *WebSocketHandler) GetClients() map[string]*WebSocketClient {
	wsh.clientsMu.RLock()
	defer wsh.clientsMu.RUnlock()

	clients := make(map[string]*WebSocketClient)
	for id, client := range wsh.clients {
		clients[id] = client
	}
	return clients
}
