package api

import (
	"fmt"
	"jst_dev/server/jst_log"
	"time"

	"github.com/nats-io/nats.go"
)

const (
	SubjConvoGroup    = "svc.convo"
	SubjRoomCreate    = "room.create"
	SubjRoomDelete    = "room.delete"
	SubjRoomJoin      = "room.join"
	SubjRoomLeave     = "room.leave"
	SubjRoomByUser    = "room.by_user"
	SubjRequestCreate = "request.create"
	SubjRequestReply  = "request.reply"
)

type Room struct {
	Id     string   `json:"id"`
	Public bool     `json:"public"`
	Users  []string `json:"users"`
}

type Request struct {
	Id        string    `json:"id"`
	From      string    `json:"from"`
	To        string    `json:"to"`
	Room      string    `json:"room"`
	Message   string    `json:"message"`
	Timestamp time.Time `json:"timestamp"`
}

type Message struct {
	User      string    `json:"user"`
	Room      string    `json:"room"`
	Content   string    `json:"content"`
	Timestamp time.Time `json:"timestamp"`
}

const (
	messageJetStreamSubject = "convo_message"
)

func MessagePub(nc *nats.Conn, message Message) error {
	if message.Room == "" {
		return fmt.Errorf("room is required")
	}
	if message.User == "" {
		return fmt.Errorf("user is required")
	}
	if message.Content == "" {
		return fmt.Errorf("content is required")
	}

	headers := make(nats.Header)
	headers.Set("sender", message.User)
	headers.Set("timestamp", message.Timestamp.Format(time.RFC3339))

	return nc.PublishMsg(&nats.Msg{
		Subject: messageJetStreamSubject + "." + message.Room,
		Data:    []byte(message.Content),
		Header:  headers,
	})
}

func MessageSub(nc *nats.Conn, l *jst_log.Logger, room string) (<-chan Message, func(), error) {
	var (
		msgChan = make(chan Message)
		err     error
		sub     *nats.Subscription
	)
	l.Debug("subscribing to messages from room: %s\n", room)
	sub, err = nc.Subscribe(messageJetStreamSubject+"."+room, func(m *nats.Msg) {
		var message Message
		l.Debug("got message: %+v\n", m)
		if sender := m.Header.Get("sender"); sender != "" {
			message.User = sender
			l.Debug("sender: %s\n", sender)
		}
		if timestampStr := m.Header.Get("timestamp"); timestampStr != "" {
			if timestamp, err := time.Parse(time.RFC3339, timestampStr); err == nil {
				message.Timestamp = timestamp
				l.Debug("timestamp: %s\n", timestampStr)
			}
		}
		message.Content = string(m.Data)
		message.Room = room

		l.Debug("sending message: %v\n", message)
		msgChan <- message
	})
	if err != nil {
		return nil, nil, fmt.Errorf("failed to subscribe to messages from room: %w", err)
	}
	return msgChan, func() {
		_ = sub.Unsubscribe()
	}, nil
}

// ROOM

type RoomCreateRequest struct {
	Public bool     `json:"public"`
	Users  []string `json:"users"`
}

type RoomCreateResponse struct {
	ID string `json:"id"`
}

type RoomGetByUserRequest struct {
	UserID string `json:"user_id"`
}

type RoomGetByUserResponse struct {
	Rooms []Room `json:"rooms"`
}

// REQUEST
// create

type RequestCreateRequest struct {
	RoomID  string `json:"room_id"`
	UserID  string `json:"user_id"`
	Message string `json:"message"`
}

type RequestCreateResponse struct {
	ID string `json:"id"`
}

//reply

type RequestStatus string

const (
	RequestStatusAccepted RequestStatus = "accepted"
	RequestStatusRejected RequestStatus = "rejected"
)

type RequestAction string

const (
	RequestActionAccept RequestAction = "accept"
	RequestActionReject RequestAction = "reject"
)

type RequestReplyRequest struct {
	RequestID  string        `json:"request_id"`
	UserIDFrom string        `json:"user_id_from"`
	UserIDTo   string        `json:"user_id_to"`
	RoomID     string        `json:"room_id"`
	Message    string        `json:"message"`
	Action     RequestAction `json:"action"` // "accept" or "reject"
}

type RequestReplyResponse struct {
	ID     string        `json:"id"`
	Status RequestStatus `json:"status"` // "accepted" or "rejected"
}
