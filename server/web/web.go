package web

import (
	"context"
	"embed"
	"io/fs"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/nats-io/nats.go"

	"jst_dev/server/articles"
	"jst_dev/server/jst_log"
)

type httpServer struct {
	nc          *nats.Conn
	l           *jst_log.Logger
	ctx         context.Context
	articleRepo articles.ArticleRepo
	mux         *http.ServeMux // For defining routes
	handler     http.Handler   // Final wrapped handler for serving requests
	embedFs     fs.FS
	syncService *SyncService // Data sync service
}

//go:embed static
var embedded embed.FS

// New initializes and returns a new httpServer instance with embedded static files and an article repository.
// Returns nil if the static files or article repository cannot be initialized.
func New(ctx context.Context, nc *nats.Conn, jwtSecret string, l *jst_log.Logger, articleRepo articles.ArticleRepo, dev bool) *httpServer {
	fs, err := fs.Sub(embedded, "static")
	if err != nil {
		l.Error("Failed to load static folder")
		return nil
	}

	s := &httpServer{
		nc:          nc,
		ctx:         ctx,
		l:           l,
		embedFs:     fs,
		articleRepo: articleRepo,
		mux:         http.NewServeMux(),
	}

	// Initialize sync service
	s.syncService = NewSyncService(nc, l.WithBreadcrumb("sync"), ctx)

	// Set up routes on the mux
	routes(s.mux, l.WithBreadcrumb("route"), s.articleRepo, nc, s.embedFs, jwtSecret, dev)

	// Apply global middleware to create the final handler
	// note: last added is first called
	var handler http.Handler = s.mux
	handler = logger(l.WithBreadcrumb("log"), handler)
	handler = authJwt(jwtSecret, handler)
	// handler = authJwtDummy(jwtSecret, handler)
	handler = cors(l.WithBreadcrumb("cors"), handler)
	s.handler = handler // Store the wrapped handler

	return s
}

// GetMux returns the underlying mux for adding additional routes
func (s *httpServer) GetMux() *http.ServeMux {
	return s.mux
}

// GetSyncService returns the sync service for external access
func (s *httpServer) GetSyncService() *SyncService {
	return s.syncService
}

func (s *httpServer) Run(cleanShutdown *sync.WaitGroup, port string) {
	cleanShutdown.Add(1)

	httpServer := &http.Server{
		Addr:              net.JoinHostPort("0.0.0.0", "8080"),
		Handler:           s.handler, // Use the wrapped handler instead of s.mux
		ReadHeaderTimeout: 20 * time.Second,
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
