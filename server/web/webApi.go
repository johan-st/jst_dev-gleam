package web

import (
	"embed"
	"jst_dev/server/jst_log"
	"net/http"

	"io/fs"

	"github.com/nats-io/nats.go"
)

type ApiHandler interface {
	ServeHTTP(w http.ResponseWriter, r *http.Request)
	GetVersion() string
}

type apiHandler struct {
	l        *jst_log.Logger
	kv       nats.KeyValue
	os       nats.ObjectStore
	embedded fs.FS
	mux      http.ServeMux
}

func (h *apiHandler) routes() {
	mux := *http.NewServeMux()
	mux.HandleFunc("/articles", h.handlerArticles())
	mux.HandleFunc("/article/{id}", h.handlerArticle())
}

//go:embed webApiData
var assets embed.FS

func NewApiHandler(l *jst_log.Logger, kv nats.KeyValue, os nats.ObjectStore) ApiHandler {
	embedded, err := fs.Sub(assets, "webApiData")
	if err != nil {
		panic(err)
	}
	handler := &apiHandler{
		l:        l.WithBreadcrumb("api"),
		kv:       kv,
		os:       os,
		embedded: embedded,
	}
	handler.routes()
	return handler
}
func (h *apiHandler) GetVersion() string {
	return "1.0.0"
}

func (h *apiHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.l.Info("API request received", "path", r.URL.Path, "method", r.Method)
	h.mux.ServeHTTP(w, r)

}

func (h *apiHandler) handlerArticles() http.HandlerFunc {
	l := h.l.WithBreadcrumb("articles")

	return func(w http.ResponseWriter, r *http.Request) {
		indexContent, err := fs.ReadFile(h.embedded, "article/index.json")
		if err != nil {
			l.Error("Failed to read article index", "error", err)
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
		w.Write(indexContent)
		return

	}
}

func (h *apiHandler) handlerArticle() http.HandlerFunc {
	l := h.l.WithBreadcrumb("article")
	return func(w http.ResponseWriter, r *http.Request) {
		id, ok := r.Context().Value("id").(string)
		if !ok {
			l.Warn("Failed to get id value from context")
			http.NotFound(w, r)
			return
		}

		filePath := "article/" + id + ".json"

		articleContent, err := fs.ReadFile(h.embedded, filePath)
		if err != nil {
			l.Error("Failed to read article file", "id", id, "error", err)
			http.NotFound(w, r)
			return
		}

		w.Header().Set("Content-Type", "application/json")

		w.WriteHeader(http.StatusOK)
		w.Write(articleContent)
	}
}
