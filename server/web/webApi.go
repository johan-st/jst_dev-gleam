package web

import (
	"embed"
	"jst_dev/server/jst_log"
	"net/http"
	"os"
	"strings"

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
}

//go:embed webApiData
var assets embed.FS

func NewApiHandler(l *jst_log.Logger, kv nats.KeyValue, os nats.ObjectStore) ApiHandler {
	embedded, err := fs.Sub(assets, "webApiData")
	if err != nil {
		panic(err)
	}

	// // Print content of index.json for debugging
	// indexContent, err := fs.ReadFile(embedded, "article/index.json")
	// if err != nil {
	// 	l.Error("Failed to read index.json", "error", err)
	// } else {
	// 	l.Info("Index.json content", "content", string(indexContent))
	// }

	return &apiHandler{
		l:        l,
		kv:       kv,
		os:       os,
		embedded: embedded,
	}
}
func (h *apiHandler) GetVersion() string {
	return "1.0.0"
}

func (h *apiHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.l.Info("API request received", "path", r.URL.Path, "method", r.Method)

	// Set common headers
	w.Header().Set("Content-Type", "application/json")

	// Handle article requests
	if strings.HasPrefix(r.URL.Path, "/article") {
		pathParts := strings.Split(strings.TrimPrefix(r.URL.Path, "/article"), "/")

		// If path is just /article or /article/ serve the index
		if len(pathParts) <= 1 || pathParts[1] == "" {
			h.l.Info("Serving article index")
			indexContent, err := fs.ReadFile(h.embedded, "article/index.json")
			if err != nil {
				h.l.Error("Failed to read article index", "error", err)
				http.Error(w, "Internal server error", http.StatusInternalServerError)
				return
			}

			w.WriteHeader(http.StatusOK)
			w.Write(indexContent)
			return
		}
		id := pathParts[1]
		h.l.Info("Serving article", "id", id)
		// Check if the article file exists
		articlePath := "article/" + id + ".json"
		_, err := fs.Stat(h.embedded, articlePath)
		if err != nil {
			if os.IsNotExist(err) {
				h.l.Warn("Article not found", "id", id)
				http.Error(w, "Article not found", http.StatusNotFound)
				return
			}
			h.l.Error("Failed to check article existence", "error", err)
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}
		articleContent, err := fs.ReadFile(h.embedded, "article/"+id+".json")
		if err != nil {
			h.l.Error("Failed to read article", "error", err)
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		w.Write(articleContent)
		return
	}

	// If we get here, the path wasn't handled
	h.l.Warn("Unhandled API path", "path", r.URL.Path)
	http.Error(w, "Not found", http.StatusNotFound)
}
