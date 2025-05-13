package web2

import (
	"context"
	"embed"
	"io/fs"
	"jst_dev/server/jst_log"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/nats-io/nats.go"
)

type httpServer struct {
	l        jst_log.Logger
	ctx      context.Context
	articles map[string]byte
	mux      http.ServeMux
	embedFs  fs.FS
}

//go:embed static
var embedded embed.FS

func New(ctx context.Context, nc *nats.Conn, l jst_log.Logger) *httpServer {
	fs, err := fs.Sub(embedded, "static")
	if err != nil {
		l.Error("Failed to load static folder")
		return nil
	}
	s := &httpServer{ctx: ctx, l: l, embedFs: fs}
	s.routes()

	return s
}

func (s *httpServer) Run(cleanShutdown *sync.WaitGroup) {
	cleanShutdown.Add(1)

	httpServer := &http.Server{
		Addr:    net.JoinHostPort("", "8080"),
		Handler: &s.mux,
	}
	go func() {
		s.l.Info("listening on %s\n", httpServer.Addr)
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
