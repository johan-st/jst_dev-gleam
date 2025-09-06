package api

import (
	"encoding/json"
	"fmt"
	"jst_dev/server/jst_log"
	"strconv"
	"time"

	"github.com/google/uuid"
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
	Name   string   `json:"name"`
	Public bool     `json:"public"`
	Users  []string `json:"users"`
}

type Request struct {
	Id          string `json:"id"`
	From        string `json:"from"`
	To          string `json:"to"`
	Room        string `json:"room"`
	Message     string `json:"message"`
	TimestampMs int    `json:"timestamp_ms"`
}

type Message struct {
	Id          string `json:"id"`
	User        string `json:"user_id"`
	Room        string `json:"room_id"`
	Content     string `json:"content"`
	TimestampMs int    `json:"timestamp_ms"`
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
	uuid, err := uuid.NewRandom()
	if err != nil {
		return fmt.Errorf("failed to generate uuid: %w", err)
	}
	message.TimestampMs = (int)(time.Now().UnixMilli())
	timestampStr := strconv.Itoa(message.TimestampMs)
	headers := make(nats.Header)
	headers.Set("sender", message.User)
	headers.Set("room", message.Room)
	headers.Set("timestamp", timestampStr)
	headers.Set("id", uuid.String())

	message.Id = uuid.String()
	messageJson, err := json.Marshal(message)
	if err != nil {
		return fmt.Errorf("failed to marshal message: %w", err)
	}

	return nc.PublishMsg(&nats.Msg{
		Subject: messageJetStreamSubject + "." + message.Room,
		Data:    messageJson,
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
		message.Content = string(m.Data)
		message.Room = room
		message.User = m.Header.Get("user_id")
		ts, err := strconv.Atoi(m.Header.Get("timestamp_ms"))
		if err != nil {
			l.Error("failed to convert timestamp to int: %v", err)
			ts = 0
		}
		message.TimestampMs = ts

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
	Name   string   `json:"name"`
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
