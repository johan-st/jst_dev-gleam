package api

import (
	"fmt"
	"strings"

	"github.com/golang-jwt/jwt"
)

var Subj = struct {
	// users
	UserGroup  string
	UserCreate string
	UserGet    string
	UserUpdate string
	UserDelete string
	// permissions
	PermissionsGroup  string
	PermissionsList   string
	PermissionsGrant  string
	PermissionsRevoke string
	PermissionsCheck  string
	// auth
	AuthGroup string
	AuthLogin string
}{
	// users
	UserGroup:  "svc.who.users",
	UserCreate: "create",
	UserGet:    "get",
	UserUpdate: "update",
	UserDelete: "delete",
	// permissions
	PermissionsGroup:  "svc.who.permissions",
	PermissionsList:   "list",
	PermissionsGrant:  "grant",
	PermissionsRevoke: "revoke",
	PermissionsCheck:  "check",
	// auth
	AuthGroup: "svc.who.auth",
	AuthLogin: "login",
}

// USER
type User struct {
	Version     int
	ID          string
	Revision    uint64
	Username    string
	Email       string
	Permissions []Permission
}

type UserFullResponse struct {
	ID          string       `json:"id"`
	Revision    uint64       `json:"revision"`
	Username    string       `json:"username"`
	Email       string       `json:"email"`
	Permissions []Permission `json:"permissions"`
}

type UserCreateRequest struct {
	Username string `json:"username"`
	Email    string `json:"email"`
	Password string `json:"password"`
}

type UserGetRequest struct {
	ID       string `json:"id,omitempty"`
	Revision uint64 `json:"revision,omitempty"`
	Username string `json:"username,omitempty"`
	Email    string `json:"email,omitempty"`
}

type UserUpdateRequest struct {
	ID       string `json:"id"`
	Revision uint64 `json:"revision,omitempty"`
	Username string `json:"username,omitempty"`
	Email    string `json:"email,omitempty"`
	Password string `json:"password,omitempty"`
}
type UserUpdateResponse struct {
	ID              string `json:"id"`
	Revision        uint64 `json:"revision"`
	Username        string `json:"username"`
	Email           string `json:"email"`
	PasswordChanged bool   `json:"passwordChanged"`
}

type UserDeleteRequest struct {
	ID string `json:"id"`
}
type UserDeleteResponse struct {
	IdDeleted string `json:"deleted_id"`
}

// Permission represents actions that are allowed for the resource.
type Permission string

const (
	// post
	PermissionPostViewAny   Permission = "post_view_any"
	PermissionPostDeleteAny Permission = "post_delete_any"

	// user
	PermissionUserViewAny    Permission = "user_view_any"
	PermissionUserBlockAny   Permission = "user_block_any"
	PermissionUserUnblockAny Permission = "user_unblock_any"
	PermissionUserGrantAny   Permission = "user_grant_any"
	PermissionUserRevokeAny  Permission = "user_revoke_any"
)

type PermissionsListResponse struct {
	Permissions []Permission `json:"permissions"`
}

type PermissionsGrantRequest struct {
	ID          string       `json:"id"`
	Permissions []Permission `json:"permissions"`
}
type PermissionsGrantResponse struct {
	ID      string       `json:"id"`
	Added   []Permission `json:"added"`
	Existed []Permission `json:"existed"`
}

type PermissionsRevokeRequest struct {
	ID          string       `json:"id"`
	Permissions []Permission `json:"permissions"`
}
type PermissionsRevokeResponse struct {
	ID      string       `json:"id"`
	Removed []Permission `json:"removed"`
	Missing []Permission `json:"missing"`
}

type PermissionsCheckRequest struct {
	ID          string       `json:"id"`
	Permissions []Permission `json:"permissions"`
}
type PermissionsCheckResponse struct {
	ID          string       `json:"id"`
	Permissions []Permission `json:"permissions"`
	AllGranted  bool         `json:"allGranted"`
	Granted     []Permission `json:"granted"`
	Missing     []Permission `json:"missing"`
}

// AUTH
type AuthRequest struct {
	Username string `json:"username"`
	Email    string `json:"email"`
	Password string `json:"password"`
}

type AuthResponse struct {
	Token     string `json:"token"`
	ExpiresAt int64  `json:"expiresAt"`
}

// JwtClaims is the claims for the JWT token.
//
// This is ment to be imported and used inside of the who service but also needs to be available in the api package.
type JwtClaims struct {
	Permissions []Permission `json:"perm"`
	jwt.StandardClaims
}

// JwtVerify verifies a JWT token signed by the Who service.
//
// This is ment to be imported and used outside of the who service.
//
// JwtVerify verifies a JWT token using the provided secret and returns the subject and associated permissions.
// Returns an error if the token is invalid or the claims cannot be parsed.
func JwtVerify(secret, audienceName, tokenStr string) (string, []Permission, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &JwtClaims{}, func(token *jwt.Token) (any, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		return []byte(secret), nil
	})
	if err != nil {
		return "", nil, fmt.Errorf("invalid token: %w", err)
	}
	claims, ok := token.Claims.(*JwtClaims)
	if !ok {
		return "", nil, fmt.Errorf("invalid custom claims token")
	}
	err = claims.Valid()
	if err != nil {
		return "", nil, fmt.Errorf("invalid token: %w", err)
	}
	if !strings.Contains(claims.Audience, audienceName) {
		return "", nil, fmt.Errorf("invalid audience: %s", claims.Audience)
	}

	return claims.Subject, claims.Permissions, nil
}
