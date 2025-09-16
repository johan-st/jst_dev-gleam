package who

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"jst_dev/server/core"
	"jst_dev/server/jst_log"
	"jst_dev/server/who/api"
)

// --- USER KEY ---

type UserRepoKey struct {
	ID string
}

func (k UserRepoKey) String() string {
	return k.ID
}

func (k UserRepoKey) Bytes() []byte {
	return []byte(k.ID)
}

func (k *UserRepoKey) FromBytes(value []byte) error {
	k.ID = string(value)
	return nil
}

// --- USER VALUE ---

type UserRepoValue struct {
	api.User
	PasswordHash string `json:"passwordHash"`
	Revision     uint64 `json:"revision"`
}

func (u UserRepoValue) Bytes() []byte {
	data, err := json.Marshal(u)
	if err != nil {
		panic("UserRepoValue.Bytes") // TODO: evaluate this. Do I need another interface for the repo?
	}
	return data
}

func (u UserRepoValue) FromBytes(value []byte) error {
	return json.Unmarshal(value, &u)
}

// --- REPO ---

// NewUserRepo initializes and returns a UserRepo backed by a JetStream key-value store.
// Returns an error if the key-value store cannot be set up.
func NewUserRepo(ctx context.Context, nc *nats.Conn, l *jst_log.Logger) (core.Repo[UserRepoKey, UserRepoValue], error) {
	kv, err := setupUserKV(ctx, nc)
	if err != nil {
		return nil, fmt.Errorf("repo setup: %w", err)
	}

	stringToKey := func(s string) UserRepoKey {
		return UserRepoKey{ID: s}
	}

	repo, err := core.NewRepoKv[UserRepoKey, UserRepoValue](ctx, l, kv, stringToKey)
	if err != nil {
		return nil, fmt.Errorf("create repo: %w", err)
	}

	return repo, nil
}

// --- SETUP ---

// setupUserKV initializes and returns a JetStream key-value store bucket named "who_users" for storing users in JSON format.
// The bucket is configured with a 1MB maximum value size, 64 history entries, and file storage.
// Returns the created key-value store or an error if initialization fails.
func setupUserKV(ctx context.Context, nc *nats.Conn) (jetstream.KeyValue, error) {
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, fmt.Errorf("jetstream new: %w", err)
	}
	kv, err := js.CreateOrUpdateKeyValue(ctx, jetstream.KeyValueConfig{
		Bucket:       "who_users",
		Description:  "who users by id",
		MaxValueSize: 1024 * 1024 * 1,  // 1 MB
		MaxBytes:     1024 * 1024 * 50, // 50 MB,
		History:      64,
		Storage:      jetstream.FileStorage,
		Compression:  true,
	})
	if err != nil {
		return nil, fmt.Errorf("kv create: %w", err)
	}
	return kv, nil
}
