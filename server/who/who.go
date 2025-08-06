package who

import (
	"context"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"slices"
	"time"

	"github.com/golang-jwt/jwt"
	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/nats-io/nats.go/micro"

	"jst_dev/server/jst_log"
	"jst_dev/server/who/api"
)

type userKeyType struct{}

var UserKey = userKeyType{}

const jwtExpiresAfterTime = time.Hour * 12

var PermissionsAll = []api.Permission{
	api.PermissionPostEditAny,
}

type Who struct {
	users   []User
	l       *jst_log.Logger
	nc      *nats.Conn
	hash    hash.Hash
	secret  []byte
	usersKv jetstream.KeyValue
	ctx     context.Context
}

type User struct {
	api.User

	// private
	passwordHash string
	revision     uint64
}

type Conf struct {
	HashSalt  string
	JwtSecret []byte
	NatsConn  *nats.Conn
	Logger    *jst_log.Logger
}

// New creates a new Who service instance with the provided configuration.
// It validates the JWT secret length, initializes the password hash with a fixed salt, and sets up the service fields.
// Returns the initialized Who instance or an error if configuration is invalid.
func New(ctx context.Context, c *Conf) (*Who, error) {
	var (
		err  error
		hash hash.Hash
		who  *Who
	)

	if len(c.JwtSecret) < 12 {
		return nil, fmt.Errorf("jwt secret must be at least 12 characters")
	}

	hash = sha512.New()
	_, err = hash.Write([]byte(c.HashSalt))
	if err != nil {
		return nil, fmt.Errorf("failed to write hash salt: %w", err)
	}

	who = &Who{
		l:       c.Logger,
		nc:      c.NatsConn,
		ctx:     ctx,
		hash:    hash,
		users:   []User{},
		secret:  c.JwtSecret,
		usersKv: nil,
	}

	return who, nil
}

func (w *Who) Start(ctx context.Context) error {
	if w.nc.Status() != nats.CONNECTED {
		return fmt.Errorf("nats connection not connected: %s", w.nc.Status())
	}

	js, err := jetstream.New(w.nc)
	if err != nil {
		return fmt.Errorf("failed to get JetStream context: %w", err)
	}

	confKv := jetstream.KeyValueConfig{
		Bucket:       "who_users",
		Description:  "who users by id",
		Storage:      jetstream.FileStorage,
		MaxValueSize: 1024 * 1024 * 1,  // 1 MB
		MaxBytes:     1024 * 1024 * 50, // 50 MB,
		History:      64,
		Compression:  true,
	}
	kv, err := js.CreateOrUpdateKeyValue(w.ctx, confKv)
	if err != nil {
		w.l.Error(fmt.Sprintf("create users kv store %s:%s", confKv.Bucket, err.Error()))
		return fmt.Errorf("create users kv store %s:%w", confKv.Bucket, err)
	}
	w.usersKv = kv
	if err := w.userWatcher(); err != nil {
		return fmt.Errorf("failed to start user watcher: %w", err)
	}

	svcMetadata := map[string]string{}
	svcMetadata["location"] = "unknown"
	svcMetadata["environment"] = "development"
	whoSvc, err := micro.AddService(w.nc, micro.Config{
		Name:        "who",
		Version:     "1.0.0",
		Description: "auth n auth, user management",
		Metadata:    svcMetadata,
	})
	if err != nil {
		return fmt.Errorf("add service: %w", err)
	}

	// ----------- Users -----------
	userSvcGroup := whoSvc.AddGroup(api.Subj.UserGroup, micro.WithGroupQueueGroup(api.Subj.UserGroup))
	if err = userSvcGroup.AddEndpoint("user_create", w.handleUserCreate(), micro.WithEndpointSubject(api.Subj.UserCreate)); err != nil {
		return fmt.Errorf("add users endpoint (user_create): %w", err)
	}
	if err = userSvcGroup.AddEndpoint("user_get", w.handleUserGet(), micro.WithEndpointSubject(api.Subj.UserGet)); err != nil {
		return fmt.Errorf("add users endpoint (user_get): %w", err)
	}
	if err = userSvcGroup.AddEndpoint("user_update", w.handleUserUpdate(), micro.WithEndpointSubject(api.Subj.UserUpdate)); err != nil {
		return fmt.Errorf("add users endpoint (user_update): %w", err)
	}
	if err = userSvcGroup.AddEndpoint("user_delete", w.handleUserDelete(), micro.WithEndpointSubject(api.Subj.UserDelete)); err != nil {
		return fmt.Errorf("add users endpoint (user_delete): %w", err)
	}

	// ----------- Permissions -----------
	permissionsSvcGroup := whoSvc.AddGroup(api.Subj.PermissionsGroup, micro.WithGroupQueueGroup(api.Subj.PermissionsGroup))
	if err = permissionsSvcGroup.AddEndpoint("permission_list", w.handlePermissionsList(), micro.WithEndpointSubject(api.Subj.PermissionsList)); err != nil {
		return fmt.Errorf("add permissions endpoint (permission_list): %w", err)
	}
	if err = permissionsSvcGroup.AddEndpoint("permission_grant", w.handlePermissionsGrant(), micro.WithEndpointSubject(api.Subj.PermissionsGrant)); err != nil {
		return fmt.Errorf("add permissions endpoint (permission_grant): %w", err)
	}
	if err = permissionsSvcGroup.AddEndpoint("permission_revoke", w.handlePermissionsRevoke(), micro.WithEndpointSubject(api.Subj.PermissionsRevoke)); err != nil {
		return fmt.Errorf("add permissions endpoint (permission_revoke): %w", err)
	}
	if err = permissionsSvcGroup.AddEndpoint("permission_check", w.handlePermissionsCheck(), micro.WithEndpointSubject(api.Subj.PermissionsCheck)); err != nil {
		return fmt.Errorf("add permissions endpoint (permission_check): %w", err)
	}

	// ----------- Auth -----------
	authSvcGroup := whoSvc.AddGroup(api.Subj.AuthGroup, micro.WithGroupQueueGroup(api.Subj.AuthGroup))
	if err = authSvcGroup.AddEndpoint("auth_login", w.handleAuth(), micro.WithEndpointSubject(api.Subj.AuthLogin)); err != nil {
		return fmt.Errorf("add auth endpoint (auth_login): %w", err)
	}
	return nil
}

// ----------- WATCHERS -----------

func (w *Who) userWatcher() error {
	var (
		watcher jetstream.KeyWatcher
		err     error
		kv      jetstream.KeyValueEntry
		user    User
	)

	// Store the context in the Who struct
	w.ctx = context.Background()

	watcher, err = w.usersKv.WatchAll(w.ctx)
	if err != nil {
		return fmt.Errorf("failed to watch users: %w", err)
	}

	go func() {
		for {
			select {
			case kv = <-watcher.Updates():
				if kv == nil {
					w.l.Info("up to date. %d users loaded", len(w.users))
					continue
				}
				switch kv.Operation() {
				case jetstream.KeyValuePut:
					err = json.Unmarshal(kv.Value(), &user)
					if err != nil {
						w.l.Error("failed to unmarshal user: %s", err.Error())
						continue
					}
					found := false
					for i, existingUser := range w.users {
						if existingUser.ID == user.ID {
							w.users[i] = user
							found = true
							w.l.Debug("updated user(%s). %d users loaded", user.ID, len(w.users))
							break
						}
					}
					if !found {
						w.users = append(w.users, user)
						w.l.Debug("new user(%s). %d users loaded", user.ID, len(w.users))
					}
				case jetstream.KeyValueDelete:
					for i, existingUser := range w.users {
						if existingUser.ID == kv.Key() {
							w.users = append(w.users[:i], w.users[i+1:]...)
							w.l.Debug("deleted user(%s). %d users loaded", kv.Key(), len(w.users))
							break
						}
					}
				default:
					w.l.Error("unknown operation: %s", kv.Operation())
				}
			case <-w.ctx.Done():
				w.l.Debug("watcher: context done")
				return
			}
		}
	}()

	return nil
}

// ----------- HANDLERS -----------
// - Users

func (w *Who) handleUserCreate() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("user_create")
	return func(req micro.Request) {
		var (
			err      error
			user     *User
			reqData  api.UserCreateRequest
			respData api.UserFullResponse
		)

		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal user create request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to user create request: %v", err)
			}
			return
		}
		if reqData.Username == "" {
			l.Warn("username is empty")
			if err := req.Error("INVALID_REQUEST", "username is empty", []byte("username is empty")); err != nil {
				l.Error("failed to respond to user create request: %v", err)
			}
			return
		}
		if reqData.Email == "" {
			l.Warn("email is empty")
			if err := req.Error("INVALID_REQUEST", "email is empty", []byte("email is empty")); err != nil {
				l.Error("failed to respond to user create request: %v", err)
			}
			return
		}
		if reqData.Password == "" {
			l.Warn("password is empty")
			if err := req.Error("INVALID_REQUEST", "password is empty", []byte("password is empty")); err != nil {
				l.Error("failed to respond to user create request: %v", err)
			}
			return
		}
		user = w.userByEmail(reqData.Email)
		if user != nil {
			l.Warn("user already exists")
			if err := req.Error("EMAIL_TAKEN", "a user with this email already exists", []byte(reqData.Email)); err != nil {
				l.Error("failed to respond to user create request: %v", err)
			}
			return
		}
		user = w.userByUsername(reqData.Username)
		if user != nil {
			l.Warn("user already exists")
			if err := req.Error("USERNAME_TAKEN", "a user with this username already exists", []byte(reqData.Username)); err != nil {
				l.Error("failed to respond to user create request: %v", err)
			}
			return
		}

		user, err = w.userCreate(reqData.Username, reqData.Email, reqData.Password)
		if err != nil {
			l.Error(fmt.Sprintf("failed to create user: %s", err.Error()))
			if err := req.Error("SERVER_ERROR", "server error", []byte(err.Error())); err != nil {
				l.Error("failed to respond to user create request: %v", err)
			}
			return
		}

		w.users = append(w.users, *user)
		respData = api.UserFullResponse{
			ID:          user.ID,
			Username:    user.Username,
			Email:       user.Email,
			Permissions: user.Permissions,
		}
		if err := req.RespondJSON(respData); err != nil {
			l.Error("failed to respond to user create request: %v", err)
		}
	}
}

func (w *Who) handleUserGet() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("user_get")

	return func(req micro.Request) {
		var (
			reqData  api.UserGetRequest
			respData api.UserFullResponse
			err      error
			user     *User
		)
		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal user get request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to user get request: %v", err)
			}
			return
		}
		if reqData.ID == "" && reqData.Username == "" && reqData.Email == "" {
			l.Warn("no id, username, or email provided")
			if err := req.Error("INVALID_REQUEST", "no id, username, or email provided", []byte("no id, username, or email provided")); err != nil {
				l.Error("failed to respond to user get request: %v", err)
			}
			return
		}
		if reqData.ID != "" {
			user = w.userGet(reqData.ID)
			if user == nil {
				l.Warn(fmt.Sprintf("error getting user: %s", err.Error()))
				if err := req.Error("SERVER_ERROR", "server error while getting user", []byte(err.Error())); err != nil {
					l.Error("failed to respond to user get request: %v", err)
				}
				return
			}
		} else if reqData.Email != "" {
			user = w.userByEmail(reqData.Email)
			if user == nil {
				l.Warn(fmt.Sprintf("user not found: %s", reqData.Email))
				if err := req.Error("USER_NOT_FOUND", "user not found", []byte(reqData.Email)); err != nil {
					l.Error("failed to respond to user get request: %v", err)
				}
				return
			}
		} else if reqData.Username != "" {
			user = w.userByUsername(reqData.Username)
			if user == nil {
				l.Warn(fmt.Sprintf("user not found: %s", reqData.Username))
				if err := req.Error("USER_NOT_FOUND", "user not found", []byte(reqData.Username)); err != nil {
					l.Error("failed to respond to user get request: %v", err)
				}
				return
			}
		}

		if err != nil {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.ID))
			if err := req.Error("USER_NOT_FOUND", "user not found", []byte(reqData.ID)); err != nil {
				l.Error("failed to respond to user get request: %v", err)
			}
			return
		}
		respData = api.UserFullResponse{
			ID:          user.ID,
			Username:    user.Username,
			Email:       user.Email,
			Permissions: user.Permissions,
		}
		if err := req.RespondJSON(respData); err != nil {
			l.Error("failed to respond to user get request: %v", err)
		}
	}
}

func (w *Who) handleUserUpdate() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("user_update")
	return func(req micro.Request) {
		var (
			err             error
			user            *User
			reqData         api.UserUpdateRequest
			respData        api.UserUpdateResponse
			passwordChanged bool = false
			passwordHash    []byte
			userBytes       []byte
			rev             uint64
		)

		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal user update request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to user update request: %v", err)
			}
			return
		}
		user = w.userGet(reqData.ID)
		if user == nil {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.ID))
			if err := req.Error("NOT_FOUND", "user not found", []byte(reqData.ID)); err != nil {
				l.Error("failed to respond to user update request: %v", err)
			}
			return
		}

		// TODO: validate data before updating
		if reqData.Username != "" {
			user.Username = reqData.Username
		}
		if reqData.Email != "" {
			user.Email = reqData.Email
		}
		if reqData.Password != "" {
			passwordChanged = true
			passwordHash = w.hash.Sum([]byte(reqData.Password))
			user.passwordHash = hex.EncodeToString(passwordHash)
		}

		userBytes, err = json.Marshal(user)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to marshal user: %s", err.Error()))
			if err := req.Error("SERVER_ERROR", "server error while updating user", []byte(err.Error())); err != nil {
				l.Error("failed to respond to user update request: %v", err)
			}
			return
		}
		rev, err = w.usersKv.Put(w.ctx, user.ID, userBytes)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to update user: %s", err.Error()))
			if err := req.Error("SERVER_ERROR", "server error while updating user", []byte(err.Error())); err != nil {
				l.Error("failed to respond to user update request: %v", err)
			}
			return
		}
		user.revision = rev
		respData = api.UserUpdateResponse{
			ID:              user.ID,
			Username:        user.Username,
			Email:           user.Email,
			PasswordChanged: passwordChanged,
		}
		if err := req.RespondJSON(respData); err != nil {
			l.Error("failed to respond to user update request: %v", err)
		}
	}
}

func (w *Who) handleUserDelete() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("user_delete")
	return func(req micro.Request) {
		var (
			err      error
			user     *User
			reqData  api.UserDeleteRequest
			respData api.UserDeleteResponse
		)
		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal user delete request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to user delete request: %v", err)
			}
			return
		}
		user = w.userGet(reqData.ID)
		if user == nil {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.ID))
			if err := req.Error("NOT_FOUND", "user not found and could thus not be deleted", []byte(reqData.ID)); err != nil {
				l.Error("failed to respond to user delete request: %v", err)
			}
			return
		}
		err = w.usersKv.Delete(w.ctx, user.ID)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to delete user: %s", err.Error()))
			if err := req.Error("SERVER_ERROR", "server error while deleting user", []byte(err.Error())); err != nil {
				l.Error("failed to respond to user delete request: %v", err)
			}
			return
		}
		respData = api.UserDeleteResponse{
			IdDeleted: user.ID,
		}
		if err := req.RespondJSON(respData); err != nil {
			l.Error("failed to respond to user delete request: %v", err)
		}
	}
}

// - Permissions

func (w *Who) handlePermissionsList() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("permissions_list")
	permissions := []api.Permission{
		api.PermissionPostEditAny,
	}
	return func(req micro.Request) {
		var (
			respData api.PermissionsListResponse
		)
		l.Debug("got request")
		respData = api.PermissionsListResponse{
			Permissions: permissions,
		}
		if err := req.RespondJSON(respData); err != nil {
			l.Error("failed to respond to permissions list request: %v", err)
		}
	}
}

func (w *Who) handlePermissionsGrant() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("permissions_grant")
	return func(req micro.Request) {
		var (
			err         error
			user        *User
			reqData     api.PermissionsGrantRequest
			respData    api.PermissionsGrantResponse
			permAdded   = []api.Permission{}
			permExisted = []api.Permission{}
		)
		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal permissions grant request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to permissions grant request: %v", err)
			}
			return
		}
		user = w.userGet(reqData.ID)
		if user == nil {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.ID))
			if err := req.Error("NOT_FOUND", "user not found and could thus not be granted permission", []byte(reqData.ID)); err != nil {
				l.Error("failed to respond to permissions grant request: %v", err)
			}
			return
		}
		for _, perm := range reqData.Permissions {
			updated, err := w.userAddPermission(user, perm)
			if err != nil {
				l.Warn(fmt.Sprintf("failed to add permission: %s", err.Error()))
				if err := req.Error("OPERATION_FAILED", "the operation failed to complete", []byte(err.Error())); err != nil {
					l.Error("failed to respond to permissions grant request: %v", err)
				}
				return
			}
			if updated {
				permAdded = append(permAdded, perm)
			} else {
				permExisted = append(permExisted, perm)
			}
		}
		respData = api.PermissionsGrantResponse{
			ID:      user.ID,
			Added:   permAdded,
			Existed: permExisted,
		}
		if err := req.RespondJSON(respData); err != nil {
			l.Error("failed to respond to permissions grant request: %v", err)
		}
	}
}

func (w *Who) handlePermissionsRevoke() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("permissions_revoke")
	return func(req micro.Request) {
		var (
			err         error
			user        *User
			reqData     api.PermissionsRevokeRequest
			respData    api.PermissionsRevokeResponse
			permRemoved = []api.Permission{}
			permMissing = []api.Permission{}
		)
		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal permissions revoke request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to permissions revoke request: %v", err)
			}
			return
		}
		user = w.userGet(reqData.ID)
		if user == nil {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.ID))
			if err := req.Error("NOT_FOUND", "user not found and could thus not be revoked permission", []byte(reqData.ID)); err != nil {
				l.Error("failed to respond to permissions revoke request: %v", err)
			}
			return
		}
		for _, perm := range reqData.Permissions {
			removed, err := w.userRemovePermission(user, perm)
			if err != nil {
				l.Warn(fmt.Sprintf("failed to remove permission: %s", err.Error()))
				if err := req.Error("OPERATION_FAILED", "the operation failed to complete", []byte(err.Error())); err != nil {
					l.Error("failed to respond to permissions revoke request: %v", err)
				}
				return
			}
			if removed {
				permRemoved = append(permRemoved, perm)
			} else {
				permMissing = append(permMissing, perm)
			}
		}
		respData = api.PermissionsRevokeResponse{
			ID:      user.ID,
			Removed: permRemoved,
			Missing: permMissing,
		}
		if err := req.RespondJSON(respData); err != nil {
			l.Error("failed to respond to permissions revoke request: %v", err)
		}
	}
}

func (w *Who) handlePermissionsCheck() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("permissions_check")
	return func(req micro.Request) {
		var (
			err         error
			reqData     api.PermissionsCheckRequest
			respData    api.PermissionsCheckResponse
			user        *User
			permGranted = []api.Permission{}
			permMissing = []api.Permission{}
		)

		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal permissions check request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to permissions check request: %v", err)
			}
			return
		}
		user = w.userGet(reqData.ID)
		if user == nil {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.ID))
			if err := req.Error("NOT_FOUND", "user not found", []byte(reqData.ID)); err != nil {
				l.Error("failed to respond to permissions check request: %v", err)
			}
			return
		}
		for _, perm := range reqData.Permissions {
			if w.permGranted(user, []api.Permission{perm}) {
				permGranted = append(permGranted, perm)
			} else {
				permMissing = append(permMissing, perm)
			}
		}
		respData = api.PermissionsCheckResponse{
			ID:          user.ID,
			Permissions: reqData.Permissions,
			AllGranted:  len(permMissing) == 0,
			Granted:     permGranted,
			Missing:     permMissing,
		}
		if err := req.RespondJSON(respData); err != nil {
			l.Error("failed to respond to permissions check request: %v", err)
		}
	}
}

// - Auth

func (w *Who) handleAuth() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("auth")
	return func(req micro.Request) {
		var (
			err      error
			user     *User
			token    string
			reqData  api.AuthRequest
			respData api.AuthResponse
		)

		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal auth request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to auth request: %v", err)
			}
			return
		}
		if reqData.Username == "" && reqData.Email == "" {
			l.Warn("username and email are empty")
			if err := req.Error("INVALID_REQUEST", "username and email are empty", []byte("username and email are empty")); err != nil {
				l.Error("failed to respond to auth request: %v", err)
			}
			return
		}

		if reqData.Email != "" {
			user = w.userByEmail(reqData.Email)
		}
		if user == nil && reqData.Username != "" {
			user = w.userByUsername(reqData.Username)
		}
		if user == nil {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.Username))
			if err := req.Error("NOT_FOUND", "user not found", []byte(reqData.Username)); err != nil {
				l.Error("failed to respond to auth request: %v", err)
			}
			return
		}

		token, err = w.userJwt(user)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to create token: %s", err.Error()))
			if err := req.Error("OPERATION_FAILED", "the operation failed to complete", []byte(err.Error())); err != nil {
				l.Error("failed to respond to auth request: %v", err)
			}
			return
		}
		l.Debug("got token %s", token)
		respData = api.AuthResponse{
			Token:     token,
			ExpiresAt: time.Now().Add(jwtExpiresAfterTime).Unix(),
		}
		if err := req.RespondJSON(respData); err != nil {
			l.Error("failed to respond to auth request: %v", err)
		}
	}
}

// ----------- Helper Functions -----------

func (w *Who) userCreate(username, email, password string) (*User, error) {
	var (
		err          error
		user         *User
		userBytes    []byte
		passwordHash []byte
		rev          uint64
	)

	if username == "" || email == "" || password == "" {
		return nil, fmt.Errorf("username, email and password are required")
	}

	passwordHash = w.hash.Sum([]byte(password))
	user = &User{
		User: api.User{
			Version:     1,
			ID:          uuid.New().String(),
			Username:    username,
			Email:       email,
			Permissions: []api.Permission{},
		},
		passwordHash: hex.EncodeToString(passwordHash),
	}
	userBytes, err = json.Marshal(user)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal user: %w", err)
	}
	rev, err = w.usersKv.Create(w.ctx, user.ID, userBytes)
	if err != nil {
		return nil, fmt.Errorf("failed to put user in kv: %w", err)
	}
	w.l.Debug("user created %s, rev %d", user.Email, rev)
	return user, nil
}

func (w *Who) userGet(id string) *User {
	for _, user := range w.users {
		if user.ID == id {
			return &user
		}
	}
	return nil
}
func (w *Who) userByUsername(username string) *User {
	for _, user := range w.users {
		if user.Username == username {
			return &user
		}
	}
	return nil
}
func (w *Who) userByEmail(email string) *User {
	for _, user := range w.users {
		if user.Email == email {
			return &user
		}
	}
	return nil
}

func (w *Who) permGranted(user *User, perms []api.Permission) bool {
	for _, perm := range perms {
		if !slices.Contains(user.Permissions, perm) {
			return false
		}
	}
	return true
}

func (w *Who) userAddPermission(user *User, perm api.Permission) (bool, error) {
	var (
		err       error
		userBytes []byte
		rev       uint64
	)

	if !slices.Contains(PermissionsAll, perm) {
		return false, fmt.Errorf("permission %s is not a valid permission", perm)
	}
	if w.permGranted(user, []api.Permission{perm}) {
		return false, nil
	}
	user.Permissions = append(user.Permissions, perm)

	// Persist the updated user to KV store
	userBytes, err = json.Marshal(user)
	if err != nil {
		return false, fmt.Errorf("failed to marshal user: %w", err)
	}
	rev, err = w.usersKv.Put(w.ctx, user.ID, userBytes)
	if err != nil {
		return false, fmt.Errorf("failed to update user in KV store: %w", err)
	}
	user.revision = rev

	return true, nil
}

func (w *Who) userRemovePermission(user *User, perm api.Permission) (bool, error) {
	var (
		err       error
		userBytes []byte
		rev       uint64
	)

	if !slices.Contains(PermissionsAll, perm) {
		return false, fmt.Errorf("permission %s is not a valid permission", perm)
	}
	if !w.permGranted(user, []api.Permission{perm}) {
		return false, nil
	}

	user.Permissions = slices.DeleteFunc(user.Permissions, func(p api.Permission) bool {
		return p == perm
	})

	// Persist the updated user to KV store
	userBytes, err = json.Marshal(user)
	if err != nil {
		return false, fmt.Errorf("failed to marshal user: %w", err)
	}
	rev, err = w.usersKv.Put(w.ctx, user.ID, userBytes)
	if err != nil {
		return false, fmt.Errorf("failed to update user in KV store: %w", err)
	}
	user.revision = rev

	return true, nil
}

// ----------- JWT -----------

func (w *Who) userJwt(user *User) (string, error) {
	var (
		err          error
		token        *jwt.Token
		signedSecret string
		claims       api.JwtClaims
	)
	// Create the Claims
	claims = api.JwtClaims{
		Permissions: user.Permissions,
		StandardClaims: jwt.StandardClaims{
			Audience:  "jst_dev.who, jst_dev.blog, jst_dev.web",
			ExpiresAt: time.Now().Add(jwtExpiresAfterTime).Unix(),
			Issuer:    "jst_dev.who",
			Subject:   user.ID,
			IssuedAt:  time.Now().Unix(),
		},
	}

	// TODO: Consider signingmethod with a public/private key pair
	token = jwt.NewWithClaims(jwt.SigningMethodHS512, claims)
	signedSecret, err = token.SignedString(w.secret)
	if err != nil {
		return "", err
	}
	return signedSecret, nil
}
