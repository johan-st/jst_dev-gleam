package who

import (
	"context"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"jst_dev/server/jst_log"
	"jst_dev/server/who/api"
	"slices"
	"time"

	"github.com/golang-jwt/jwt"
	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/micro"
)

const hashSalt = "jst_dev_salt"
const jwtExpiresAfterTime = time.Hour * 12

var PermissionsAll = []api.Permission{
	api.PermissionPostViewAny,
	api.PermissionPostDeleteAny,
	api.PermissionUserViewAny,
	api.PermissionUserBlockAny,
	api.PermissionUserUnblockAny,
	api.PermissionUserGrantAny,
	api.PermissionUserRevokeAny,
}

type Who struct {
	users   []User
	l       *jst_log.Logger
	nc      *nats.Conn
	hash    hash.Hash
	secret  []byte
	usersKv nats.KeyValue
	ctx     context.Context
}

type User struct {
	Version  int
	ID       string
	Username string
	Email    string

	// private
	permissions  []api.Permission
	passwordHash string
}

type Conf struct {
	HashSalt  string
	JwtSecret []byte
	NatsConn  *nats.Conn
	Logger    *jst_log.Logger
}

func New(c *Conf) (*Who, error) {
	if len(c.JwtSecret) < 12 {
		return nil, fmt.Errorf("jwt secret must be at least 12 characters")
	}

	hash := sha512.New()
	_, err := hash.Write([]byte(hashSalt))
	if err != nil {
		return nil, fmt.Errorf("failed to write hash salt: %w", err)
	}

	who := &Who{
		users:   []User{},
		l:       c.Logger,
		nc:      c.NatsConn,
		hash:    hash,
		secret:  c.JwtSecret,
		usersKv: nil,
	}

	return who, nil
}

func (w *Who) Start(ctx context.Context) error {
	s := w.nc.Status()
	if s != nats.CONNECTED {
		return fmt.Errorf("nats connection not connected: %s", s)
	}

	js, err := w.nc.JetStream()
	if err != nil {
		return fmt.Errorf("failed to get JetStream context: %w", err)
	}

	confKv := nats.KeyValueConfig{
		Bucket:       "who_users",
		Description:  "who users by id",
		Storage:      nats.FileStorage,
		MaxValueSize: 1024 * 1024 * 1, // 1MB
		History:      64,
	}
	kv, err := js.CreateKeyValue(&confKv)
	if err != nil {
		w.l.Error(fmt.Sprintf("create users kv store %s:%s", confKv.Bucket, err.Error()))
		return fmt.Errorf("create users kv store %s:%w", confKv.Bucket, err)
	}

	w.usersKv = kv

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
	userSvcGroup := whoSvc.AddGroup("svc.who.users", micro.WithGroupQueueGroup("svc.who.users"))
	if err := userSvcGroup.AddEndpoint("user_create", w.handleUserCreate(), micro.WithEndpointSubject("create")); err != nil {
		return fmt.Errorf("add users endpoint (user_create): %w", err)
	}
	if err := userSvcGroup.AddEndpoint("user_get", w.handleUserGet(), micro.WithEndpointSubject("get")); err != nil {
		return fmt.Errorf("add users endpoint (user_get): %w", err)
	}
	if err := userSvcGroup.AddEndpoint("user_update", w.handleUserUpdate(), micro.WithEndpointSubject("update")); err != nil {
		return fmt.Errorf("add users endpoint (user_update): %w", err)
	}
	if err := userSvcGroup.AddEndpoint("user_delete", w.handleUserDelete(), micro.WithEndpointSubject("delete")); err != nil {
		return fmt.Errorf("add users endpoint (user_delete): %w", err)
	}

	// ----------- Permissions -----------
	permissionsSvcGroup := whoSvc.AddGroup("svc.who.permissions", micro.WithGroupQueueGroup("svc.who.permissions"))
	if err := permissionsSvcGroup.AddEndpoint("permission_list", w.handlePermissionsList(), micro.WithEndpointSubject("list")); err != nil {
		return fmt.Errorf("add permissions endpoint (permission_list): %w", err)
	}
	if err := permissionsSvcGroup.AddEndpoint("permission_grant", w.handlePermissionsGrant(), micro.WithEndpointSubject("grant")); err != nil {
		return fmt.Errorf("add permissions endpoint (permission_grant): %w", err)
	}
	if err := permissionsSvcGroup.AddEndpoint("permission_revoke", w.handlePermissionsRevoke(), micro.WithEndpointSubject("revoke")); err != nil {
		return fmt.Errorf("add permissions endpoint (permission_revoke): %w", err)
	}
	if err := permissionsSvcGroup.AddEndpoint("permission_check", w.handlePermissionsCheck(), micro.WithEndpointSubject("check")); err != nil {
		return fmt.Errorf("add permissions endpoint (permission_check): %w", err)
	}

	// ----------- Auth -----------
	authSvcGroup := whoSvc.AddGroup("svc.who.auth", micro.WithGroupQueueGroup("svc.who.auth"))
	if err := authSvcGroup.AddEndpoint("auth_login", w.handleAuth(), micro.WithEndpointSubject("login")); err != nil {
		return fmt.Errorf("add auth endpoint (auth_login): %w", err)
	}
	return nil
}

// ----------- HANDLERS -----------
// - Users

func (w *Who) handleUserCreate() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("user_create")
	return func(req micro.Request) {
		var (
			reqData  api.UserCreateRequest
			respData api.UserFullResponse
			err      error
			user     User
			ok       bool
		)

		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal user create request: %s", err.Error()))
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		if reqData.Username == "" {
			l.Warn("username is empty")
			req.Error("INVALID_REQUEST", "username is empty", []byte("username is empty"))
			return
		}
		if reqData.Email == "" {
			l.Warn("email is empty")
			req.Error("INVALID_REQUEST", "email is empty", []byte("email is empty"))
			return
		}
		if reqData.Password == "" {
			l.Warn("password is empty")
			req.Error("INVALID_REQUEST", "password is empty", []byte("password is empty"))
			return
		}
		_, ok = w.userByEmail(reqData.Email)
		if ok {
			l.Warn("user already exists")
			req.Error("EMAIL_ALREADY_EXISTS", "a user with this email already exists", []byte(reqData.Email))
			return
		}
		_, ok = w.userByUsername(reqData.Username)
		if ok {
			l.Warn("user already exists")
			req.Error("USERNAME_ALREADY_EXISTS", "a user with this username already exists", []byte(reqData.Username))
			return
		}

		user, err = w.userCreate(reqData.Username, reqData.Email, reqData.Password)
		if err != nil {
			l.Error(fmt.Sprintf("failed to create user: %s", err.Error()))
			req.Error("SERVER_ERROR", "server error", []byte(err.Error()))
			return
		}

		w.users = append(w.users, user)
		respData = api.UserFullResponse{
			ID:          user.ID,
			Username:    user.Username,
			Email:       user.Email,
			Permissions: user.permissions,
		}
		req.RespondJSON(respData)
	}
}

func (w *Who) handleUserGet() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("user_get")

	return func(req micro.Request) {
		var (
			reqData  api.UserGetRequest
			respData api.UserFullResponse
			err      error
			user     User
			ok       bool
		)
		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal user get request: %s", err.Error()))
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		if reqData.ID == "" && reqData.Username == "" && reqData.Email == "" {
			l.Warn("no id, username, or email provided")
			req.Error("INVALID_REQUEST", "no id, username, or email provided", []byte("no id, username, or email provided"))
			return
		}
		if reqData.ID != "" {
			user, ok = w.userGet(reqData.ID)
			if err != nil {
				l.Warn(fmt.Sprintf("error getting user: %s", err.Error()))
				req.Error("SERVER_ERROR", "server error while getting user", []byte(err.Error()))
				return
			}
		} else if reqData.Email != "" {
			user, ok = w.userByEmail(reqData.Email)
			if !ok {
				l.Warn(fmt.Sprintf("user not found: %s", reqData.Email))
				req.Error("USER_NOT_FOUND", "user not found", []byte(reqData.Email))
				return
			}
		} else if reqData.Username != "" {
			user, ok = w.userByUsername(reqData.Username)
		}

		if err != nil {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.ID))
			req.Error("USER_NOT_FOUND", "user not found", []byte(reqData.ID))
			return
		}
		respData = api.UserFullResponse{
			ID:          user.ID,
			Username:    user.Username,
			Email:       user.Email,
			Permissions: user.permissions,
		}
		req.RespondJSON(respData)
	}
}

func (w *Who) handleUserUpdate() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("user_update")
	type UserUpdateReq struct {
		ID       string `json:"id"`
		Username string `json:"username,omitempty"`
		Email    string `json:"email,omitempty"`
		Password string `json:"password,omitempty"`
	}
	type UserUpdateResp struct {
		Revision        uint64 `json:"revision"`
		ID              string `json:"id"`
		Username        string `json:"username"`
		Email           string `json:"email"`
		PasswordChanged bool   `json:"passwordChanged"`
	}

	return func(req micro.Request) {
		l.Debug("got request")
		var (
			reqData         UserUpdateReq
			respData        UserUpdateResp
			err             error
			user            User
			ok              bool
			passwordChanged bool = false
			rev             uint64
		)
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal user update request: %s", err.Error()))
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		user, ok = w.userGet(reqData.ID)
		if !ok {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.ID))
			req.Error("NOT_FOUND", "user not found", []byte(reqData.ID))
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
			passwordHash := w.hash.Sum([]byte(reqData.Password))
			user.passwordHash = hex.EncodeToString(passwordHash)
		}

		userBytes, err := json.Marshal(user)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to marshal user: %s", err.Error()))
			req.Error("SERVER_ERROR", "server error while updating user", []byte(err.Error()))
			return
		}
		rev, err = w.usersKv.Put(user.ID, userBytes)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to update user: %s", err.Error()))
			req.Error("SERVER_ERROR", "server error while updating user", []byte(err.Error()))
			return
		}
		respData = UserUpdateResp{
			Revision:        rev,
			ID:              user.ID,
			Username:        user.Username,
			Email:           user.Email,
			PasswordChanged: passwordChanged,
		}
		req.RespondJSON(respData)
	}
}

func (w *Who) handleUserDelete() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("user_delete")
	type UserDeleteReq struct {
		ID string `json:"id"`
	}
	type UserDeleteResp struct {
		ID string `json:"id"`
	}
	return func(req micro.Request) {
		l.Debug("got request")
		var reqData UserDeleteReq
		err := json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal user delete request: %s", err.Error()))
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		user, ok := w.userGet(reqData.ID)
		if !ok {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.ID))
			req.Error("NOT_FOUND", "user not found and could thus not be deleted", []byte(reqData.ID))
			return
		}
		err = w.usersKv.Delete(user.ID)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to delete user: %s", err.Error()))
			req.Error("SERVER_ERROR", "server error while deleting user", []byte(err.Error()))
			return
		}
		respData := UserDeleteResp{
			ID: user.ID,
		}
		req.RespondJSON(respData)
	}
}

// - Permissions

func (w *Who) handlePermissionsList() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("permissions_list")
	//
	permissions := []api.Permission{
		api.PermissionPostViewAny,
		api.PermissionPostDeleteAny,
		api.PermissionUserViewAny,
		api.PermissionUserBlockAny,
		api.PermissionUserUnblockAny,
		api.PermissionUserGrantAny,
		api.PermissionUserRevokeAny,
	}
	return func(req micro.Request) {
		l.Debug("got request")
		respData := api.PermissionsListResponse{
			Permissions: permissions,
		}
		req.RespondJSON(respData)
	}
}

func (w *Who) handlePermissionsGrant() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("permissions_grant")
	return func(req micro.Request) {
		l.Debug("got request")
		var reqData api.PermissionsGrantRequest
		err := json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal permissions grant request: %s", err.Error()))
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		user, ok := w.userGet(reqData.ID)
		if !ok {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.ID))
			req.Error("NOT_FOUND", "user not found and could thus not be granted permission", []byte(reqData.ID))
			return
		}
		err = w.userAddPermission(&user, reqData.Permission)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to add permission: %s", err.Error()))
			req.Error("OPERATION_FAILED", "the operation failed to complete", []byte(err.Error()))
			return
		}
		respData := api.PermissionsGrantResponse{
			ID:    user.ID,
			Added: reqData.Permission,
		}
		req.RespondJSON(respData)
	}
}

func (w *Who) handlePermissionsRevoke() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("permissions_revoke")
	return func(req micro.Request) {
		l.Debug("got request")
		var reqData api.PermissionsRevokeRequest
		err := json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal permissions revoke request: %s", err.Error()))
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		user, ok := w.userGet(reqData.ID)
		if !ok {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.ID))
			req.Error("NOT_FOUND", "user not found and could thus not be revoked permission", []byte(reqData.ID))
			return
		}
		err = w.userRemovePermission(&user, reqData.Permission)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to remove permission: %s", err.Error()))
			req.Error("OPERATION_FAILED", "the operation failed to complete", []byte(err.Error()))
			return
		}
		respData := api.PermissionsRevokeResponse{
			ID:      user.ID,
			Removed: reqData.Permission,
		}
		req.RespondJSON(respData)
	}
}

func (w *Who) handlePermissionsCheck() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("permissions_check")
	type PermissionsCheckResp struct {
		ID  string `json:"id"`
		Has bool   `json:"has"`
	}
	return func(req micro.Request) {
		l.Debug("got request")
		var (
			err     error
			reqData api.PermissionsCheckRequest
			user    User
		)
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal permissions check request: %s", err.Error()))
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		user, ok := w.userGet(reqData.ID)
		if !ok {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.ID))
			req.Error("NOT_FOUND", "user not found", []byte(reqData.ID))
			return
		}
		has := w.hasPermission(&user, reqData.Permission)
		respData := PermissionsCheckResp{
			ID:  user.ID,
			Has: has,
		}
		req.RespondJSON(respData)
	}
}

// - Auth

func (w *Who) handleAuth() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("auth")
	return func(req micro.Request) {
		l.Debug("got request")
		var (
			err      error
			reqData  api.AuthRequest
			respData api.AuthResponse
			user     User
			ok       bool
		)

		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal auth request: %s", err.Error()))
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		if reqData.Username == "" && reqData.Email == "" {
			l.Warn("username and email are empty")
			req.Error("INVALID_REQUEST", "username and email are empty", []byte("username and email are empty"))
			return
		}

		if reqData.Email != "" {
			user, ok = w.userByEmail(reqData.Email)
		}
		if !ok && reqData.Username != "" {
			user, ok = w.userByUsername(reqData.Username)
		}
		if !ok {
			l.Warn(fmt.Sprintf("user not found: %s", reqData.Username))
			req.Error("NOT_FOUND", "user not found", []byte(reqData.Username))
			return
		}

		token, err := w.userJwt(&user)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to create token: %s", err.Error()))
			req.Error("OPERATION_FAILED", "the operation failed to complete", []byte(err.Error()))
			return
		}
		l.Debug("got token %s", token)
		respData = api.AuthResponse{
			Token:     token,
			ExpiresAt: time.Now().Add(jwtExpiresAfterTime).Unix(),
		}
		req.RespondJSON(respData)
	}
}

// ----------- Helper Functions -----------

func (w *Who) userCreate(username, email, password string) (User, error) {
	if username == "" || email == "" || password == "" {
		return User{}, fmt.Errorf("username, email and password are required")
	}

	passwordHash := w.hash.Sum([]byte(password))

	u := User{
		Version:      1,
		ID:           uuid.New().String(),
		Username:     username,
		Email:        email,
		permissions:  []api.Permission{},
		passwordHash: hex.EncodeToString(passwordHash),
	}
	userBytes, err := json.Marshal(u)
	if err != nil {
		return User{}, fmt.Errorf("failed to marshal user: %w", err)
	}
	rev, err := w.usersKv.Put(u.ID, userBytes)
	if err != nil {
		return User{}, fmt.Errorf("failed to put user in kv: %w", err)
	}
	w.l.Debug("user created %s, rev %d", u.Email, rev)
	return u, nil
}

func (w *Who) userGet(id string) (User, bool) {
	var (
		user User
		ok   bool = false
	)
	for _, u := range w.users {
		if u.ID == id {
			user = u
			ok = true
			break
		}
	}
	return user, ok
}

// userByUsername returns the user by username and a boolean indicating if the user was found
// We do not return a reference to the original user as we do not want to allow modifications to the user
//
//  user, ok := w.userByUsername("username44")
func (w *Who) userByUsername(username string) (User, bool) {
	var user User
	for _, u := range w.users {
		if u.Username == username {
			user = u
			break
		}
	}
	return user, user.ID != ""
}

// userByEmail returns the user by email and a boolean indicating if the user was found
// We do not return a reference to the original user as we do not want to allow modifications to the user
//
//  user, ok := w.userByEmail("email@example.com")
func (w *Who) userByEmail(email string) (User, bool) {
	var user User
	for _, u := range w.users {
		if u.Email == email {
			user = u
			break
		}
	}
	return user, user.ID != ""
}

func (w *Who) hasPermission(u *User, p api.Permission) bool {
	return slices.Contains(u.permissions, p)
}

func (w *Who) userAddPermission(u *User, p api.Permission) error {
	if !slices.Contains(PermissionsAll, p) {
		return fmt.Errorf("invalid permission")
	}
	if w.hasPermission(u, p) {
		return fmt.Errorf("permission already exists")
	}
	u.permissions = append(u.permissions, p)
	return nil
}

func (w *Who) userRemovePermission(u *User, perm api.Permission) error {
	u.permissions = slices.DeleteFunc(u.permissions, func(p api.Permission) bool {
		return p == perm

	})
	return nil
}

// ----------- JWT -----------

func (w *Who) userJwt(u *User) (string, error) {
	// Create the Claims
	claims := api.JwtClaims{
		Permissions: u.permissions,
		StandardClaims: jwt.StandardClaims{
			Audience:  "jst_dev.who",
			ExpiresAt: time.Now().Add(jwtExpiresAfterTime).Unix(),
			Issuer:    "jst_dev.who",
			Subject:   u.ID,
			IssuedAt:  time.Now().Unix(),
		},
	}

	// TODO: Consider signingmethod with a public/private key pair
	token := jwt.NewWithClaims(jwt.SigningMethodHS512, claims)
	ss, err := token.SignedString(w.secret)
	if err != nil {
		return "", err
	}
	return ss, nil
}


