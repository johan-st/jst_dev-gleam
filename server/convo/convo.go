// convo is the service that manages the conversation.
package convo

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/nats-io/nats.go/micro"

	"jst_dev/server/convo/api"
	"jst_dev/server/core"
	"jst_dev/server/jst_log"
	whoApi "jst_dev/server/who/api"
)

type Convo struct {
	roomRepo core.Repo[RoomRepoValue]
	ctx      context.Context
	nc       *nats.Conn
	l        *jst_log.Logger
}

func (c *Convo) Name() string {
	return "convo"
}

type Conf struct {
	Logger   *jst_log.Logger
	NatsConn *nats.Conn
}

// Helper functions to convert between old and new data types
func roomToRepoValue(room api.Room) RoomRepoValue {
	return RoomRepoValue{
		Room:     room,
		Revision: 0, // Will be set by the repo
	}
}

func repoValueToRoom(rv RoomRepoValue) api.Room {
	return rv.Room
}

func New(c *Conf) (core.Service, error) {
	if c.Logger == nil {
		return nil, fmt.Errorf("logger can not be nil")
	}
	if c.NatsConn == nil {
		return nil, fmt.Errorf("nats conn can not be nil")
	}

	return &Convo{
		nc: c.NatsConn,
		l:  c.Logger,
	}, nil
}

func (c *Convo) Run(ctx context.Context) error {
	// Initialize service (set up routes, endpoints, connections, etc.)
	if c.nc.Status() != nats.CONNECTED {
		return fmt.Errorf("nats connection not connected: %s", c.nc.Status())
	}
	if ctx == nil {
		return fmt.Errorf("context is nil")
	}
	c.ctx = ctx

	// Initialize room repository
	roomRepo, err := newRoomRepo(ctx, c.nc, c.l)
	if err != nil {
		return fmt.Errorf("failed to create room repo: %w", err)
	}
	c.roomRepo = roomRepo

	// Initialize JetStream for message streams
	js, err := jetstream.New(c.nc)
	if err != nil {
		return fmt.Errorf("failed to get JetStream context: %w", err)
	}

	// Create/Update stream for conversation messages per room: convo_message.<room>
	streamConf := jetstream.StreamConfig{
		Name:        "convo_message",
		Description: "conversation messages per room",
		Subjects:    []string{"convo_message.*"},
		Storage:     jetstream.FileStorage,
		MaxAge:      7 * 24 * time.Hour,
		MaxBytes:    1024 * 1024 * 50, // 50 MB
	}
	if _, err := js.CreateOrUpdateStream(ctx, streamConf); err != nil {
		return fmt.Errorf("create/update stream %s: %w", streamConf.Name, err)
	}

	svcMetadata := map[string]string{}
	svcMetadata["location"] = "unknown"
	svcMetadata["environment"] = "development"

	// start services
	convoSvc, err := micro.AddService(c.nc, micro.Config{
		Name:        "convo",
		Version:     "1.0.0",
		Description: "conversation service",
		Metadata:    svcMetadata,
	})
	if err != nil {
		return fmt.Errorf("add service: %w", err)
	}

	// ----------- Conversation Rooms -----------
	convoSvcGroup := convoSvc.AddGroup(api.SubjConvoGroup, micro.WithGroupQueueGroup(api.SubjConvoGroup))
	if err = convoSvcGroup.AddEndpoint("room_create", c.handleRoomCreate(), micro.WithEndpointSubject(api.SubjRoomCreate)); err != nil {
		return fmt.Errorf("add convo endpoint (%s): %w", api.SubjRoomCreate, err)
	}
	if err = convoSvcGroup.AddEndpoint("room_get_by_user", c.handleRoomGetByUser(), micro.WithEndpointSubject(api.SubjRoomByUser)); err != nil {
		return fmt.Errorf("add convo endpoint (%s): %w", api.SubjRoomByUser, err)
	}

	c.l.Info("service started")
	<-ctx.Done()
	c.l.Info("service stopping...")
	// Cleanup resources
	if err := convoSvc.Stop(); err != nil {
		c.l.Error("failed to stop convo service: %v", err)
	}

	c.l.Info("service stopped")
	return nil
}

// ----------- WATCHERS -----------
// NO WATCHERS FOR NOW, WE USE KV STORE FOR ROOMS AND MESSAGES

// ----------- HANDLERS -----------

func (c *Convo) handleRoomCreate() micro.HandlerFunc {
	return func(req micro.Request) {
		var (
			err      error
			reqData  api.RoomCreateRequest
			respData api.RoomCreateResponse
		)
		// guards and unmarshalling
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			c.l.Error("failed to unmarshal room create request: %v", err)
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				c.l.Error("failed to respond to room create request: %v", err)
			}
			return
		}
		if reqData.Users == nil {
			c.l.Error("users is nil")
			if err := req.Error("INVALID_REQUEST", "users is nil", []byte("users is nil")); err != nil {
				c.l.Error("failed to respond to room create request: %v", err)
			}
			return
		}
		if len(reqData.Users) == 0 {
			c.l.Error("users is empty")
			if err := req.Error("INVALID_REQUEST", "users is empty", []byte("users is empty")); err != nil {
				c.l.Error("failed to respond to room create request: %v", err)
			}
			return
		}
		// create room
		room, err := c.roomCreate(reqData.Users)
		if err != nil {
			c.l.Error("failed to create room: %v", err)
			if err := req.Error("SERVER_ERROR", "failed to create room", []byte(err.Error())); err != nil {
				c.l.Error("failed to respond to room create request: %v", err)
			}
			return
		}
		// respond
		respData.ID = room.Id
		respPayload, err := json.Marshal(respData)
		if err != nil {
			c.l.Error("failed to marshal response: %v", err)
			if err := req.Error("SERVER_ERROR", "failed to marshal response", []byte(err.Error())); err != nil {
				c.l.Error("failed to respond to room create request: %v", err)
			}
			return
		}
		if err := req.Respond(respPayload); err != nil {
			c.l.Error("failed to respond to room create request: %v", err)
		}
	}
}

func (c *Convo) handleRoomGetByUser() micro.HandlerFunc {
	return func(req micro.Request) {
		var (
			err      error
			reqData  api.RoomGetByUserRequest
			respData api.RoomGetByUserResponse
		)
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			c.l.Error("failed to unmarshal room get by user request: %v", err)
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				c.l.Error("failed to respond to room get by user request: %v", err)
			}
			return
		}
		if reqData.UserID == "" {
			c.l.Error("user id is empty")
			if err := req.Error("INVALID_REQUEST", "user id is empty", []byte("user id is empty")); err != nil {
				c.l.Error("failed to respond to room get by user request: %v", err)
			}
			return
		}
		rooms, err := c.roomGetByUser(reqData.UserID)
		if err != nil {
			c.l.Error("failed to get room by user: %v", err)
			if err := req.Error("SERVER_ERROR", "failed to get room by user", []byte(err.Error())); err != nil {
				c.l.Error("failed to respond to room get by user request: %v", err)
			}
			return
		}
		respData.Rooms = rooms
		respPayload, err := json.Marshal(respData)
		if err != nil {
			c.l.Error("failed to marshal response: %v", err)
			if err := req.Error("SERVER_ERROR", "failed to marshal response", []byte(err.Error())); err != nil {
				c.l.Error("failed to respond to room get by user request: %v", err)
			}
			return
		}
		if err := req.Respond(respPayload); err != nil {
			c.l.Error("failed to respond to room get by user request: %v", err)
		}
	}
}

// ----------- UTILITIES -----------

func (c *Convo) roomCreate(usersIds []string) (*api.Room, error) {
	room := &api.Room{
		Id:     uuid.New().String(),
		Public: true,
		Users:  []string{},
	}
	wg := sync.WaitGroup{}
	for _, userId := range usersIds {
		wg.Add(1)
		go func(c *Convo, userId string) {
			var (
				userResp whoApi.UserFullResponse
			)
			whoReq := whoApi.UserGetRequest{ID: userId}
			whoReqBytes, err := json.Marshal(whoReq)
			if err != nil {
				c.l.Error("failed to marshal who request: %v", err)
				return
			}
			msg, err := c.nc.Request(whoApi.Subj.UserGroup+"."+whoApi.Subj.UserGet, whoReqBytes, 5*time.Second)
			if err != nil {
				c.l.Error("failed to request who: %v", err)
				return
			}
			if err := json.Unmarshal(msg.Data, &userResp); err != nil {
				c.l.Error("failed to unmarshal who response: %v", err)
				return
			}
			room.Users = append(room.Users, userResp.ID)
			wg.Done()
		}(c, userId)
	}
	wg.Wait()
	// Convert to repo value and store
	roomRepoValue := roomToRepoValue(*room)
	err := c.roomRepo.Put(room.Id, roomRepoValue)
	if err != nil {
		return nil, fmt.Errorf("failed to put room in repo: %w", err)
	}
	c.l.Debug("room created %s", room.Id)

	return room, nil
}

func (c *Convo) roomGetByUser(userId string) ([]api.Room, error) {
	rooms := []api.Room{}
	keys, err := c.roomRepo.Keys()
	if err != nil {
		return nil, err
	}
	for key := range keys {
		roomRepoValue, err := c.roomRepo.Get(key)
		if err != nil {
			continue
		}
		room := repoValueToRoom(roomRepoValue)
		if slices.Contains(room.Users, userId) {
			rooms = append(rooms, room)
		}
	}
	return rooms, nil
}
