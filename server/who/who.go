package who

import (
	"crypto/sha512"
	"encoding/hex"
	"fmt"
	"hash"
	"jst_dev/server/jst_log"
	"slices"
	"time"

	"github.com/golang-jwt/jwt"
	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
)

type Permission string

const (
	PostCreate Permission = "post_create"
)

var (
	jwtSecret = []byte("secret")
	hashSalt  = []byte("salt")
)

type Who struct {
	users []User
	l     *jst_log.Logger
	nc    *nats.Conn
	hash  hash.Hash
}

type User struct {
	Version     int
	ID          string
	Username    string
	Email       string
	Permissions []Permission

	// private
	passwordHash string
}

func New(l *jst_log.Logger, nc *nats.Conn) (*Who, error) {
	s := nc.Status()
	if s != nats.CONNECTED {
		return nil, fmt.Errorf("nats connection not connected: %s", s)
	}

	hash := sha512.New()
	_, err := hash.Write(hashSalt)
	if err != nil {
		return nil, fmt.Errorf("failed to write hash salt: %w", err)
	}

	who := &Who{
		users: []User{},
		l:     l,
		nc:    nc,
		hash:  hash,
	}
	return who, nil
}

func (w *Who) CreateUser(username, email, password string) (*User, error) {
	if username == "" || email == "" || password == "" {
		return nil, fmt.Errorf("username, email and password are required")
	}

	passwordHash := w.hash.Sum([]byte(password))

	u := User{
		Version:      1,
		ID:           uuid.New().String(),
		Username:     username,
		Email:        email,
		Permissions:  []Permission{},
		passwordHash: hex.EncodeToString(passwordHash),
	}
	w.users = append(w.users, u)
	return &u, nil
}

func (w *Who) GetUser(id string) *User {
	for _, u := range w.users {
		if u.ID == id {
			return &u
		}
	}
	return nil
}

func (u *User) HasPermission(p Permission) bool {
	return slices.Contains(u.Permissions, p)
}

func (u *User) AddPermission(p Permission) {
	u.Permissions = append(u.Permissions, p)
}

func (u *User) RemovePermission(p Permission) {
	u.Permissions = slices.DeleteFunc(u.Permissions, func(p Permission) bool {
		return p == p
	})
}

func (u *User) Json() string {
	return fmt.Sprintf("User{ID: %s, Username: %s, Email: %s, Permissions: %v}", u.ID, u.Username, u.Email, u.Permissions)
}

// ----------- JWT -----------

type WhoCustomClaims struct {
	Permissions []Permission `json:"perm"`
	jwt.StandardClaims
}

func (u *User) JwtGet() (string, error) {
	// Create the Claims
	claims := WhoCustomClaims{
		Permissions: u.Permissions,
		StandardClaims: jwt.StandardClaims{
			Audience:  "jst_dev",
			ExpiresAt: time.Now().Add(time.Hour * 12).Unix(),
			Issuer:    "who",
			Subject:   u.ID,
			IssuedAt:  time.Now().Unix(),
		},
	}

	// TODO: Consider signingmethod with a public/private key pair
	token := jwt.NewWithClaims(jwt.SigningMethodHS512, claims)
	ss, err := token.SignedString(jwtSecret)
	if err != nil {
		return "", err
	}
	return ss, nil
}

func (w *Who) JwtVerify(tokenStr string) (string, []Permission, error) {

	token, err := jwt.ParseWithClaims(tokenStr, &WhoCustomClaims{}, func(token *jwt.Token) (interface{}, error) {
		return jwtSecret, nil
	})
	if err != nil {
		return "", nil, fmt.Errorf("invalid token: %w", err)
	}

	claims, ok := token.Claims.(*WhoCustomClaims)
	if !ok {
		return "", nil, fmt.Errorf("invalid custom claims token")
	}

	err = claims.Valid()
	if err != nil {
		return "", nil, fmt.Errorf("invalid token: %w", err)
	}

	return claims.Subject, claims.Permissions, nil
}
