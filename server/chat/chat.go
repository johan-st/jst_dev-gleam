package chat

import (
	"context"
	"encoding/json"
	"fmt"
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
	js nats.JetStreamContext
}

func New(ctx context.Context, nc *nats.Conn, l *jst_log.Logger) (Chat, error) {
	if l == nil {
		return Chat{}, fmt.Errorf("logger is required")
	}

	js, err := nc.JetStream()
	if err != nil {
		return Chat{}, fmt.Errorf("failed to get jetstream: %w", err)
	}

	return Chat{
		nc: nc,
		l:  l,
		js: js,
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

		// Store in NATS KV
		kv, err := c.js.KeyValue("chat")
		if err != nil {
			c.l.Error("failed to get chat KV bucket", "error", err)
			if err := req.Error("500", "failed to store contact request", nil); err != nil {
				c.l.Error("failed to send error response", "error", err)
			}
			return
		}

		requestData, _ := json.Marshal(contactReq)
		if _, err := kv.Put(fmt.Sprintf("request.%s", contactReq.ID), requestData); err != nil {
			c.l.Error("failed to store contact request in KV", "error", err)
			if err := req.Error("500", "failed to store contact request", nil); err != nil {
				c.l.Error("failed to send error response", "error", err)
			}
			return
		}

		// Publish to chat.request.<request_id> for real-time updates
		subject := fmt.Sprintf("chat.request.%s", contactReq.ID)
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

		// Get the contact request from NATS KV
		kv, err := c.js.KeyValue("chat")
		if err != nil {
			c.l.Error("failed to get chat KV bucket", "error", err)
			if err := req.Error("500", "failed to get contact request", nil); err != nil {
				c.l.Error("failed to send error response", "error", err)
			}
			return
		}

		entry, err := kv.Get(fmt.Sprintf("request.%s", responseReq.RequestID))
		if err != nil || entry == nil {
			if err := req.Error("404", "contact request not found", nil); err != nil {
				c.l.Error("failed to send error response", "error", err)
			}
			return
		}

		var contactReq ContactRequest
		if err := json.Unmarshal(entry.Value(), &contactReq); err != nil {
			c.l.Error("failed to unmarshal contact request", "error", err)
			if err := req.Error("500", "failed to parse contact request", nil); err != nil {
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

			// Store session in NATS KV
			sessionData, _ := json.Marshal(chatSession)
			if _, err := kv.Put(fmt.Sprintf("session.%s", chatSession.ID), sessionData); err != nil {
				c.l.Error("failed to store chat session in KV", "error", err)
			}

			// Update contact request with session ID
			contactReq.ChatSessionID = &chatSession.ID
			if _, err := kv.Put(fmt.Sprintf("request.%s", contactReq.ID), sessionData); err != nil {
				c.l.Error("failed to update contact request in KV", "error", err)
			}

			// Publish session creation
			sessionSubject := fmt.Sprintf("chat.room.%s", chatSession.ID)
			if err := c.nc.Publish(sessionSubject, sessionData); err != nil {
				c.l.Error("failed to publish session creation", "error", err, "session_id", chatSession.ID)
			}
		}

		// Publish updated request status
		subject := fmt.Sprintf("chat.request.%s", contactReq.ID)
		updatedRequestData, _ := json.Marshal(contactReq)
		if err := c.nc.Publish(subject, updatedRequestData); err != nil {
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
	kv, err := c.js.KeyValue("chat")
	if err != nil {
		c.l.Error("failed to get chat KV bucket", "error", err)
		return nil, false
	}

	entry, err := kv.Get(fmt.Sprintf("request.%s", id))
	if err != nil || entry == nil {
		return nil, false
	}

	var req ContactRequest
	if err := json.Unmarshal(entry.Value(), &req); err != nil {
		c.l.Error("failed to unmarshal contact request", "error", err)
		return nil, false
	}

	return &req, true
}

// Get chat session by ID
func (c *Chat) GetChatSession(id string) (*ChatSession, bool) {
	kv, err := c.js.KeyValue("chat")
	if err != nil {
		c.l.Error("failed to get chat KV bucket", "error", err)
		return nil, false
	}

	entry, err := kv.Get(fmt.Sprintf("session.%s", id))
	if err != nil || entry == nil {
		return nil, false
	}

	var session ChatSession
	if err := json.Unmarshal(entry.Value(), &session); err != nil {
		c.l.Error("failed to unmarshal chat session", "error", err)
		return nil, false
	}

	return &session, true
}