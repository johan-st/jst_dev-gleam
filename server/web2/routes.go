package web2

import (
	"encoding/json"
	"jst_dev/server/articles"
	"net/http"
)

func (s *httpServer) routes() {
	s.mux = *http.NewServeMux()
	// s.mux.HandleFunc("/", s.handlerTodo("catch-all"))
	s.mux.HandleFunc("GET /api/seed", s.handlerSeed())
	s.mux.HandleFunc("GET /api/article/", s.handlerArticleList())
	s.mux.HandleFunc("POST /api/article", s.handlerArticleNew())
	s.mux.HandleFunc("PUT /api/article", s.handlerArticleUpdate())
	s.mux.HandleFunc("GET /api/article/{slug}/", s.handlerArticle())
}

func (s *httpServer) handlerSeed() http.HandlerFunc {
	l := s.l.WithBreadcrumb("handlers").WithBreadcrumb("seed")
	l.Debug("ready")
	return func(w http.ResponseWriter, r *http.Request) {
		l.Debug("seed handler called")
		if err := s.articleRepo.Put(articles.TestArticle(), 0); err != nil {
			l.Error("failed to put test article in repo: %w", err)
			http.Error(w, "failed to put test article in repo", http.StatusInternalServerError)
			return
		}
		if err := s.articleRepo.Put(articles.NatsAllTheWayDown(), 0); err != nil {
			l.Error("failed to put nats all the way down article in repo: %w", err)
			http.Error(w, "failed to put nats all the way down article in repo", http.StatusInternalServerError)
			return
		}
		s.respJson(w, "seeded", http.StatusOK)
	}
}

func (s *httpServer) handlerArticleList() http.HandlerFunc {
	type Resp struct {
		Articles []articles.ArticleMetadata `json:"articles"`
	}

	l := s.l.WithBreadcrumb("handlers").WithBreadcrumb("article").WithBreadcrumb("list")

	return func(w http.ResponseWriter, r *http.Request) {
		articles := s.articleRepo.AllNoContent()
		l.Debug("articles count: %d", len(articles))
		s.respJson(w, Resp{Articles: articles}, http.StatusOK)
	}
}

func (s *httpServer) handlerArticle() http.HandlerFunc {
	l := s.l.WithBreadcrumb("handlers").WithBreadcrumb("article").WithBreadcrumb("get")
	l.Debug("ready")

	return func(w http.ResponseWriter, r *http.Request) {
		slug := r.PathValue("slug")
		article := s.articleRepo.Get(slug)
		if article == nil {
			l.Info("not found, article \"%s\"", slug)
			http.NotFound(w, r)
			return
		}
		l.Debug("article: %s", article.Slug)
		s.respJson(w, article, http.StatusOK)
	}
}

func (s *httpServer) handlerArticleNew() http.HandlerFunc {
	type ReqNew struct {
		Slug     string             `json:"slug"`
		Title    string             `json:"title"`
		Subtitle string             `json:"subtitle"`
		Leading  string             `json:"leading"`
		Content  []articles.Content `json:"content"`
	}

	l := s.l.WithBreadcrumb("handlers").WithBreadcrumb("article").WithBreadcrumb("new")
	l.Debug("ready")

	return func(w http.ResponseWriter, r *http.Request) {
		var req ReqNew
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			l.Warn("Failed to decode request", "error", err)
			http.Error(w, "Invalid request body", http.StatusBadRequest)
			return
		}
		err := s.articleRepo.Put(articles.Article{
			StructVersion: 1,
			Slug:          req.Slug,
			Title:         req.Title,
			Subtitle:      req.Subtitle,
			Leading:       req.Leading,
			Content:       req.Content,
		}, 0)
		if err != nil {
			l.Error("failed to put new article in repo: %w", err)
			http.Error(w, "failed to put new article in repo", http.StatusInternalServerError)
		}
	}
}
func (s *httpServer) handlerArticleUpdate() http.HandlerFunc {
	type ReqUpdate struct {
		Rev      int                `json:"revision"`
		Slug     string             `json:"slug"`
		Title    string             `json:"title"`
		Subtitle string             `json:"subtitle"`
		Leading  string             `json:"leading"`
		Content  []articles.Content `json:"content"`
	}

	l := s.l.WithBreadcrumb("handlers").WithBreadcrumb("article").WithBreadcrumb("update")
	l.Debug("ready")

	return func(w http.ResponseWriter, r *http.Request) {
		var req ReqUpdate
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			l.Warn("Failed to decode request", "error", err)
			http.Error(w, "Invalid request body", http.StatusBadRequest)
			return
		}
		err := s.articleRepo.Put(articles.Article{
			StructVersion: 1,
			Rev:           req.Rev,
			Slug:          req.Slug,
			Title:         req.Title,
			Subtitle:      req.Subtitle,
			Leading:       req.Leading,
			Content:       req.Content,
		}, req.Rev)
		if err != nil {
			l.Error("failed to put new article in repo: %w", err)
			http.Error(w, "failed to put new article in repo", http.StatusInternalServerError)
		}
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

// --- RESPONDERS ---

// build and write the response
func (s *httpServer) respJson(w http.ResponseWriter, content any, code int) {
	respBytes, err := json.Marshal(content)
	if err != nil {
		s.l.Error("failed to marchal json")
		http.Error(w, "failed to marshal json", http.StatusInternalServerError)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	w.Write(respBytes)
}
