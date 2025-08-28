package chat

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/micro"
	"jst_dev/server/jst_log"
)

const (
	// NATS Subjects
	SubjectContactRequestCreate = "chat.request.create"
	SubjectContactRequestRespond = "chat.request.respond"
	SubjectChatMessageSend = "chat.message.send"
	
	// Subject patterns for WebSocket authorization
	SubjectPatternChatRoom = "chat.room.*"
	SubjectPatternChatRequest = "chat.request.*"
)

type Chat struct {
	nc *nats.Conn
	l  *jst_log.Logger
	
	// In-memory storage for MVP (can be replaced with NATS KV later)
	requests   map[string]*ContactRequest
	sessions   map[string]*ChatSession
	mu         sync.RWMutex
}

func New(ctx context.Context, nc *nats.Conn, l *jst_log.Logger) (Chat, error) {
	if l == nil {
		return Chat{}, fmt.Errorf("logger is required")
	}

	return Chat{
		nc:        nc,
		l:         l,
		requests:  make(map[string]*ContactRequest),
		sessions:  make(map[string]*ChatSession),
	}, nil
}

// Start the chat service
func (c *Chat) Start(ctx context.Context) error {
	svcMetadata := map[string]string{}
	svcMetadata["location"] = "unknown"
	svcMetadata["environment"] = "development"

	chatSvc, err := micro.AddService(c.nc, micro.Config{
		Name:        "chat",
		Version:     "1.0.0",
		Description: "Chat and contact request service",
		Metadata:    svcMetadata,
	})
	if err != nil {
		return fmt.Errorf("add service: %w", err)
	}

	// Add contact request creation endpoint
	if err = chatSvc.AddEndpoint("create_contact_request", c.handleContactRequestCreate(), micro.WithEndpointSubject(SubjectContactRequestCreate)); err != nil {
		return fmt.Errorf("add create contact request endpoint: %w", err)
	}

	// Add contact request response endpoint
	if err = chatSvc.AddEndpoint("respond_contact_request", c.handleContactRequestRespond(), micro.WithEndpointSubject(SubjectContactRequestRespond)); err != nil {
		return fmt.Errorf("add respond contact request endpoint: %w", err)
	}

	// Add chat message sending endpoint
	if err = chatSvc.AddEndpoint("send_chat_message", c.handleChatMessageSend(), micro.WithEndpointSubject(SubjectChatMessageSend)); err != nil {
		return fmt.Errorf("add send chat message endpoint: %w", err)
	}

	c.l.Info("chat service started")
	return nil
}

// Handle contact request creation
func (c *Chat) handleContactRequestCreate() micro.HandlerFunc {
	return func(req micro.Request) {
		var createReq ContactRequestCreate
		if err := json.Unmarshal(req.Data(), &createReq); err != nil {
			c.l.Error("failed to unmarshal contact request create", "error", err)
			if err := req.Error("400", fmt.Sprintf("failed to unmarshal request: %v", err), nil); err != nil {
				c.l.Error("failed to send error response", "error", err)
			}
			return
		}

		// Validate required fields
		if createReq.ClientMsgID == "" {
			if err := req.Error("400", "client_msg_id is required", nil); err != nil {
				c.l.Error("failed to send error response", "error", err)
			}
			return
		}

		// Create contact request
		contactReq := &ContactRequest{
			ID:          uuid.New().String(),
			RequesterID: createReq.RequesterID,
			RequesterIP: createReq.RequesterIP,
			Status:      "pending",
			CreatedAt:   time.Now(),
			ClientMsgID: createReq.ClientMsgID,
		}

		// Store in memory
		c.mu.Lock()
		c.requests[contactReq.ID] = contactReq
		c.mu.Unlock()

		// Publish to chat.request.<request_id> for real-time updates
		subject := fmt.Sprintf("chat.request.%s", contactReq.ID)
		requestData, _ := json.Marshal(contactReq)
		if err := c.nc.Publish(subject, requestData); err != nil {
			c.l.Error("failed to publish contact request", "error", err, "request_id", contactReq.ID)
		}

		c.l.Info("contact request created", "request_id", contactReq.ID, "client_msg_id", createReq.ClientMsgID)

		// Return the created request
		response, _ := json.Marshal(contactReq)
		if err := req.Respond(response); err != nil {
			c.l.Error("failed to send response", "error", err)
		}
	}
}

// Handle contact request response (accept/busy)
func (c *Chat) handleContactRequestRespond() micro.HandlerFunc {
	return func(req micro.Request) {
		var responseReq ContactRequestResponse
		if err := json.Unmarshal(req.Data(), &responseReq); err != nil {
			c.l.Error("failed to unmarshal contact request response", "error", err)
			if err := req.Error("400", fmt.Sprintf("failed to unmarshal request: %v", err), nil); err != nil {
				c.l.Error("failed to send error response", "error", err)
			}
			return
		}

		// Get the contact request
		c.mu.RLock()
		contactReq, exists := c.requests[responseReq.RequestID]
		c.mu.RUnlock()

		if !exists {
			if err := req.Error("404", "contact request not found", nil); err != nil {
				c.l.Error("failed to send error response", "error", err)
			}
			return
		}

		// Update the request
		now := time.Now()
		contactReq.Status = responseReq.Response
		contactReq.RespondedAt = &now

		// If accepted, create chat session
		if responseReq.Response == "accept" {
			chatSession := &ChatSession{
				ID:           uuid.New().String(),
				RequestID:    contactReq.ID,
				Participants: []string{contactReq.RequesterID, "jst"},
				Status:       "active",
				CreatedAt:    now,
			}

			c.mu.Lock()
			c.sessions[chatSession.ID] = chatSession
			contactReq.ChatSessionID = &chatSession.ID
			c.mu.Unlock()

			// Publish session creation
			sessionSubject := fmt.Sprintf("chat.room.%s", chatSession.ID)
			sessionData, _ := json.Marshal(chatSession)
			if err := c.nc.Publish(sessionSubject, sessionData); err != nil {
				c.l.Error("failed to publish session creation", "error", err, "session_id", chatSession.ID)
			}
		}

		// Publish updated request status
		subject := fmt.Sprintf("chat.request.%s", contactReq.ID)
		requestData, _ := json.Marshal(contactReq)
		if err := c.nc.Publish(subject, requestData); err != nil {
			c.l.Error("failed to publish updated request", "error", err, "request_id", contactReq.ID)
		}

		c.l.Info("contact request responded", "request_id", contactReq.ID, "response", responseReq.Response)

		// Return success
		if err := req.Respond([]byte("success")); err != nil {
			c.l.Error("failed to send response", "error", err)
		}
	}
}

// Handle chat message sending
func (c *Chat) handleChatMessageSend() micro.HandlerFunc {
	return func(req micro.Request) {
		var msgReq ChatMessageSend
		if err := json.Unmarshal(req.Data(), &msgReq); err != nil {
			c.l.Error("failed to unmarshal chat message", "error", err)
			if err := req.Error("400", fmt.Sprintf("failed to unmarshal request: %v", err), nil); err != nil {
				c.l.Error("failed to send error response", "error", err)
			}
			return
		}

		// Note: We don't need to validate session exists for MVP
		// Messages will be published to the subject regardless

		// Create chat message
		chatMsg := &ChatMessage{
			ID:          uuid.New().String(),
			SessionID:   msgReq.SessionID,
			SenderID:    msgReq.SenderID,
			Content:     msgReq.Content,
			Timestamp:   time.Now(),
			ClientMsgID: msgReq.ClientMsgID,
		}

		// Publish to chat room
		subject := fmt.Sprintf("chat.room.%s", msgReq.SessionID)
		msgData, _ := json.Marshal(chatMsg)
		if err := c.nc.Publish(subject, msgData); err != nil {
			c.l.Error("failed to publish chat message", "error", err, "session_id", msgReq.SessionID)
			if err := req.Error("500", "failed to publish message", nil); err != nil {
				c.l.Error("failed to send error response", "error", err)
			}
			return
		}

		c.l.Info("chat message sent", "session_id", msgReq.SessionID, "sender_id", msgReq.SenderID)

		// Return success
		if err := req.Respond([]byte("success")); err != nil {
			c.l.Error("failed to send response", "error", err)
		}
	}
}

// Get contact request by ID
func (c *Chat) GetContactRequest(id string) (*ContactRequest, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	req, exists := c.requests[id]
	return req, exists
}

// Get chat session by ID
func (c *Chat) GetChatSession(id string) (*ChatSession, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	chatSession, exists := c.sessions[id]
	return chatSession, exists
}