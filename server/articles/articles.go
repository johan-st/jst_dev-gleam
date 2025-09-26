package articles

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"jst_dev/server/core"
	"jst_dev/server/jst_log"
)

// --- ARTICLE ---

type Article struct {
	StructVersion int       `json:"struct_version"`
	Id            uuid.UUID `json:"id"`
	Rev           uint64    `json:"revision,omitempty"`
	Slug          string    `json:"slug"`
	Title         string    `json:"title"`
	Subtitle      string    `json:"subtitle"`
	Leading       string    `json:"leading"`
	Author        string    `json:"author"`
	PublishedAt   int       `json:"published_at"` // unix timestamp in milliseconds
	Tags          []string  `json:"tags"`
	Content       string    `json:"content,omitempty"`
}

func (A Article) Bytes() []byte {
	data, err := json.Marshal(A)
	if err != nil {
		panic("Article.Bytes") // TODO: evaluate this. Do I need another interface for the repo?
	}
	return data
}

func (A Article) FromBytes(value []byte) (Article, error) {
	err := json.Unmarshal(value, &A)
	if err != nil {
		return Article{}, err
	}
	return A, nil
}

// --- REPO ---

// Repo initializes and returns an ArticleRepo backed by a JetStream key-value store.
// Returns an error if the key-value store cannot be set up.
func NewRepo(ctx context.Context, nc *nats.Conn, l *jst_log.Logger) (core.Repo[Article], error) {
	kv, err := setup(ctx, nc)
	if err != nil {
		return nil, fmt.Errorf("repo setup: %w", err)
	}

	repo, err := core.NewRepoKv[Article](ctx, l, kv)
	if err != nil {
		return nil, fmt.Errorf("create repo: %w", err)
	}

	return repo, nil
}

// --- SETUP ---

// setup initializes and returns a JetStream key-value store bucket named "article" for storing articles in JSON format.
// The bucket is configured with a 5MB maximum value size, 64 history entries, and file storage.
// Returns the created key-value store or an error if initialization fails.
func setup(ctx context.Context, nc *nats.Conn) (jetstream.KeyValue, error) {
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, fmt.Errorf("jetstream new: %w", err)
	}
	kv, err := js.CreateOrUpdateKeyValue(ctx, jetstream.KeyValueConfig{
		Bucket:       "article",
		Description:  "articles in json format",
		MaxValueSize: 1024 * 1024 * 5,  // 5 MB
		MaxBytes:     1024 * 1024 * 50, // 50 MB,
		History:      64,
		// TTL: 24 * time.Hour,
		Storage: jetstream.FileStorage,
		// Replicas: 1,
		// Placement: &jetstream.Placement{},
		// RePublish: &jetstream.RePublish{},
		// Mirror: &jetstream.StreamSource{},
		// Sources: []*jetstream.StreamSource{},
		Compression: true,
	})
	if err != nil {
		return nil, fmt.Errorf("kv create: %w", err)
	}
	return kv, nil
}
