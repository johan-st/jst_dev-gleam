package urlShort

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"jst_dev/server/core"
	"jst_dev/server/jst_log"
	"jst_dev/server/urlShort/api"
)

// --- SHORT URL KEY ---

type ShortUrlRepoKey struct {
	ID string
}

func (k ShortUrlRepoKey) String() string {
	return k.ID
}

func (k ShortUrlRepoKey) Bytes() []byte {
	return []byte(k.ID)
}

func (k *ShortUrlRepoKey) FromBytes(value []byte) error {
	k.ID = string(value)
	return nil
}

// --- SHORT URL VALUE ---

type ShortUrlRepoValue struct {
	api.ShortUrl
	Revision uint64 `json:"revision"`
}

func (s ShortUrlRepoValue) Bytes() []byte {
	data, err := json.Marshal(s)
	if err != nil {
		panic("ShortUrlRepoValue.Bytes") // TODO: evaluate this. Do I need another interface for the repo?
	}
	return data
}

func (s ShortUrlRepoValue) FromBytes(value []byte) error {
	return json.Unmarshal(value, &s)
}

// --- REPO ---

// NewShortUrlRepo initializes and returns a ShortUrlRepo backed by a JetStream key-value store.
// Returns an error if the key-value store cannot be set up.
func NewShortUrlRepo(ctx context.Context, nc *nats.Conn, l *jst_log.Logger) (core.Repo[ShortUrlRepoKey, ShortUrlRepoValue], error) {
	kv, err := setupShortUrlKV(ctx, nc)
	if err != nil {
		return nil, fmt.Errorf("repo setup: %w", err)
	}

	stringToKey := func(s string) ShortUrlRepoKey {
		return ShortUrlRepoKey{ID: s}
	}

	repo, err := core.NewRepoKv[ShortUrlRepoKey, ShortUrlRepoValue](ctx, l, kv, stringToKey)
	if err != nil {
		return nil, fmt.Errorf("create repo: %w", err)
	}

	return repo, nil
}

// --- SETUP ---

// setupShortUrlKV initializes and returns a JetStream key-value store bucket named "url_short" for storing short URLs in JSON format.
// The bucket is configured with a 1KB maximum value size, 1 history entry, and file storage.
// Returns the created key-value store or an error if initialization fails.
func setupShortUrlKV(ctx context.Context, nc *nats.Conn) (jetstream.KeyValue, error) {
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, fmt.Errorf("jetstream new: %w", err)
	}
	kv, err := js.CreateOrUpdateKeyValue(ctx, jetstream.KeyValueConfig{
		Bucket:       "url_short",
		Description:  "short url mappings",
		MaxValueSize: 1 * 1024,         // 1 KB
		MaxBytes:     50 * 1024 * 1024, // 50 MB
		History:      1,
		Storage:      jetstream.FileStorage,
		Compression:  false,
	})
	if err != nil {
		return nil, fmt.Errorf("kv create: %w", err)
	}
	return kv, nil
}
