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

type Blog struct {
	js   jetstream.JetStream
	kv   jetstream.KeyValue
	l    *jst_log.Logger
	ctx  context.Context
	talk *talk.Talk
}

type BlogArticle struct {
	Title   string `json:"title"`
	Slug    string `json:"slug"`
	Content string `json:"content"`
}

func New(ctx context.Context, talk *talk.Talk, l *jst_log.Logger) (*Blog, error) {
	// Create JetStream streams
	js, err := jetstream.New(talk.Conn)
	if err != nil {
		return nil, fmt.Errorf("create JetStream: %w", err)
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
		// TODO: if err is bucket already exists we should try to update the config
		return nil, fmt.Errorf("create key value: %w", err)
	}

	return &Blog{
		js:   js,
		kv:   kv,
		l:    l,
		ctx:  ctx,
		talk: talk,
	}, nil

}
func (b *Blog) Start() error {

	watcher, err := b.kv.WatchAll(b.ctx)
	if err != nil {
		return fmt.Errorf("watchAll: %w", err)
	}
	go b.updatesWatcher(b.ctx, watcher, b.l.WithBreadcrumb("updates"))

	// start service
	metadata := map[string]string{}
	metadata["location"] = "unknown"
	metadata["environment"] = "development"
	svc, err := micro.AddService(b.talk.Conn, micro.Config{
		Name:        "blog",
		Version:     "1.0.0",
		Description: "Managing blog posts",
		Metadata:    metadata,
	})
	if err != nil {
		return fmt.Errorf("add service")
	}
	// Use group to add endpoints
	if err := svc.AddEndpoint("validate", b.HandleValidate()); err != nil {
		return fmt.Errorf("add endpoinr (validate): %w", err)
	}
	if err := svc.AddEndpoint("add", b.HandleAdd()); err != nil {
		return fmt.Errorf("add endpoint (add): %w", err)
	}
	if err := svc.AddEndpoint("list", b.HandleList()); err != nil {
		return fmt.Errorf("add endpoint (list): %w", err)
	}
	if err := svc.AddEndpoint("get", b.HandleGet()); err != nil {
		return fmt.Errorf("add endpoint (get): %w", err)
	}

	return nil
}

func (b *Blog) updatesWatcher(ctx context.Context, w jetstream.KeyWatcher, l *jst_log.Logger) {
	defer w.Stop()
	for {
		select {
		case <-ctx.Done():
			l.Info("shutting down: %v", ctx.Err())
			return
		case update, ok := <-w.Updates():
			if !ok {
				l.Info("channel closed, exiting")
				return
			}
			if update == nil {
				l.Debug("we are up to date")
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
				l.Debug("UNKNOWN update (%s), on %s:%d", op, update.Key(), update.Revision())
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
			req.Respond([]byte(fmt.Sprintf("invalid: %s", err.Error())))
			return
		}
		req.Respond([]byte("ok"))
	}
}

func (b *Blog) HandleAdd() micro.HandlerFunc {
	l := b.l.WithBreadcrumb("add")
	type req struct {
		Slug    string `json:"slug"`
		Title   string `json:"title"`
		Content string `json:"content"`
	}
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
