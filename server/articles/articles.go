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

// --- ARTICLE ---
type ArticleRepo struct {
	ctx      context.Context
	lock     sync.RWMutex
	articles map[string]*Article
	kv       jetstream.KeyValue
}

type ArticleMetadata struct {
	StructVersion int    `json:"struct_version"`
	Rev           int    `json:"revision"`
	Slug          string `json:"slug"`
	Title         string `json:"title"`
	Subtitle      string `json:"subtitle"`
	Leading       string `json:"leading"`
}

type Article struct {
	StructVersion int       `json:"struct_version"`
	Rev           int       `json:"revision"`
	Slug          string    `json:"slug"`
	Title         string    `json:"title"`
	Subtitle      string    `json:"subtitle"`
	Leading       string    `json:"leading"`
	Content       []Content `json:"content"`
}

// --- CONTENT ---

type Content struct {
	Type       ContentType `json:"type"`
	Text       string      `json:"text,omitempty"`
	Content    []Content   `json:"content,omitempty"`
	Url        string      `json:"url,omitempty"`
	Alt        string      `json:"alt,omitempty"`
	Heading    string      `json:"heading,omitempty"`
	Subheading string      `json:"subheading,omitempty"`
}

type ContentType string

const (
	ContentText         ContentType = "text"
	ContentBlock        ContentType = "block"
	ContentHeading      ContentType = "heading"
	ContentParagraph    ContentType = "paragraph"
	ContentLink         ContentType = "link"
	ContentLinkExternal ContentType = "link_external"
	ContentImage        ContentType = "image"
	ContentList         ContentType = "list"
)

// --- GENERATORS ---

func Text(text string) Content {
	return Content{
		Type: ContentText,
		Text: text,
	}
}

func Block(contents ...Content) Content {
	return Content{
		Type:    ContentBlock,
		Content: contents,
	}
}

func Heading(text string) Content {
	return Content{
		Type: ContentHeading,
		Text: text,
	}
}

func Paragraph(contents ...Content) Content {
	return Content{
		Type:    ContentParagraph,
		Content: contents,
	}
}

func Link(url string, contents ...Content) Content {
	return Content{
		Type:    ContentLink,
		Url:     url,
		Content: contents,
	}
}

func LinkExternal(url string, contents ...Content) Content {
	return Content{
		Type:    ContentLinkExternal,
		Url:     url,
		Content: contents,
	}
}
func Image(url string, alt string) Content {
	return Content{
		Type: ContentImage,
		Url:  url,
		Alt:  alt,
	}
}

func List(contents ...Content) Content {
	return Content{
		Type:    ContentList,
		Content: contents,
	}
}

// --- REPO ---

// Creates a new ArticleRepo. This includes setting up a kv store and a watcher to update the in-memory map.
func Repo(ctx context.Context, nc *nats.Conn, l *jst_log.Logger) (*ArticleRepo, error) {
	kv, err := setup(ctx, nc)
	if err != nil {
		return nil, fmt.Errorf("repo setup: %w", err)
	}
	repo := &ArticleRepo{
		ctx:      ctx,
		articles: make(map[string]*Article),
		kv:       kv,
		lock:     sync.RWMutex{},
	}

	watcher, err := kv.WatchAll(ctx)
	if err != nil {
		return nil, fmt.Errorf("watchAll: %w", err)
	}
	go repo.updater(ctx, watcher, l.WithBreadcrumb("watcher"))
	return repo, nil
}

// Get returns an article by slug.
func (r *ArticleRepo) Get(slug string) *Article {
	r.lock.RLock()
	defer r.lock.RUnlock()
	art, ok := r.articles[slug]
	if !ok {
		return nil
	}
	return art
}

func (r *ArticleRepo) AllNoContent() []ArticleMetadata {
	r.lock.RLock()
	defer r.lock.RUnlock()
	articles := make([]ArticleMetadata, 0, len(r.articles))
	for _, art := range r.articles {
		articles = append(articles, ArticleMetadata{
			StructVersion: art.StructVersion,
			Slug:          art.Slug,
			Rev:           art.Rev,
			Title:         art.Title,
			Subtitle:      art.Subtitle,
			Leading:       art.Leading,
		})
	}
	return articles
}

// Put updates an article.
func (r *ArticleRepo) Put(art Article, rev int) error {
	r.lock.Lock()
	defer r.lock.Unlock()

	// Validate the revision number
	if rev > 0 {
		// Check if article exists and revision matches
		existing, exists := r.articles[art.Slug]
		if !exists {
			return fmt.Errorf("article with slug %s not found", art.Slug)
		}
		if existing.Rev != rev {
			return fmt.Errorf("revision mismatch: expected %d, got %d", existing.Rev, rev)
		}
		// Increment revision for update
		art.Rev = rev + 1
	} else {
		// For new articles, start at revision 1
		// Check if article already exists
		if _, exists := r.articles[art.Slug]; exists {
			return fmt.Errorf("article with slug %s already exists", art.Slug)
		}
		art.Rev = 1
	}

	// Marshal article to JSON
	data, err := json.Marshal(art)
	if err != nil {
		return fmt.Errorf("marshal article: %w", err)
	}

	// Store in JetStream KV
	_, err = r.kv.Put(r.ctx, art.Slug, data)
	if err != nil {
		return fmt.Errorf("store article: %w", err)
	}

	// Update in-memory map (this will also be updated by the watcher,
	// but we do it here for immediate consistency)
	r.articles[art.Slug] = &art

	return nil
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
