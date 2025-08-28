package chat

import (
	"time"
)

// ContactRequest represents a contact request from a visitor
type ContactRequest struct {
	ID             string     `json:"id"`
	RequesterID    string     `json:"requester_id"`
	RequesterIP    string     `json:"requester_ip"`
	Status         string     `json:"status"` // pending, accepted, declined
	CreatedAt      time.Time  `json:"created_at"`
	RespondedAt    *time.Time `json:"responded_at,omitempty"`
	Response       string     `json:"response,omitempty"` // accept, busy
	ChatSessionID  *string    `json:"chat_session_id,omitempty"`
	ClientMsgID    string     `json:"client_msg_id"` // For frontend correlation
}

// ChatSession represents a chat session between parties
type ChatSession struct {
	ID           string    `json:"id"`
	RequestID    string    `json:"request_id"`
	Participants []string  `json:"participants"`
	Status       string    `json:"status"` // active, closed
	CreatedAt    time.Time `json:"created_at"`
	ClosedAt     *time.Time `json:"closed_at,omitempty"`
}

// ChatMessage represents a message in a chat session
type ChatMessage struct {
	ID           string    `json:"id"`
	SessionID    string    `json:"session_id"`
	SenderID     string    `json:"sender_id"`
	Content      string    `json:"content"`
	Timestamp    time.Time `json:"timestamp"`
	ClientMsgID  string    `json:"client_msg_id"` // For frontend correlation
}

// ContactRequestCreate represents the request to create a new contact request
type ContactRequestCreate struct {
	RequesterID string `json:"requester_id"`
	RequesterIP string `json:"requester_ip"`
	ClientMsgID string `json:"client_msg_id"`
}

// ContactRequestResponse represents the response to a contact request
type ContactRequestResponse struct {
	RequestID string `json:"request_id"`
	Response  string `json:"response"` // accept, busy
}

// ChatMessageSend represents a message to be sent to a chat session
type ChatMessageSend struct {
	SessionID   string `json:"session_id"`
	SenderID    string `json:"sender_id"`
	Content     string `json:"content"`
	ClientMsgID string `json:"client_msg_id"`
}