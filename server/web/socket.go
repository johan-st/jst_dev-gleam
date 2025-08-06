package web

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	"jst_dev/server/jst_log"

	"github.com/gorilla/websocket"
	"github.com/nats-io/nats.go"
)

// Message types for WebSocket communication
const (
	MsgTypeConnect     = "connect"
	MsgTypeDisconnect  = "disconnect"
	MsgTypeSubscribe   = "subscribe"
	MsgTypeUnsubscribe = "unsubscribe"
	MsgTypeData        = "data"
	MsgTypeError       = "error"
	MsgTypeAuth        = "auth"
	MsgTypeSync        = "sync"
)

// WebSocketMessage represents the structure of messages sent over WebSocket
type WebSocketMessage struct {
	Type      string      `json:"type"`
	Topic     string      `json:"topic,omitempty"`
	Data      interface{} `json:"data,omitempty"`
	Error     string      `json:"error,omitempty"`
	UserID    string      `json:"user_id,omitempty"`
	Timestamp int64       `json:"timestamp,omitempty"`
}

// Client represents a connected WebSocket client
type Client struct {
	ID     string
	Conn   *websocket.Conn
	UserID string
	Topics map[string]bool
	Send   chan []byte
	Hub    *Hub
	mu     sync.RWMutex
}

// Hub manages all WebSocket connections and NATS subscriptions
type Hub struct {
	clients    map[*Client]bool
	broadcast  chan []byte
	register   chan *Client
	unregister chan *Client
	nc         *nats.Conn
	logger     *jst_log.Logger
	ctx        context.Context
	mu         sync.RWMutex
}

// NewHub creates a new WebSocket hub
func NewHub(nc *nats.Conn, logger *jst_log.Logger, ctx context.Context) *Hub {
	return &Hub{
		clients:    make(map[*Client]bool),
		broadcast:  make(chan []byte),
		register:   make(chan *Client),
		unregister: make(chan *Client),
		nc:         nc,
		logger:     logger,
		ctx:        ctx,
	}
}

// Run starts the hub's main event loop
func (h *Hub) Run() {
	for {
		select {
		case client := <-h.register:
			h.mu.Lock()
			h.clients[client] = true
			h.mu.Unlock()
			h.logger.Info("Client registered: %s", client.ID)

		case client := <-h.unregister:
			h.mu.Lock()
			if _, ok := h.clients[client]; ok {
				delete(h.clients, client)
				close(client.Send)
			}
			h.mu.Unlock()
			h.logger.Info("Client unregistered: %s", client.ID)

		case message := <-h.broadcast:
			h.mu.RLock()
			for client := range h.clients {
				select {
				case client.Send <- message:
				default:
					close(client.Send)
					delete(h.clients, client)
				}
			}
			h.mu.RUnlock()

		case <-h.ctx.Done():
			h.logger.Info("Hub shutting down")
			return
		}
	}
}

// Broadcast sends a message to all connected clients
func (h *Hub) Broadcast(msg *WebSocketMessage) {
	data, err := json.Marshal(msg)
	if err != nil {
		h.logger.Error("Failed to marshal broadcast message: %v", err)
		return
	}
	h.broadcast <- data
}

// SendToUser sends a message to a specific user
func (h *Hub) SendToUser(userID string, msg *WebSocketMessage) {
	data, err := json.Marshal(msg)
	if err != nil {
		h.logger.Error("Failed to marshal user message: %v", err)
		return
	}

	h.mu.RLock()
	defer h.mu.RUnlock()

	for client := range h.clients {
		if client.UserID == userID {
			select {
			case client.Send <- data:
			default:
				close(client.Send)
				delete(h.clients, client)
			}
		}
	}
}

// WebSocket upgrader configuration
var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		// In production, implement proper origin checking
		return true
	},
}

// HandleWebSocket handles WebSocket connections
func HandleWebSocket(hub *Hub, w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		hub.logger.Error("Failed to upgrade connection: %v", err)
		return
	}

	// Extract user ID from JWT token or query parameter
	userID := r.URL.Query().Get("user_id")
	if userID == "" {
		// Try to get from JWT token in headers
		if token := r.Header.Get("Authorization"); token != "" {
			// Parse JWT and extract user ID
			// This would integrate with your existing JWT authentication
			userID = "anonymous" // Placeholder
		}
	}

	client := &Client{
		ID:     generateClientID(),
		Conn:   conn,
		UserID: userID,
		Topics: make(map[string]bool),
		Send:   make(chan []byte, 256),
		Hub:    hub,
	}

	hub.register <- client

	// Send welcome message
	welcomeMsg := &WebSocketMessage{
		Type:      MsgTypeConnect,
		Data:      map[string]string{"message": "Connected to sync server"},
		UserID:    userID,
		Timestamp: time.Now().Unix(),
	}
	client.sendMessage(welcomeMsg)

	// Start goroutines for reading and writing
	go client.writePump()
	go client.readPump()
}

// Client methods
func (c *Client) readPump() {
	defer func() {
		c.Hub.unregister <- c
		c.Conn.Close()
	}()

	c.Conn.SetReadLimit(512)
	if err := c.Conn.SetReadDeadline(time.Now().Add(60 * time.Second)); err != nil {
		c.Hub.logger.Error("Failed to set read deadline: %v", err)
	}
	c.Conn.SetPongHandler(func(string) error {
		if err := c.Conn.SetReadDeadline(time.Now().Add(60 * time.Second)); err != nil {
			c.Hub.logger.Error("Failed to set read deadline: %v", err)
		}
		return nil
	})

	for {
		_, message, err := c.Conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				c.Hub.logger.Error("WebSocket read error: %v", err)
			}
			break
		}

		c.handleMessage(message)
	}
}

func (c *Client) writePump() {
	ticker := time.NewTicker(54 * time.Second)
	defer func() {
		ticker.Stop()
		c.Conn.Close()
	}()

	for {
		select {
		case message, ok := <-c.Send:
			if err := c.Conn.SetWriteDeadline(time.Now().Add(10 * time.Second)); err != nil {
				c.Hub.logger.Error("Failed to set write deadline: %v", err)
				return
			}
			if !ok {
				if err := c.Conn.WriteMessage(websocket.CloseMessage, []byte{}); err != nil {
					c.Hub.logger.Error("Failed to write close message: %v", err)
					return
				}
				return
			}

			w, err := c.Conn.NextWriter(websocket.TextMessage)
			if err != nil {
				c.Hub.logger.Error("Failed to get next writer: %v", err)
				return
			}
			if _, err := w.Write(message); err != nil {
				c.Hub.logger.Error("Failed to write message: %v", err)
				return
			}

			if err := w.Close(); err != nil {
				c.Hub.logger.Error("Failed to close writer: %v", err)
				return
			}
		case <-ticker.C:
			if err := c.Conn.SetWriteDeadline(time.Now().Add(10 * time.Second)); err != nil {
				c.Hub.logger.Error("Failed to set write deadline: %v", err)
				return
			}
			if err := c.Conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				c.Hub.logger.Error("Failed to write ping message: %v", err)
				return
			}
		}
	}
}

func (c *Client) handleMessage(message []byte) {
	var msg WebSocketMessage
	if err := json.Unmarshal(message, &msg); err != nil {
		c.sendError("Invalid message format")
		return
	}

	switch msg.Type {
	case MsgTypeSubscribe:
		c.handleSubscribe(msg.Topic)
	case MsgTypeUnsubscribe:
		c.handleUnsubscribe(msg.Topic)
	case MsgTypeAuth:
		c.handleAuth(msg.UserID)
	case MsgTypeSync:
		c.handleSync(msg)
	default:
		c.sendError("Unknown message type")
	}
}

func (c *Client) handleSubscribe(topic string) {
	if topic == "" {
		c.sendError("Topic is required for subscription")
		return
	}

	c.mu.Lock()
	c.Topics[topic] = true
	c.mu.Unlock()

	// Subscribe to NATS topic
	_, err := c.Hub.nc.Subscribe(topic, func(natsMsg *nats.Msg) {
		syncMsg := &WebSocketMessage{
			Type:      MsgTypeData,
			Topic:     topic,
			Data:      string(natsMsg.Data),
			Timestamp: time.Now().Unix(),
		}
		c.sendMessage(syncMsg)
	})

	if err != nil {
		c.sendError("Failed to subscribe to topic")
		return
	}

	// Store subscription for cleanup
	// In a production system, you'd want to track subscriptions properly

	response := &WebSocketMessage{
		Type:      MsgTypeSubscribe,
		Topic:     topic,
		Data:      map[string]string{"status": "subscribed"},
		Timestamp: time.Now().Unix(),
	}
	c.sendMessage(response)
}

func (c *Client) handleUnsubscribe(topic string) {
	c.mu.Lock()
	delete(c.Topics, topic)
	c.mu.Unlock()

	// Unsubscribe from NATS topic
	// Implementation would depend on how you track subscriptions

	response := &WebSocketMessage{
		Type:      MsgTypeUnsubscribe,
		Topic:     topic,
		Data:      map[string]string{"status": "unsubscribed"},
		Timestamp: time.Now().Unix(),
	}
	c.sendMessage(response)
}

func (c *Client) handleAuth(userID string) {
	if userID != "" {
		c.UserID = userID
	}

	response := &WebSocketMessage{
		Type:      MsgTypeAuth,
		UserID:    c.UserID,
		Data:      map[string]string{"status": "authenticated"},
		Timestamp: time.Now().Unix(),
	}
	c.sendMessage(response)
}

func (c *Client) handleSync(msg WebSocketMessage) {
	// Handle data synchronization
	// This could involve:
	// 1. Publishing to NATS for other clients
	// 2. Storing in a database
	// 3. Triggering business logic

	if msg.Topic != "" {
		// Publish to NATS for other subscribers
		data, _ := json.Marshal(msg.Data)
		if err := c.Hub.nc.Publish(msg.Topic, data); err != nil {
			c.Hub.logger.Error("Failed to publish to NATS: %v", err)
		}
	}

	response := &WebSocketMessage{
		Type:      MsgTypeSync,
		Topic:     msg.Topic,
		Data:      map[string]string{"status": "synced"},
		Timestamp: time.Now().Unix(),
	}
	c.sendMessage(response)
}

func (c *Client) sendMessage(msg *WebSocketMessage) {
	data, err := json.Marshal(msg)
	if err != nil {
		c.Hub.logger.Error("Failed to marshal message: %v", err)
		return
	}

	select {
	case c.Send <- data:
	default:
		c.Hub.unregister <- c
	}
}

func (c *Client) sendError(errorMsg string) {
	msg := &WebSocketMessage{
		Type:      MsgTypeError,
		Error:     errorMsg,
		Timestamp: time.Now().Unix(),
	}
	c.sendMessage(msg)
}

// Utility function to generate unique client IDs
func generateClientID() string {
	return fmt.Sprintf("client_%d", time.Now().UnixNano())
}

// SyncService provides high-level data synchronization functionality
type SyncService struct {
	hub    *Hub
	logger *jst_log.Logger
}

// NewSyncService creates a new sync service
func NewSyncService(nc *nats.Conn, logger *jst_log.Logger, ctx context.Context) *SyncService {
	hub := NewHub(nc, logger, ctx)
	go hub.Run()

	return &SyncService{
		hub:    hub,
		logger: logger,
	}
}

// PublishData publishes data to a specific topic
func (s *SyncService) PublishData(topic string, data interface{}) error {
	msg := &WebSocketMessage{
		Type:      MsgTypeData,
		Topic:     topic,
		Data:      data,
		Timestamp: time.Now().Unix(),
	}
	s.hub.Broadcast(msg)
	return nil
}

// PublishToUser publishes data to a specific user
func (s *SyncService) PublishToUser(userID string, data interface{}) error {
	msg := &WebSocketMessage{
		Type:      MsgTypeData,
		Data:      data,
		UserID:    userID,
		Timestamp: time.Now().Unix(),
	}
	s.hub.SendToUser(userID, msg)
	return nil
}

// GetHub returns the underlying hub for direct access
func (s *SyncService) GetHub() *Hub {
	return s.hub
}
