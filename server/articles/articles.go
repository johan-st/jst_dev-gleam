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

type repo struct {
	ctx context.Context
	kv  jetstream.KeyValue
}

// --- ARTICLE ---
type articleRepo struct {
	ctx context.Context
	kv  jetstream.KeyValue
}

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
type Key struct {
	Id uuid.UUID
}

func (A Article) Bytes() []byte {
	data, err := json.Marshal(A)
	if err != nil {
		panic("Article.Bytes") // TODO: evaluate this. Do I need another interface for the repo?
	}
	return data
}

func (A Article) FromBytes(value []byte) error {
	return json.Unmarshal(value, &A)
}
func (k Key) String() string {
	return k.Id.String()
}

func (k Key) Bytes() []byte {
	return []byte(k.Id.String())
}

func (k Key) FromBytes(value []byte) error {
	return k.Id.UnmarshalText(value)
}

// --- REPO ---

// Repo initializes and returns an ArticleRepo backed by a JetStream key-value store.
// Returns an error if the key-value store cannot be set up.
func NewRepo(ctx context.Context, nc *nats.Conn, l *jst_log.Logger) (core.Repo[Key, Article], error) {
	kv, err := setup(ctx, nc)
	if err != nil {
		return nil, fmt.Errorf("repo setup: %w", err)
	}

	stringToKey := func(s string) Key {
		id, _ := uuid.Parse(s)
		return Key{Id: id}
	}

	repo, err := core.NewRepo[Key, Article](ctx, kv, stringToKey)
	if err != nil {
		return nil, fmt.Errorf("create repo: %w", err)
	}

	return repo, nil
}

func (r *articleRepo) Get(id uuid.UUID) (Article, error) {
	var (
		err   error
		entry jetstream.KeyValueEntry
		art   Article
	)
	entry, err = r.kv.Get(r.ctx, id.String())
	if err != nil {
		return art, fmt.Errorf("get article: %w", err)
	}
	err = json.Unmarshal(entry.Value(), &art)
	if err != nil {
		return art, fmt.Errorf("unmarshal article: %w", err)
	}
	art.Rev = entry.Revision()
	return art, nil
}

func (r *articleRepo) GetBySLug(slug string) (Article, error) {
	var (
		err   error
		keys  jetstream.KeyLister
		key   string
		entry jetstream.KeyValueEntry
		art   Article
	)
	keys, err = r.kv.ListKeys(r.ctx)
	if err != nil {
		return art, fmt.Errorf("list keys: %w", err)
	}
	for key = range keys.Keys() {
		entry, err = r.kv.Get(r.ctx, key)
		if err != nil {
			return art, fmt.Errorf("get article: %w", err)
		}
		err = json.Unmarshal(entry.Value(), &art)
		if err != nil {
			return art, fmt.Errorf("unmarshal article: %w", err)
		}
		if art.Slug == slug {
			art.Rev = entry.Revision()
			return art, nil
		}
	}
	return art, fmt.Errorf("article with slug %s not found", slug)
}

func (r *articleRepo) AllNoContent() ([]Article, error) {
	var (
		err       error
		art       Article
		keyLister jetstream.KeyLister
		entry     jetstream.KeyValueEntry
		arts      []Article
	)
	keyLister, err = r.kv.ListKeys(r.ctx)
	if err != nil {
		return nil, fmt.Errorf("list keys: %w", err)
	}
	for key := range keyLister.Keys() {
		art = Article{}
		entry, err = r.kv.Get(r.ctx, key)
		if err != nil {
			return nil, fmt.Errorf("get article: %w", err)
		}
		err = json.Unmarshal(entry.Value(), &art)
		if err != nil {
			return nil, fmt.Errorf("unmarshal article: %w", err)
		}

		metadataArticle := Article{
			StructVersion: art.StructVersion,
			Id:            art.Id,
			Author:        art.Author,
			PublishedAt:   art.PublishedAt,
			Tags:          art.Tags,
			Rev:           entry.Revision(),
			Slug:          art.Slug,
			Title:         art.Title,
			Subtitle:      art.Subtitle,
			Leading:       art.Leading,
		}
		arts = append(arts, metadataArticle)
	}
	return arts, nil
}

func (r *articleRepo) Create(art Article) (Article, error) {
	var (
		err  error
		data []byte
		rev  uint64
	)
	art.StructVersion = 1
	art.Rev = 1
	art.Id = uuid.New()
	data, err = json.Marshal(art)
	if err != nil {
		return art, fmt.Errorf("marshal article: %w", err)
	}
	rev, err = r.kv.Create(r.ctx, art.Id.String(), data)
	if err != nil {
		return art, fmt.Errorf("create article: %w", err)
	}
	art.Rev = rev
	return art, nil
}

func (r *articleRepo) Update(art Article) (Article, error) {
	var (
		err  error
		data []byte
		rev  uint64
	)

	art.Rev++
	data, err = json.Marshal(art)
	if err != nil {
		return art, fmt.Errorf("marshal article: %w", err)
	}

	// rev, err = r.kv.Update(r.ctx, art.Id.String(), data, uint64(art.Rev)) // TODO: use CAS
	rev, err = r.kv.Put(r.ctx, art.Id.String(), data)
	if err != nil {
		return art, fmt.Errorf("update article: %w", err)
	}
	art.Rev = rev
	return art, nil
}

func (r *articleRepo) Delete(id uuid.UUID) error {
	err := r.kv.Delete(r.ctx, id.String())
	if err != nil {
		return fmt.Errorf("delete article: %w", err)
	}
	return nil
}

func (r *articleRepo) GetHistory(id uuid.UUID) ([]Article, error) {
	var revisions []Article

	history, err := r.kv.History(r.ctx, id.String())
	if err != nil {
		return nil, fmt.Errorf("get article history: %w", err)
	}

	for _, entry := range history {
		if entry.Operation() == jetstream.KeyValuePut {
			var art Article
			err = json.Unmarshal(entry.Value(), &art)
			if err != nil {
				return nil, fmt.Errorf("unmarshal article: %w", err)
			}
			art.Rev = entry.Revision()
			revisions = append(revisions, art)
		}
	}

	// Reverse to show newest first
	for i, j := 0, len(revisions)-1; i < j; i, j = i+1, j-1 {
		revisions[i], revisions[j] = revisions[j], revisions[i]
	}

	return revisions, nil
}

func (r *articleRepo) GetRevision(id uuid.UUID, revision uint64) (Article, error) {
	var art Article

	entry, err := r.kv.GetRevision(r.ctx, id.String(), revision)
	if err != nil {
		return art, fmt.Errorf("get article revision: %w", err)
	}

	err = json.Unmarshal(entry.Value(), &art)
	if err != nil {
		return art, fmt.Errorf("unmarshal article: %w", err)
	}

	return art, nil
}

func (r *articleRepo) Context() context.Context {
	return r.ctx
}

func (r *articleRepo) WatchAll() (jetstream.KeyWatcher, error) {
	return r.kv.WatchAll(r.ctx)
}

func (r *articleRepo) Purge() error {
	keys, err := r.kv.ListKeys(r.ctx)
	if err != nil {
		return fmt.Errorf("purge article: %w", err)
	}
	for key := range keys.Keys() {
		err = r.kv.Purge(r.ctx, key)
		if err != nil {
			return fmt.Errorf("purge article: %w", err)
		}
	}
	return nil
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
