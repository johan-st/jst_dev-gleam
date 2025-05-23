package web

import (
	"context"
	"embed"
	"io/fs"
	"jst_dev/server/articles"
	"jst_dev/server/jst_log"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/nats-io/nats.go"
)

type httpServer struct {
	nc          *nats.Conn
	l           *jst_log.Logger
	ctx         context.Context
	articleRepo articles.ArticleRepo
	mux         *http.ServeMux // For defining routes
	handler     http.Handler   // Final wrapped handler for serving requests
	embedFs     fs.FS
}

//go:embed static
var embedded embed.FS

// New initializes and returns a new httpServer instance with embedded static files and an article repository.
// Returns nil if the static files or article repository cannot be initialized.
func New(ctx context.Context, nc *nats.Conn, jwtSecret string, l *jst_log.Logger) *httpServer {
	fs, err := fs.Sub(embedded, "static")
	if err != nil {
		l.Error("Failed to load static folder")
		return nil
	}
	// artRepo, err := articles.RepoWithInMemCache(ctx, nc, l.WithBreadcrumb("articleRepo"))
	artRepo, err := articles.Repo(ctx, nc, l.WithBreadcrumb("articleRepo"))
	if err != nil {
		l.Error("Failed to create article repo: %s", err)
		return nil
	}

	s := &httpServer{
		nc:          nc,
		ctx:         ctx,
		l:           l,
		embedFs:     fs,
		articleRepo: artRepo,
		mux:         http.NewServeMux(),
	}

	// Set up routes on the mux
	routes(s.mux, l.WithBreadcrumb("route"), artRepo, nc, jwtSecret)

	// Apply middleware to create the final handler
	// note: last added is first called
	var handler http.Handler = s.mux
	handler = logger(handler)
	handler = authJwt(jwtSecret, handler)
	handler = cors(handler)
	s.handler = handler // Store the wrapped handler

	return s
}

func (s *httpServer) Run(cleanShutdown *sync.WaitGroup) {
	cleanShutdown.Add(1)

	httpServer := &http.Server{
		Addr:    net.JoinHostPort("", "8080"),
		Handler: s.handler, // Use the wrapped handler instead of s.mux
	}
	go func() {
		s.l.Info("listening on %s", httpServer.Addr)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			s.l.Error("error listening and serving: %s", err)
		}
	}()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		<-s.ctx.Done()
		shutdownCtx := context.Background()
		shutdownCtx, cancel := context.WithTimeout(shutdownCtx, 10*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			s.l.Error("error shutting down http server: %s\n", err)
		}
	}()
	wg.Wait()
	cleanShutdown.Done()
}
