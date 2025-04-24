package api

import (
	"fmt"

	"github.com/golang-jwt/jwt"
)

// USER
type UserFullResponse struct {
	ID          string       `json:"id"`
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
	Username string `json:"username,omitempty"`
	Email    string `json:"email,omitempty"`
}

type UserUpdateRequest struct {
	ID       string `json:"id"`
	Username string `json:"username,omitempty"`
	Email    string `json:"email,omitempty"`
}

type UserDeleteRequest struct {
	ID string `json:"id"`
}
type UserDeleteResponse struct {
	IdDeleted string `json:"deleted_id"`
}

// PERMISSIONS
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

type PermissionsListRequest struct {
	ID string `json:"id"`
}
type PermissionsListResponse struct {
	Permissions []Permission `json:"permissions"`
}

type PermissionsGrantRequest struct {
	ID         string     `json:"id"`
	Permission Permission `json:"permission"`
}
type PermissionsGrantResponse struct {
	ID    string     `json:"id"`
	Added Permission `json:"added"`
}

type PermissionsRevokeRequest struct {
	ID         string     `json:"id"`
	Permission Permission `json:"permission"`
}
type PermissionsRevokeResponse struct {
	ID      string     `json:"id"`
	Removed Permission `json:"removed"`
}

type PermissionsCheckRequest struct {
	ID         string     `json:"id"`
	Permission Permission `json:"permission"`
}
type PermissionsCheckResponse struct {
	ID            string     `json:"id"`
	HasPermission Permission `json:"hasPermission"`
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

// --------- Jwt ---------
type JwtClaims struct {
	Permissions []Permission `json:"perm"`
	jwt.StandardClaims
}

// JwtVerify verifies a JWT token signed by the Who service.
// 
//  subject, permissions, err := JwtVerify(secret, tokenStr)
func JwtVerify(secret, tokenStr string) (string, []Permission, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &JwtClaims{}, func(token *jwt.Token) (any, error) {
		return secret, nil
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

	return claims.Subject, claims.Permissions, nil
}
