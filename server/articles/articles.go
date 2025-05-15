// Ment to be imported and called from anywhere we have a nats.Conn to the cluster where the blog is stored.
package articles

import (
	"context"
	"encoding/json"
	"fmt"
	"jst_dev/server/jst_log"
	"sync"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

const (
	kv_name = "articles"
)

type ArticleRepo struct {
	ctx      context.Context
	lock     sync.RWMutex
	articles map[string]*Article
	kv       jetstream.KeyValue
}

type Article struct {
	StructVersion int       `json:"struct_version"`
	Slug          string    `json:"slug"`
	Title         string    `json:"title"`
	Subtitle      string    `json:"subtitle"`
	Leading       string    `json:"leading"`
	Content       []Content `json:"content"`
}

type Content struct {
	Type    ContentType `json:"type"`
	Text    string      `json:"text,omitempty"`    // Only for type "Text"
	Content []Content   `json:"content,omitempty"` // Never for type "Text"
}

type ContentType string

const (
	Heading   ContentType = "heading"
	Subtitle  ContentType = "subtitle"
	Leading   ContentType = "leading"
	Paragraph ContentType = "paragraph"
	Link      ContentType = "link"
	Text      ContentType = "text"
)

// --- REPO ---

func Repo(ctx context.Context, nc *nats.Conn, l *jst_log.Logger) (*ArticleRepo, error) {
	kv, err := setup(ctx, nc)
	if err != nil {
		return nil, fmt.Errorf("repo setup: %w", err)
	}
	repo := &ArticleRepo{
		articles: make(map[string]*Article),
		kv:       kv,
		lock:     sync.RWMutex{},
	}

	watcher, err := kv.WatchAll(ctx)
	if err != nil {
		return nil, fmt.Errorf("watchAll: %w", err)
	}
	go repo.updater(ctx, watcher, l.WithBreadcrumb("watch"))
	return repo, nil
}

func (r *ArticleRepo) Get(slug string) *Article {
	art, ok := r.articles[slug]
	if !ok {
		return nil
	}
	return art
}

func (r *ArticleRepo) updater(ctx context.Context, w jetstream.KeyWatcher, l *jst_log.Logger) {
	var (
		err error
		art *Article
	)
	defer w.Stop()
	for {
		select {
		case <-ctx.Done():
			l.Info("context done, stopping")
			return
		case update, ok := <-w.Updates():
			if !ok {
				l.Warn("Channel unexpectedly closed")
				return
			}
			if update == nil {
				l.Debug("up to date")
				continue
			}

			op := update.Operation()
			switch op {
			case jetstream.KeyValuePut:
				l.Debug("PUT - %s:%d", update.Key(), update.Revision())
				art = &Article{}
				err = json.Unmarshal(update.Value(), art)
				if err != nil {
					l.Error("decode put: %w", err)
				}
				r.articles[art.Slug] = art
			case jetstream.KeyValueDelete:
				l.Debug("DELETE - %s:%d", update.Key(), update.Revision())
				delete(r.articles, update.Key())
			case jetstream.KeyValuePurge:
				l.Debug("PURGE - %s:%d", update.Key(), update.Revision())
				l.Error("Purge not handled")
			default:
				l.Debug("UNKNOWN update (%s), on %s:%d", op, update.Key(), update.Revision())
			}
		}
	}
}

// --- SETUP ---

// set up key-value store used for the articles.
func setup(ctx context.Context, nc *nats.Conn) (jetstream.KeyValue, error) {
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, fmt.Errorf("jetstream new: %w", err)
	}
	kv, err := js.CreateOrUpdateKeyValue(ctx, jetstream.KeyValueConfig{
		Bucket:       "article",
		Description:  "articles in json format",
		MaxValueSize: 1024 * 1024 * 5, // 5MB
		History:      64,
		// TTL: 24 * time.Hour,
		Storage: jetstream.FileStorage,
		// Replicas: 1,
		// Placement: &jetstream.Placement{},
		// RePublish: &jetstream.RePublish{},
		// Mirror: &jetstream.StreamSource{},
		// Sources: []*jetstream.StreamSource{},
		// Compression: true,
	})
	if err != nil {
		return nil, fmt.Errorf("kv create: %w", err)
	}
	return kv, nil
}
