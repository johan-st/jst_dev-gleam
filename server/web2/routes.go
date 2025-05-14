package web2

import (
	"encoding/json"
	"io/fs"
	"net/http"
)

func (s *httpServer) routes() {
	s.mux = *http.NewServeMux()
	// s.mux.HandleFunc("/", s.handlerTodo("catch-all"))
	s.mux.HandleFunc("/api/article/", s.handlerArticleList())
	s.mux.HandleFunc("/api/article/{id}/", s.handlerArticle())
}

func (s *httpServer) handlerArticleList() http.HandlerFunc {
	l := s.l.WithBreadcrumb("articleList")

	return func(w http.ResponseWriter, r *http.Request) {
		indexContent, err := fs.ReadFile(s.embedFs, "article/index.json")
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

func (s *httpServer) handlerArticle() http.HandlerFunc {
	l := s.l.WithBreadcrumb("handlers.article")
	l.Debug("ready")

	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		article := s.articleRepo.GetById(id)
		if article == nil {
			l.Info("not found, article id \"%s\"", id)
			http.NotFound(w, r)
			return
		}

		// filePath := "article/" + id + ".json"
		// articleContent, err := fs.ReadFile(s.embedFs, filePath)
		// if err != nil {
		// 	l.Error("Failed to read article file", "id", id, "error", err)
		// 	http.NotFound(w, r)
		// 	return
		// }
		articleJson, err := json.Marshal(article)
		if err != nil {
			l.Error("Marshal error %s", err.Error())
			http.Error(w, err.Error(), 500)
			return
		}
		// todo: respJson(any, code)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write(articleJson)
		l.Debug("served article \"%s\"", id)
	}
}

func (s *httpServer) handlerTodo(name string) http.HandlerFunc {
	l := s.l.WithBreadcrumb(name)
	l.Debug("ready")

	return func(w http.ResponseWriter, r *http.Request) {
		l.Error("Todo handler called")
		l.Debug("path: %s", r.URL.Path)
	}
}
