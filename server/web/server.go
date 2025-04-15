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

// PageStore manages in-memory storage of pages
type PageStore struct {
	mu    sync.RWMutex
	pages map[string][]byte
}

// Server handles HTTP requests and manages page content
type Server struct {
	store *PageStore
	l     *jst_log.Logger
	kv    nats.KeyValue
}

// NewServer creates a new HTTP server instance
func NewServer(lParent *jst_log.Logger, kv nats.KeyValue, os nats.ObjectStore) *Server {
	l := lParent.WithBreadcrumb("HttpServer")
	l.Debug("NewServer")
	return &Server{
		store: &PageStore{
			pages: make(map[string][]byte),
		},
		l:  l,
		kv: kv,
	}
}

// SetPage stores a page in memory
func (s *Server) setPage(subject string, page []byte) {
	s.store.mu.Lock()
	defer s.store.mu.Unlock()
	s.store.pages[subject] = page
}

// GetPage retrieves a page from memory
func (s *Server) getPage(subject string) ([]byte, bool) {
	s.store.mu.RLock()
	defer s.store.mu.RUnlock()
	page, exists := s.store.pages[subject]
	return page, exists
}

// ServeHTTP implements the http.Handler interface
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	timeStart := time.Now()
	s.l.Debug(fmt.Sprintf("ServeHTTP %s %s", r.Method, r.URL.Path))
	if r.Method != http.MethodGet {
		s.l.Debug("Method not allowed")
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	subject := r.URL.Path
	if subject == "/" {
		subject = "index"
	}
	subject = strings.TrimPrefix(subject, "/")
	subject = strings.ReplaceAll(subject, "/", ".")

	s.l.Debug(fmt.Sprintf("getPage subject: %s", subject))
	page, exists := s.getPage(subject)
	if !exists {
		s.l.Warn(fmt.Sprintf("unknown page requested at %s", r.URL.Path))
		http.Error(w, "Page not found", http.StatusNotFound)
		return
	}

	tmpl, err := template.New("template").Parse(string(page))
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
	s.l.Debug(fmt.Sprintf("Page written in %s", time.Since(timeStart)))
}

// Start begins listening for HTTP requests on the specified port
func (s *Server) Start(port int) error {
	s.l.Debug("loading pages")
	// get all pages
	keys, err := s.kv.ListKeys()
	if err != nil {
		s.l.Error(fmt.Sprintf("ListKeys:%e", err))
		return err
	}
	for key := range keys.Keys() {
		s.l.Debug(fmt.Sprintf("key:%s", key))
		page, err := s.kv.Get(key)
		if err != nil {
			s.l.Error(fmt.Sprintf("Get:%e", err))
			return err
		}
		s.setPage(key, page.Value())
	}
	s.l.Info(fmt.Sprintf("loaded %d pages", len(s.store.pages)))
	keysBytes := []byte("registered routes: ")
	for key := range s.store.pages {
		keysBytes = append(keysBytes, []byte(key+", ")...)
	}
	s.l.Debug(string(keysBytes))

	go pagesWatcher(s)

	addr := fmt.Sprintf(":%d", port)
	s.l.Info(fmt.Sprintf("listening on %s", addr))
	return http.ListenAndServe(addr, s)
}

func pagesWatcher(s *Server) {
	l := s.l.WithBreadcrumb("pagesWatcher")
	l.Debug("Watch")

	opts := []nats.WatchOpt{
		nats.UpdatesOnly(),
	}
	watcher, err := s.kv.WatchAll(opts...)
	if err != nil {
		panic(err)
	}
	defer watcher.Stop()

	for entry := range watcher.Updates() {
		timeStart := time.Now()
		l.Debug(fmt.Sprintf("page @ %s updated", entry.Key()))
		s.setPage(entry.Key(), entry.Value())
		l.Debug(fmt.Sprintf("setPage in %s", time.Since(timeStart)))

	}
}
