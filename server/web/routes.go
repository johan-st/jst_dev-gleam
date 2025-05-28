package web

import (
	"context"
	"encoding/json"
	"fmt"
	"jst_dev/server/articles"
	"jst_dev/server/jst_log"
	"jst_dev/server/who"
	whoApi "jst_dev/server/who/api"
	"net/http"
	"net/http/httputil"
	"net/url"
	"time"

	"github.com/nats-io/nats.go"
)

const (
	cookieAuth = "jst_dev_who"
	audience   = "jst_dev.who"
)

func routes(mux *http.ServeMux, l *jst_log.Logger, repo articles.ArticleRepo, nc *nats.Conn, jwtSecret string) {

	// Add routes with their respective handlers
	mux.Handle("GET /api/seed", handleSeed(l, repo))
	mux.Handle("GET /api/article/", handleArticleList(l, repo))
	mux.Handle("POST /api/article", handleArticleNew(l, repo))
	mux.Handle("PUT /api/article", handleArticleUpdate(l, repo))
	mux.Handle("GET /api/article/{slug}/", handleArticle(l, repo))

	// auth
	mux.Handle("GET /api/auth", handleAuth(l, nc))
	mux.Handle("GET /api/auth/check", handleAuthCheck(l, nc, jwtSecret))

	// Add catch-all route
	// mux.Handle("/", http.NotFoundHandler())
	mux.Handle("/", handleProxy(l.WithBreadcrumb("proxy"), "http://127.0.0.1:1234"))
}

// --- MIDDLEWARE ---

func logger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Println("logger handler called")
		next.ServeHTTP(w, r)
	})
}

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		// Allow either localhost:1234 or 127.0.0.1:1234
		if origin == "http://localhost:8080" || origin == "http://127.0.0.1:8080" {
			w.Header().Set("Access-Control-Allow-Origin", origin)
		}
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		w.Header().Set("Access-Control-Allow-Credentials", "true") // Required for cookies
		next.ServeHTTP(w, r)
	})
}

func authJwt(jwtSecret string, next http.Handler) http.Handler {

	if jwtSecret == "" {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		jwtCookie, err := r.Cookie(cookieAuth)
		if err != nil {
			next.ServeHTTP(w, r)
			return
		}
		if jwtCookie == nil {
			next.ServeHTTP(w, r)
			return
		}
		if jwtCookie.Value == "" {
			next.ServeHTTP(w, r)
			return
		}
		subject, permissions, err := whoApi.JwtVerify(jwtSecret, audience, jwtCookie.Value)
		if err != nil {
			next.ServeHTTP(w, r)
			return
		}
		ctx := context.WithValue(r.Context(), who.UserKey, whoApi.User{
			ID:          subject,
			Permissions: permissions,
		})

		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// --- HANDLERS ---

func handleProxy(l *jst_log.Logger, targetUrl string) http.Handler {

	l.Debug("handleProxy: parsing target URL: %s\n", targetUrl)
	proxyUrl, err := url.Parse(targetUrl)
	if err != nil {
		l.Error("handleProxy: error parsing target URL: %s\n", err)
		panic(err)
	}
	l.Debug("handleProxy: successfully parsed URL, creating reverse proxy")
	proxy := httputil.NewSingleHostReverseProxy(proxyUrl)

	l.Debug("ready")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		l.Debug("handleProxy: proxying request %s %s to %s\n", r.Method, r.URL.Path, targetUrl)
		proxy.ServeHTTP(w, r)
	})
}

func handleAuth(l *jst_log.Logger, nc *nats.Conn) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		l.Debug("auth handler: cookies=%v\n", r.Cookies())

		req := whoApi.AuthRequest{
			Username: "johan",
			Password: "password",
		}
		reqBytes, err := json.Marshal(req)
		if err != nil {
			l.Debug("auth handler: error marshalling request: %s\n", err)
			http.Error(w, "error marshalling request", http.StatusInternalServerError)
			return
		}
		l.Debug("auth handler: request: %s\n", string(reqBytes))
		l.Debug("auth handler: subject: %s\n", whoApi.Subj.AuthGroup+"."+whoApi.Subj.AuthLogin)

		msg, err := nc.Request(fmt.Sprintf("%s.%s", whoApi.Subj.AuthGroup, whoApi.Subj.AuthLogin), reqBytes, 10*time.Second)
		if err != nil {
			l.Debug("auth handler: error requesting auth: %s\n", err)
			http.Error(w, "error requesting auth", http.StatusInternalServerError)
			return
		}
		l.Debug("auth handler: %s\n", msg.Data)
		resp := whoApi.AuthResponse{}
		err = json.Unmarshal(msg.Data, &resp)
		if err != nil {
			l.Debug("auth handler: error unmarshalling auth response: %s\n", err)
			http.Error(w, "error unmarshalling auth response", http.StatusInternalServerError)
			return
		}

		token := resp.Token
		l.Debug("auth handler: token: %s\n", token)
		subject, permissions, err := whoApi.JwtVerify("jst_dev_secret", audience, token)
		if err != nil {
			l.Debug("auth handler: error verifying jwt: %s\n", err)
			http.Error(w, "error verifying jwt", http.StatusInternalServerError)
			return
		}
		l.Debug("auth handler: subject: %s\n", subject)
		l.Debug("auth handler: permissions: %v\n", permissions)
		l.Debug("auth handler: token: %s\n", token)

		cookie := &http.Cookie{
			Name:  cookieAuth,
			Value: resp.Token,
			// MaxAge:   30 * 60,
			// Path:     "/",
			// Domain:   "http://localhost:8080", // Let browser set the domain
			// HttpOnly: false,
			// Secure:   false,                 // Set to true in production
			// SameSite: http.SameSiteNoneMode, // Changed from Strict for cross-origin
		}
		err = cookie.Valid()
		if err != nil {
			l.Debug("auth handler: error validating cookie: %s\n", err)
			http.Error(w, "error validating cookie", http.StatusInternalServerError)
			return
		}
		http.SetCookie(w, cookie)
		l.Debug("auth handler: setting cookie %s with value length %d\n", cookie.Name, len(cookie.Value))

		respJson(w, resp, http.StatusOK)
	})
}

func handleAuthCheck(l *jst_log.Logger, nc *nats.Conn, jwtSecret string) http.Handler {

	type Resp struct {
		Valid       bool     `json:"valid"`
		Subject     string   `json:"subject"`
		Permissions []string `json:"permissions"`
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, ok := r.Context().Value(who.UserKey).(whoApi.User)
		if !ok {
			respJson(w, Resp{
				Valid:       false,
				Subject:     "",
				Permissions: nil,
			}, http.StatusUnauthorized)
			return
		}
		l.Debug("auth check handler: user: %+v\n", user)

		permissionsList := make([]string, len(user.Permissions))
		for i, permission := range user.Permissions {
			permissionsList[i] = string(permission)
		}
		respJson(w, struct {
			Valid       bool     `json:"valid"`
			Subject     string   `json:"subject"`
			Permissions []string `json:"permissions"`
		}{
			Valid:       true,
			Subject:     user.ID,
			Permissions: permissionsList,
		}, http.StatusOK)
	})
}

// handleSeed creates a handler for seeding the database with test articles
func handleSeed(l *jst_log.Logger, repo articles.ArticleRepo) http.Handler {
	logger := l.WithBreadcrumb("seed")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger.Debug("seed handler called")

		art := articles.TestArticle()
		_, err := repo.Create(art)
		if err != nil {
			logger.Error("failed to put test article in repo: %s", err.Error())
			http.Error(w, "failed to put test article in repo", http.StatusInternalServerError)
			return
		}

		art = articles.NatsAllTheWayDown()
		_, err = repo.Create(art)
		if err != nil {
			logger.Error("failed to put nats all the way down article in repo: %s", err.Error())
			http.Error(w, "failed to put nats all the way down article in repo", http.StatusInternalServerError)
			return
		}

		respJson(w, "seeded", http.StatusOK)
	})
}

// handleArticleList creates a handler for listing all articles
func handleArticleList(l *jst_log.Logger, repo articles.ArticleRepo) http.Handler {
	type Resp struct {
		Articles []articles.ArticleMetadata `json:"articles"`
	}

	logger := l.WithBreadcrumb("article").WithBreadcrumb("list")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		articles, err := repo.AllNoContent()
		if err != nil {
			logger.Error("failed to get all articles: %s", err.Error())
			http.Error(w, "failed to get all articles", http.StatusInternalServerError)
			return
		}
		logger.Debug("articles count: %d", len(articles))
		respJson(w, Resp{Articles: articles}, http.StatusOK)
	})
}

// handleArticle creates a handler for getting a single article by slug
func handleArticle(l *jst_log.Logger, repo articles.ArticleRepo) http.Handler {
	logger := l.WithBreadcrumb("article").WithBreadcrumb("get")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		slug := r.PathValue("slug")
		article, err := repo.Get(slug)
		if err != nil {
			logger.Error("failed to get article: %s", err.Error())
			http.Error(w, "failed to get article", http.StatusInternalServerError)
			return
		}
		if article == nil {
			logger.Info("not found, article \"%s\"", slug)
			http.NotFound(w, r)
			return
		}
		logger.Debug("article: %s (rev: %d)", article.Slug, article.Rev)
		respJson(w, article, http.StatusOK)
	})
}

// handleArticleNew creates a handler for creating a new article
func handleArticleNew(l *jst_log.Logger, repo articles.ArticleRepo) http.Handler {
	type ReqNew struct {
		Slug     string             `json:"slug"`
		Title    string             `json:"title"`
		Subtitle string             `json:"subtitle"`
		Leading  string             `json:"leading"`
		Content  []articles.Content `json:"content"`
	}

	logger := l.WithBreadcrumb("article").WithBreadcrumb("new")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req ReqNew
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			logger.Warn("Failed to decode request", "error", err)
			http.Error(w, "Invalid request body", http.StatusBadRequest)
			return
		}
		rev, err := repo.Create(articles.Article{
			StructVersion: 1,
			Rev:           1,
			Slug:          req.Slug,
			Title:         req.Title,
			Subtitle:      req.Subtitle,
			Leading:       req.Leading,
			Content:       req.Content,
		})
		if err != nil {
			logger.Error("failed to put new article in repo: %v", err)
			http.Error(w, "failed to put new article in repo", http.StatusInternalServerError)
			return
		}
		respJson(w, fmt.Sprintf("%s (rev: %d)", req.Slug, rev), http.StatusOK)
	})
}

// handleArticleUpdate creates a handler for updating an existing article
func handleArticleUpdate(l *jst_log.Logger, repo articles.ArticleRepo) http.Handler {
	type ReqUpdate struct {
		Rev      int                `json:"revision"`
		Slug     string             `json:"slug"`
		Title    string             `json:"title"`
		Subtitle string             `json:"subtitle"`
		Leading  string             `json:"leading"`
		Content  []articles.Content `json:"content"`
	}

	logger := l.WithBreadcrumb("article").WithBreadcrumb("update")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req ReqUpdate
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			logger.Warn("Failed to decode request", "error", err)
			http.Error(w, "Invalid request body", http.StatusBadRequest)
			return
		}
		rev, err := repo.Update(articles.Article{
			StructVersion: 1,
			Rev:           req.Rev,
			Slug:          req.Slug,
			Title:         req.Title,
			Subtitle:      req.Subtitle,
			Leading:       req.Leading,
			Content:       req.Content,
		})
		if err != nil {
			logger.Error("failed to update article in repo: %v", err)
			http.Error(w, fmt.Sprintf("failed to update article in repo: %s", err.Error()), http.StatusInternalServerError)
			return
		}
		respJson(w, fmt.Sprintf("%s (rev: %d)", req.Slug, rev), http.StatusOK)
	})
}

// --- HELPERS ---

// respJson builds and writes a JSON response
func respJson(w http.ResponseWriter, content any, code int) {
	respBytes, err := json.Marshal(content)
	if err != nil {
		http.Error(w, "failed to marshal json", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	w.Write(respBytes)
}
