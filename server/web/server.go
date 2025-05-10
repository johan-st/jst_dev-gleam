package web

import (
	"fmt"
	"net/http"
	"strings"
	"sync"
	"text/template"
	"time"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
)

// RoutesStore manages in-memory storage of pages
type RoutesStore struct {
	mu     sync.RWMutex
	routes map[string][]byte
}

// Server handles HTTP requests and manages page content
type Server struct {
	routes     *RoutesStore
	l          *jst_log.Logger
	kv         nats.KeyValue
	wsEcho     *wsServer
	fastestYet time.Duration
}

// NewServer creates a new HTTP server instance
func NewServer(l *jst_log.Logger, kv nats.KeyValue, os nats.ObjectStore) *Server {
	l.Debug("NewServer")
	return &Server{
		routes: &RoutesStore{
			routes: make(map[string][]byte),
		},
		l:          l,
		kv:         kv,
		wsEcho:     newWsServer(l.WithBreadcrumb("ws")),
		fastestYet: 1 * time.Hour,
	}
}

// SetPage stores a page in memory
func (s *Server) routeSet(subject string, page []byte) {
	s.routes.mu.Lock()
	defer s.routes.mu.Unlock()
	s.routes.routes[subject] = page
}

// GetPage retrieves a page from memory
func (s *Server) getPage(subject string) ([]byte, bool) {
	s.routes.mu.RLock()
	defer s.routes.mu.RUnlock()
	page, exists := s.routes.routes[subject]
	return page, exists
}

// DeletePage deletes a page from memory
func (s *Server) routeDelete(subject string) {
	s.routes.mu.Lock()
	defer s.routes.mu.Unlock()
	delete(s.routes.routes, subject)
}

// ServeHTTP implements the http.Handler interface
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var (
		timeStart   time.Time = time.Now()
		timeElapsed time.Duration
		subject     string
		page        []byte
		exists      bool
		tmpl        *template.Template
		err         error
	)

	s.l.Debug(fmt.Sprintf("ServeHTTP %s %s", r.Method, r.URL.Path))

	// handle websockets
	if r.URL.Path == "/ws" {
		s.wsEcho.ServeHTTP(w, r)
		return
	}

	// handle http requests
	if r.Method != http.MethodGet {
		s.l.Debug("Method not allowed")
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	subject = r.URL.Path
	if subject == "/" {
		subject = "index"
	}
	subject = strings.TrimPrefix(subject, "/")
	subject = strings.ReplaceAll(subject, "/", ".")

	s.l.Debug(fmt.Sprintf("getPage subject: %s", subject))
	page, exists = s.getPage(subject)
	if !exists {
		s.l.Warn(fmt.Sprintf("unknown page requested at %s", r.URL.Path))
		http.Error(w, "Page not found", http.StatusNotFound)
		return
	}

	tmpl, err = template.New("template").Parse(string(page))
	if err != nil {
		s.l.Error(fmt.Sprintf("Parse:%e", err))
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	s.l.Debug("Page found. Rendering...")
	w.Header().Set("Content-Type", "text/plain")
	// w.Header().Set("Content-Type", "text/html")

	err = tmpl.Execute(w, nil)
	if err != nil {
		s.l.Error(fmt.Sprintf("Execute:%e", err))
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	timeElapsed = time.Since(timeStart)
	if timeElapsed == 0 {
		s.l.Debug(fmt.Sprintf("page %s was served faster than we could measure!", subject))
	} else {
		if timeElapsed < s.fastestYet {
			s.fastestYet = timeElapsed
		}
		s.l.Debug(fmt.Sprintf("page %s was served in %s (fastest yet: %s)", subject, timeElapsed, s.fastestYet))
	}
}

func (s *Server) Start(port int) error {
	s.l.Debug("creating watcher")
	watcher, err := s.kv.WatchAll()
	if err != nil {
		return fmt.Errorf("create watcher: %s", err)
	}
	go routesWatcher(s, watcher, s.l.WithBreadcrumb("updates"))

	// start http server
	addr := fmt.Sprintf(":%d", port)
	s.l.Info(fmt.Sprintf("listening on %s", addr))
	return http.ListenAndServe(addr, s)
}

func routesWatcher(s *Server, w nats.KeyWatcher, l *jst_log.Logger) {
	defer w.Stop()
	for entry := range w.Updates() {
		if entry == nil {
			l.Debug("loaded %d routes", len(s.routes.routes))
			continue
		}

		switch entry.Operation() {
		case nats.KeyValuePut:
			l.Debug(fmt.Sprintf("PUT - %s", entry.Key()))
			s.routeSet(entry.Key(), entry.Value())
		case nats.KeyValueDelete:
			l.Debug(fmt.Sprintf("DELETE - %s", entry.Key()))
			s.routeDelete(entry.Key())
		case nats.KeyValuePurge:
			l.Debug(fmt.Sprintf("PURGE - %s - noop", entry.Key()))
		default:
			l.Debug(fmt.Sprintf("unknown operation: %s", entry.Operation()))

		}
	}
	l.Info("watcher stopped")
}
