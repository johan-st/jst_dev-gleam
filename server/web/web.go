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
	"jst_dev/server/core"
	"jst_dev/server/jst_log"
)

type httpServer struct {
	nc          *nats.Conn
	l           *jst_log.Logger
	ctx         context.Context
	articleRepo core.Repo[articles.Article]
	mux         *http.ServeMux // For defining routes
	handler     http.Handler   // Final wrapped handler for serving requests
	embedFs     fs.FS
	slow        time.Duration
	port        string
}

//go:embed static
var embedded embed.FS

// New initializes and returns a new httpServer instance with embedded static files and an article repository.
// Returns nil if the static files or article repository cannot be initialized.
func New(ctx context.Context, nc *nats.Conn, jwtSecret string, l *jst_log.Logger, articleRepo core.Repo[articles.Article], dev bool, slow time.Duration, port string) *httpServer {
	fs, err := fs.Sub(embedded, "static")
	if err != nil {
		l.Error("Failed to load static folder")
		return nil
	}

	// Default port if not specified
	if port == "" {
		port = "8080"
	}

	s := &httpServer{
		nc:          nc,
		ctx:         ctx,
		l:           l,
		embedFs:     fs,
		articleRepo: articleRepo,
		mux:         http.NewServeMux(),
		slow:        slow,
		port:        port,
	}

	// Set up routes on the mux
	routes(s.mux, l.WithBreadcrumb("route"), s.articleRepo, nc, s.embedFs, jwtSecret, dev, s.slow)

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

// Run implements the service.Service interface
// The service runs until the context is cancelled, then performs cleanup
// Only returns after the server stops
func (s *httpServer) Run(ctx context.Context) error {
	var (
		fatalChan  = make(chan error)
		httpServer = &http.Server{
			Addr:              net.JoinHostPort("0.0.0.0", s.port),
			Handler:           s.handler,
			ReadHeaderTimeout: 20 * time.Second,
		}
	)

	// Start server in background
	go func(killChan <-chan error) {
		s.l.Info("listening on %s", httpServer.Addr)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			s.l.Error("error listening and serving: %s", err)
			fatalChan <- err
		}
	}(fatalChan)

	// Wait for context cancellation or fatal error
	select {
	case err := <-fatalChan:
		s.l.Fatal("error listening and serving: %s", err)
		return err
	case <-ctx.Done():
		s.l.Info("http server stopping...")
		//TODO: we should consider moving the timeout to a stop method on this struct.
		//      That way we can control the timeout from the orchestrating main func

		shutdownCtx := context.Background()
		shutdownCtx, cancel := context.WithTimeout(shutdownCtx, 10*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			s.l.Error("error shutting down http server: %s\n", err)
		}
		s.l.Info("http server stopped")
		return nil
	}
}

// Name returns the service name for identification
func (s *httpServer) Name() string {
	return "web"
}

// RunWithWaitGroup is the legacy method for backward compatibility
// Use Run(ctx) instead for the service interface
func (s *httpServer) RunWithWaitGroup(cleanShutdown *sync.WaitGroup, port string) {
	cleanShutdown.Add(1)

	httpServer := &http.Server{
		Addr:              net.JoinHostPort("0.0.0.0", s.port),
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

func AllowedOrigins() []string {
	return []string{
		"https://jst.dev",
		"https://jst-dev.fly.dev",
		"https://jst-dev-preview.fly.dev",
		"https://server-small-dream-1266.fly.dev",
		"http://localhost:8080",
		"http://127.0.0.1:8080",
		"http://localhost:1234",
		"http://127.0.0.1:1234",
	}
}
