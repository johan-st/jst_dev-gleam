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
	"github.com/nats-io/nats.go/micro"

	"jst_dev/server/core"
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
	userRepo core.Repo[UserRepoKey, UserRepoValue]
	l        *jst_log.Logger
	nc       *nats.Conn
	hash     hash.Hash
	secret   []byte
	ctx      context.Context
}

// userStorage is the JSON representation persisted in KV. It mirrors User but
// uses exported fields so encoding/json includes them.
type userStorage struct {
	api.User
	PasswordHash string `json:"passwordHash"`
	Revision     uint64 `json:"revision"`
}

// Helper functions to convert between old and new data types
func userStorageToRepoValue(us userStorage) UserRepoValue {
	return UserRepoValue(us)
}

func repoValueToUserStorage(rv UserRepoValue) userStorage {
	return userStorage(rv)
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

	// Initialize user repository
	userRepo, err := NewUserRepo(ctx, c.NatsConn, c.Logger)
	if err != nil {
		return nil, fmt.Errorf("failed to create user repo: %w", err)
	}

	who = &Who{
		userRepo: userRepo,
		l:        c.Logger,
		nc:       c.NatsConn,
		ctx:      ctx,
		hash:     hash,
		secret:   c.JwtSecret,
	}

	return who, nil
}

// Run implements the service.Service interface
// The service runs until the context is cancelled, then performs cleanup
func (w *Who) Run(ctx context.Context) error {
	if w.nc.Status() != nats.CONNECTED {
		return fmt.Errorf("nats connection not connected: %s", w.nc.Status())
	}

	// User repository is already initialized in New()

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
	if err = authSvcGroup.AddEndpoint("auth_refresh", w.handleAuthRefresh(), micro.WithEndpointSubject(api.Subj.AuthRefresh)); err != nil {
		return fmt.Errorf("add auth endpoint (auth_refresh): %w", err)
	}

	w.l.Info("who service started")

	// Wait for context cancellation
	<-ctx.Done()

	// Cleanup
	w.l.Info("who service stopping...")
	if err := whoSvc.Stop(); err != nil {
		w.l.Error("failed to stop who service: %v", err)
	}

	w.l.Info("who service stopped")
	return nil
}

// Name returns the service name for identification
func (w *Who) Name() string {
	return "who"
}

// Start is deprecated - use Run instead
func (w *Who) Start(ctx context.Context) error {
	return w.Run(ctx)
}

// ----------- WATCHERS -----------

// userWatcher removed - repository handles watching automatically

// ----------- HANDLERS -----------
// - Users

func (w *Who) handleUserCreate() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("user_create")
	return func(req micro.Request) {
		var (
			err      error
			user     *userStorage
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

		// User is already stored in the repository
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
			user     *userStorage
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
				l.Warn(fmt.Sprintf("error getting user with id: %s", reqData.ID))
				if err := req.Error("SERVER_ERROR", "server error while getting user", []byte("error getting user with id: "+reqData.ID)); err != nil {
					l.Error("failed to respond to user get request: %v", err)
				}
				return
			}
		} else if reqData.Email != "" {
			user = w.userByEmail(reqData.Email)
			if user == nil {
				l.Warn(fmt.Sprintf("error getting user with email: %s", reqData.Email))
				if err := req.Error("USER_NOT_FOUND", "user not found", []byte("error getting user with email: "+reqData.Email)); err != nil {
					l.Error("failed to respond to user get request: %v", err)
				}
				return
			}
		} else if reqData.Username != "" {
			user = w.userByUsername(reqData.Username)
			if user == nil {
				l.Warn(fmt.Sprintf("error getting user with username: %s", reqData.Username))
				if err := req.Error("USER_NOT_FOUND", "user not found", []byte("error getting user with username: "+reqData.Username)); err != nil {
					l.Error("failed to respond to user get request: %v", err)
				}
				return
			}
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
			user            *userStorage
			reqData         api.UserUpdateRequest
			respData        api.UserUpdateResponse
			passwordChanged bool = false
			passwordHash    []byte
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
			// Require old password to be provided and correct
			if reqData.OldPassword == "" {
				l.Warn("password update denied: missing old password")
				if err := req.Error("FORBIDDEN", "old password required", nil); err != nil {
					l.Error("failed to respond to user update request: %v", err)
				}
				return
			}
			// Verify old password
			oldHash := w.hash.Sum([]byte(reqData.OldPassword))
			if user.PasswordHash != hex.EncodeToString(oldHash) {
				l.Warn("password update denied: old password mismatch")
				if err := req.Error("FORBIDDEN", "old password incorrect", nil); err != nil {
					l.Error("failed to respond to user update request: %v", err)
				}
				return
			}

			passwordChanged = true
			passwordHash = w.hash.Sum([]byte(reqData.Password))
			user.PasswordHash = hex.EncodeToString(passwordHash)
		}

		err = w.userUpdate(user)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to update user: %s", err.Error()))
			if err := req.Error("SERVER_ERROR", "server error while updating user", []byte(err.Error())); err != nil {
				l.Error("failed to respond to user update request: %v", err)
			}
			return
		}
		// Get updated user to get the new revision
		updatedUser := w.userGet(user.ID)
		if updatedUser != nil {
			rev = updatedUser.Revision
		}
		respData = api.UserUpdateResponse{
			ID:              user.ID,
			Revision:        rev,
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
			user     *userStorage
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
		key := UserRepoKey{ID: user.ID}
		err = w.userRepo.Delete(key)
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
			user        *userStorage
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
			user        *userStorage
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
			user        *userStorage
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
			user     *userStorage
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
		l.Debug("reqData: %+v", reqData)
		if reqData.Username == "" && reqData.Email == "" {
			l.Warn("username and email are empty")
			if err := req.Error("INVALID_REQUEST", "username and email are empty", []byte("username and email are empty")); err != nil {
				l.Error("failed to respond to auth request: %v", err)
			}
			return
		}
		l.Debug("got username or email")
		if reqData.Password == "" {
			l.Warn("password empty for user %s", reqData.Username)
			if err := req.Error("INVALID_REQUEST", "password required", nil); err != nil {
				l.Error("failed to respond to auth request: %v", err)
			}
			return
		}
		l.Debug("password not empty")
		if reqData.Email != "" {
			user = w.userByEmail(reqData.Email)
			if user != nil {
				l.Debug("user found by email: %s", user.Email)
			} else {
				l.Debug("no user found by email: %s", reqData.Email)
			}
		}
		if user == nil && reqData.Username != "" {
			user = w.userByUsername(reqData.Username)
			if user != nil {
				l.Debug("user found by username: %s", user.Username)
			} else {
				l.Debug("no user found by username: %s", reqData.Username)
			}
		}
		if user == nil {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.Username))
			if err := req.Error("NOT_FOUND", "user not found", []byte(reqData.Username)); err != nil {
				l.Error("failed to respond to auth request: %v", err)
			}
			return
		}
		l.Debug("user found: %+v", user)
		providedHash := w.hash.Sum([]byte(reqData.Password))
		if user.PasswordHash != hex.EncodeToString(providedHash) {
			l.Warn("invalid credentials for user %s", user.Email)
			if err := req.Error("UNAUTHORIZED", "invalid credentials", nil); err != nil {
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
			Subject:     user.ID,
			Token:       token,
			ExpiresAt:   time.Now().Add(jwtExpiresAfterTime).Unix(),
			Permissions: user.Permissions,
		}
		if err := req.RespondJSON(respData); err != nil {
			l.Error("failed to respond to auth request: %v", err)
		}
	}
}

// handleAuthRefresh refreshes a JWT for an already authenticated subject (user ID).
// It does not change permissions, only re-signs a new token with updated expiry.
func (w *Who) handleAuthRefresh() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("auth_refresh")
	return func(req micro.Request) {
		var (
			err      error
			user     *userStorage
			token    string
			reqData  api.AuthRefreshRequest
			respData api.AuthResponse
		)

		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal auth refresh request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to auth refresh request: %v", err)
			}
			return
		}
		if reqData.Subject == "" {
			l.Warn("subject is empty")
			if err := req.Error("INVALID_REQUEST", "subject is empty", []byte("subject is empty")); err != nil {
				l.Error("failed to respond to auth refresh request: %v", err)
			}
			return
		}

		user = w.userGet(reqData.Subject)
		if user == nil {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.Subject))
			if err := req.Error("NOT_FOUND", "user not found", []byte(reqData.Subject)); err != nil {
				l.Error("failed to respond to auth refresh request: %v", err)
			}
			return
		}

		token, err = w.userJwt(user)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to create token: %s", err.Error()))
			if err := req.Error("OPERATION_FAILED", "the operation failed to complete", []byte(err.Error())); err != nil {
				l.Error("failed to respond to auth refresh request: %v", err)
			}
			return
		}
		respData = api.AuthResponse{
			Token:       token,
			ExpiresAt:   time.Now().Add(jwtExpiresAfterTime).Unix(),
			Permissions: user.Permissions,
		}
		if err := req.RespondJSON(respData); err != nil {
			l.Error("failed to respond to auth refresh request: %v", err)
		}
	}
}

// ----------- Helper Functions -----------

func (w *Who) userCreate(username, email, password string) (*userStorage, error) {
	var (
		err           error
		passwordHash  []byte
		userRepoValue UserRepoValue
	)

	if username == "" || email == "" || password == "" {
		return nil, fmt.Errorf("username, email and password are required")
	}

	passwordHash = w.hash.Sum([]byte(password))
	userRepoValue = UserRepoValue{
		User: api.User{
			Version:     1,
			ID:          uuid.New().String(),
			Username:    username,
			Email:       email,
			Permissions: []api.Permission{},
		},
		PasswordHash: hex.EncodeToString(passwordHash),
		Revision:     0, // Will be set by the repo
	}

	key := UserRepoKey{ID: userRepoValue.ID}
	err = w.userRepo.Put(key, userRepoValue)
	if err != nil {
		return nil, fmt.Errorf("failed to put user in repo: %w", err)
	}
	w.l.Debug("user created %s", userRepoValue.Email)

	// Convert back to userStorage for compatibility
	user := repoValueToUserStorage(userRepoValue)
	return &user, nil
}

func (w *Who) userUpdate(user *userStorage) error {
	userRepoValue := userStorageToRepoValue(*user)
	key := UserRepoKey{ID: user.ID}
	err := w.userRepo.Put(key, userRepoValue)
	if err != nil {
		return fmt.Errorf("failed to put user in repo: %w", err)
	}
	w.l.Debug("user updated %s", user.Email)
	w.l.Debug("hash %s", user.PasswordHash)
	return nil
}

func (w *Who) userGet(id string) *userStorage {
	key := UserRepoKey{ID: id}
	userRepoValue, err := w.userRepo.Get(key)
	if err != nil {
		w.l.Debug("user not found: %s", id)
		return nil
	}
	user := repoValueToUserStorage(userRepoValue)
	return &user
}
func (w *Who) userByUsername(username string) *userStorage {
	l := w.l.WithBreadcrumb("user_by_username")
	l.Debug("username: %s", username)
	
	// Use a more efficient approach - get keys and process in batches
	keys, err := w.userRepo.Keys()
	if err != nil {
		l.Error("failed to get user keys: %v", err)
		return nil
	}
	
	// Process keys in smaller batches to avoid timeout
	keySlice := make([]UserRepoKey, 0, 100)
	for key := range keys {
		keySlice = append(keySlice, key)
		if len(keySlice) >= 100 { // Process in batches of 100
			user := w.findUserInBatch(keySlice, username, true)
			if user != nil {
				return user
			}
			keySlice = keySlice[:0] // Reset slice
		}
	}
	
	// Process remaining keys
	if len(keySlice) > 0 {
		user := w.findUserInBatch(keySlice, username, true)
		if user != nil {
			return user
		}
	}
	
	return nil
}
func (w *Who) userByEmail(email string) *userStorage {
	l := w.l.WithBreadcrumb("user_by_email")
	l.Debug("email: %s", email)
	
	// Use a more efficient approach - get keys and process in batches
	keys, err := w.userRepo.Keys()
	if err != nil {
		l.Error("failed to get user keys: %v", err)
		return nil
	}
	
	// Process keys in smaller batches to avoid timeout
	keySlice := make([]UserRepoKey, 0, 100)
	for key := range keys {
		keySlice = append(keySlice, key)
		if len(keySlice) >= 100 { // Process in batches of 100
			user := w.findUserInBatch(keySlice, email, false)
			if user != nil {
				return user
			}
			keySlice = keySlice[:0] // Reset slice
		}
	}
	
	// Process remaining keys
	if len(keySlice) > 0 {
		user := w.findUserInBatch(keySlice, email, false)
		if user != nil {
			return user
		}
	}
	
	return nil
}

// findUserInBatch searches for a user in a batch of keys
// isUsername: true for username search, false for email search
func (w *Who) findUserInBatch(keys []UserRepoKey, searchTerm string, isUsername bool) *userStorage {
	for _, key := range keys {
		userRepoValue, err := w.userRepo.Get(key)
		if err != nil {
			continue
		}
		
		if isUsername && userRepoValue.Username == searchTerm {
			user := repoValueToUserStorage(userRepoValue)
			return &user
		} else if !isUsername && userRepoValue.Email == searchTerm {
			user := repoValueToUserStorage(userRepoValue)
			return &user
		}
	}
	return nil
}

func (w *Who) permGranted(user *userStorage, perms []api.Permission) bool {
	for _, perm := range perms {
		if !slices.Contains(user.Permissions, perm) {
			return false
		}
	}
	return true
}

func (w *Who) userAddPermission(user *userStorage, perm api.Permission) (bool, error) {
	var err error

	if !slices.Contains(PermissionsAll, perm) {
		return false, fmt.Errorf("permission %s is not a valid permission", perm)
	}
	if w.permGranted(user, []api.Permission{perm}) {
		return false, nil
	}
	user.Permissions = append(user.Permissions, perm)

	// Persist the updated user to repository
	err = w.userUpdate(user)
	if err != nil {
		return false, fmt.Errorf("failed to update user in repository: %w", err)
	}

	return true, nil
}

func (w *Who) userRemovePermission(user *userStorage, perm api.Permission) (bool, error) {
	var err error

	if !slices.Contains(PermissionsAll, perm) {
		return false, fmt.Errorf("permission %s is not a valid permission", perm)
	}
	if !w.permGranted(user, []api.Permission{perm}) {
		return false, nil
	}

	user.Permissions = slices.DeleteFunc(user.Permissions, func(p api.Permission) bool {
		return p == perm
	})

	// Persist the updated user to repository
	err = w.userUpdate(user)
	if err != nil {
		return false, fmt.Errorf("failed to update user in repository: %w", err)
	}

	return true, nil
}

// ----------- JWT -----------

func (w *Who) userJwt(user *userStorage) (string, error) {
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
