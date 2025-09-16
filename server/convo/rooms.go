package convo

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"jst_dev/server/convo/api"
	"jst_dev/server/core"
	"jst_dev/server/jst_log"
)

// --- ROOM KEY ---

type RoomRepoKey struct {
	ID string
}

func (k RoomRepoKey) String() string {
	return k.ID
}

func (k RoomRepoKey) Bytes() []byte {
	return []byte(k.ID)
}

func (k *RoomRepoKey) FromBytes(value []byte) error {
	k.ID = string(value)
	return nil
}

// --- ROOM VALUE ---

type RoomRepoValue struct {
	api.Room
	Revision uint64 `json:"revision"`
}

func (r RoomRepoValue) Bytes() []byte {
	data, err := json.Marshal(r)
	if err != nil {
		panic("RoomRepoValue.Bytes") // TODO: evaluate this. Do I need another interface for the repo?
	}
	return data
}

func (r RoomRepoValue) FromBytes(value []byte) error {
	return json.Unmarshal(value, &r)
}

// --- REPO ---

// newRoomRepo initializes and returns a RoomRepo backed by a JetStream key-value store.
// Returns an error if the key-value store cannot be set up.
func newRoomRepo(ctx context.Context, nc *nats.Conn, l *jst_log.Logger) (core.Repo[RoomRepoKey, RoomRepoValue], error) {
	kv, err := setupRoomKV(ctx, nc)
	if err != nil {
		return nil, fmt.Errorf("repo setup: %w", err)
	}

	stringToKey := func(s string) RoomRepoKey {
		return RoomRepoKey{ID: s}
	}

	repo, err := core.NewRepoKv[RoomRepoKey, RoomRepoValue](ctx, l, kv, stringToKey)
	if err != nil {
		return nil, fmt.Errorf("create repo: %w", err)
	}

	return repo, nil
}

// --- SETUP ---

// setupRoomKV initializes and returns a JetStream key-value store bucket named "convo_room" for storing rooms in JSON format.
// The bucket is configured with a 16KB maximum value size, 32 history entries, and file storage.
// Returns the created key-value store or an error if initialization fails.
func setupRoomKV(ctx context.Context, nc *nats.Conn) (jetstream.KeyValue, error) {
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, fmt.Errorf("jetstream new: %w", err)
	}
	kv, err := js.CreateOrUpdateKeyValue(ctx, jetstream.KeyValueConfig{
		Bucket:       "convo_room",
		Description:  "conversation rooms by id",
		MaxValueSize: 1024 * 16,        // 16 KB per value
		MaxBytes:     1024 * 1024 * 50, // 50 MB total
		History:      32,
		Storage:      jetstream.FileStorage,
		Compression:  true,
	})
	if err != nil {
		return nil, fmt.Errorf("kv create: %w", err)
	}
	return kv, nil
}
