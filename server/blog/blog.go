package blog

import (
	"context"
	"encoding/json"
	"fmt"
	"jst_dev/server/jst_log"
	"jst_dev/server/talk"
	"strconv"
	"strings"
	"time"

	"github.com/nats-io/nats.go/jetstream"
	"github.com/nats-io/nats.go/micro"
)

var blog *Blog

type Blog struct {
	js    jetstream.JetStream
	kv    jetstream.KeyValue
	l     *jst_log.Logger
	ctx   context.Context
	slugs []string
}

type BlogArticle struct {
	Title   string `json:"title"`
	Slug    string `json:"slug"`
	Content string `json:"content"`
}

func Start(ctx context.Context, talk *talk.Talk, l *jst_log.Logger) error {
	if blog != nil {
		return fmt.Errorf("blog already started")
	}

	// Create JetStream streams
	js, err := jetstream.New(talk.Conn)
	if err != nil {
		return fmt.Errorf("create JetStream: %w", err)
	}

	kv, err := js.CreateKeyValue(ctx, jetstream.KeyValueConfig{
		Bucket:       "blog",
		Description:  "blog articles formated as markdown",
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
		return fmt.Errorf("create key value: %w", err)
	}

	blog = &Blog{
		js:  js,
		kv:  kv,
		l:   l,
		ctx: ctx,
	}

	go updatesWatcher(ctx, kv, l.WithBreadcrumb("updates"))

	// start service
	group := talk.Service.AddGroup("blog")
	// Use group to add endpoints
	group.AddEndpoint("validate", blog.HandleValidate())
	group.AddEndpoint("add", blog.HandleAdd())
	group.AddEndpoint("list", blog.HandleList())
	group.AddEndpoint("get", blog.HandleGet())
	// group.AddEndpoint("update", blog.HandleUpdate())
	// group.AddEndpoint("delete", blog.HandleDelete())

	return nil
}

func updatesWatcher(ctx context.Context, kv jetstream.KeyValue, l *jst_log.Logger) {
	watcher, err := kv.WatchAll(ctx)
	if err != nil {
		l.Error("watch key value: %w", err)
		return
	}
	defer watcher.Stop()

	for {
		select {
		case <-ctx.Done():
			l.Info("updates watcher shutting down: %v", ctx.Err())
			return
		case update, ok := <-watcher.Updates():
			if !ok {
				l.Info("updates channel closed, exiting watcher")
				return
			}
			if update == nil {
				l.Debug("update is nil, continue..")
				continue
			}
			op := update.Operation()
			switch op {
			case jetstream.KeyValuePut:
				l.Debug("PUT - %s:%d", update.Key(), update.Revision())
			case jetstream.KeyValueDelete:
				l.Debug("DELETE - %s:%d", update.Key(), update.Revision())
			case jetstream.KeyValuePurge:
				l.Debug("UPDATE - %s:%d", update.Key(), update.Revision())
			default:
				l.Debug("update %s, on %s:%d", op, update.Key(), update.Revision())
			}
		}
	}
}

// ---- HANDLERS ----

func (b *Blog) HandleValidate() micro.HandlerFunc {
	l := b.l.WithBreadcrumb("validate")
	return func(req micro.Request) {
		l.Info("blog validate request")
		// Handle validate blog request
		var article BlogArticle
		err := json.Unmarshal(req.Data(), &article)
		if err != nil {
			l.Info("blog validate request: %w", err)
			req.Respond([]byte(fmt.Sprintf("Invalid format. failed to parse json: %w", err)))
			return
		}
		req.Respond([]byte("ok"))
	}
}

func (b *Blog) HandleAdd() micro.HandlerFunc {
	l := b.l.WithBreadcrumb("add")
	return func(req micro.Request) {
		l.Info("blog add request")
		ctx, cancel := context.WithTimeout(b.ctx, 250*time.Millisecond)
		defer cancel()
		var article BlogArticle
		err := json.Unmarshal(req.Data(), &article)
		if err != nil {
			l.Warn("blog add request: %w", err)
			req.Error("400", "invalid request", []byte("shape of data is not valid. Expected: {title: string, slug: string, content: string}"))
			return
		}
		rev, err := b.kv.Put(ctx, article.Slug, []byte(req.Data()))
		if err != nil {
			l.Warn("blog add request: %w", err)
			req.Error("500", "failed to add article", []byte("failed to add article"))
			return
		}
		req.Respond([]byte(fmt.Sprintf("%s:%d", article.Slug, rev)))
	}
}

func (b *Blog) HandleList() micro.HandlerFunc {
	l := b.l.WithBreadcrumb("list")
	return func(req micro.Request) {
		l.Info("blog list request")
		var (
			sb                strings.Builder
			keyList           jetstream.KeyLister
			revFirst, revLast uint64
			ctx, cancel       = context.WithTimeout(b.ctx, 250*time.Millisecond)
			err               error
		)
		defer cancel()
		keyList, err = b.kv.ListKeys(ctx)
		if err != nil {
			l.Warn("blog list request: %w", err)
			req.Error("500", "failed to list articles", []byte("failed to list articles"))
			return
		}
		for key := range keyList.Keys() {
			revFirst, revLast = 0, 0
			history, err := b.kv.History(ctx, key, jetstream.MetaOnly())
			if err != nil {
				l.Warn("blog list request: %w", err)
				req.Error("500", "failed to get history for slug %s", []byte(key))
				return
			}
			if len(history) > 0 {
				revFirst = history[0].Revision()
				revLast = history[len(history)-1].Revision()
			}
			sb.WriteString(fmt.Sprintf("%s:%d-%d\n", key, revFirst, revLast))
		}
		req.Respond([]byte(sb.String()))
	}
}

func (b *Blog) HandleGet() micro.HandlerFunc {
	l := b.l.WithBreadcrumb("get")
	parseRequest := func(data []byte) (string, int, error) {
		var (
			slug string
			rev  int
			err  error
		)
		if len(data) == 0 {
			return "", 0, fmt.Errorf("invalid request. Expected slug[:rev] (e.g. 'article:4' or 'cars_galore')")
		}
		parts := strings.Split(string(data), ":")
		if len(parts) == 1 {
			slug = parts[0]
			rev = 0
		} else if len(parts) == 2 {
			slug = parts[0]
			rev, err = strconv.Atoi(parts[1])
			if err != nil {
				return parts[0], 0, fmt.Errorf("invalid request. parse revision: %w", err)
			}
			if rev < 0 {
				return parts[0], 0, fmt.Errorf("invalid request. revision cannot be negative")
			}
		} else {
			return "", 0, fmt.Errorf("invalid request. Expected slug[:rev] (e.g. 'article:4' or 'cars_galore')")
		}
		return slug, rev, nil
	}
	return func(req micro.Request) {
		var (
			slug   string
			rev    int
			err    error
			entry  jetstream.KeyValueEntry
			ctx    context.Context
			cancel context.CancelFunc
		)
		ctx, cancel = context.WithTimeout(b.ctx, 250*time.Millisecond)
		defer cancel()
		slug, rev, err = parseRequest(req.Data())
		l.Info("blog get request %s:%d", slug, rev)
		if err != nil {
			l.Warn("blog get request: %w", err)
			req.Error("400", "invalid request", []byte(err.Error()))
			return
		}
		if rev != 0 {
			entry, err = b.kv.GetRevision(ctx, slug, uint64(rev))
		} else {
			entry, err = b.kv.Get(ctx, slug)
		}
		if err != nil {
			l.Warn("blog get request: %w", err)
			req.Error("500", "failed to get article", []byte("failed to get article"))
			return
		}
		req.Respond(entry.Value())
	}
}
