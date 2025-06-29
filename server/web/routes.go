package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"jst_dev/server/articles"
	"jst_dev/server/jst_log"
	"jst_dev/server/who"
	whoApi "jst_dev/server/who/api"
	"net/http"
	"net/http/httputil"
	"net/url"
	"time"

	"slices"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
)

const (
	cookieAuth = "jst_dev_who"
	audience   = "jst_dev.who"
)

func routes(mux *http.ServeMux, l *jst_log.Logger, repo articles.ArticleRepo, nc *nats.Conn, embeddedFS fs.FS, jwtSecret string, dev bool) {

	// Add routes with their respective handlers
	mux.Handle("GET /api/articles", handleArticleList(l, repo))
	mux.Handle("POST /api/articles", handleArticleNew(l, repo))
	mux.Handle("GET /api/articles/{id}", handleArticle(l, repo))
	mux.Handle("PUT /api/articles/{id}", handleArticleUpdate(l, repo))
	mux.Handle("DELETE /api/articles/{id}", handleArticleDelete(l, repo))
	mux.Handle("GET /api/articles/{id}/revisions", handleArticleRevisions(l, repo))
	mux.Handle("GET /api/articles/{id}/revisions/{revision}", handleArticleRevision(l, repo))

	// auth
	mux.Handle("POST /api/auth", handleAuth(l, nc, jwtSecret))
	mux.Handle("GET /api/auth/logout", handleAuthLogout(l, nc))
	mux.Handle("GET /api/auth", handleAuthCheck(l, nc, jwtSecret))

	// web
	if dev {
		// DEV routes
		mux.Handle("GET /dev/seed", handleSeed(l, repo))   // TODO: remove this
		mux.Handle("GET /dev/purge", handlePurge(l, repo)) // TODO: remove this
		mux.Handle("/", handleProxy(l.WithBreadcrumb("proxy_frontend"), "http://127.0.0.1:1234"))
	} else {
		mux.Handle("GET /", handleStaticFile(l, embeddedFS, "index.html"))
		mux.Handle("GET /static/", handleStaticFS(l, embeddedFS))

	}
}

// --- MIDDLEWARE ---

func logger(l *jst_log.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, ok := r.Context().Value(who.UserKey).(whoApi.User)
		if ok {
			l.Debug("%s %s (%s)", r.Method, r.URL.Path, user.ID)
		} else {
			l.Debug("%s %s (no_user)", r.Method, r.URL.Path)
		}
		next.ServeHTTP(w, r)
	})
}

func cors(_ *jst_log.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin == "http://localhost:8080" || origin == "http://127.0.0.1:8080" {
			w.Header().Set("Access-Control-Allow-Origin", origin)
		} else {
			w.Header().Set("Access-Control-Allow-Origin", "https://server-small-dream-1266.fly.dev")
		}

		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		w.Header().Set("Access-Control-Allow-Credentials", "true") // Required for cookies
		next.ServeHTTP(w, r)
	})
}
func authJwtDummy(jwtSecret string, next http.Handler) http.Handler {
	if jwtSecret == "" {
		panic("no jwt secret specified")
	}
	if next == nil {
		panic("next handler is nil")
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := context.WithValue(r.Context(), who.UserKey, whoApi.User{
			ID:          "TEST_USER",
			Permissions: []whoApi.Permission{whoApi.PermissionPostEditAny},
		})
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func authJwt(jwtSecret string, next http.Handler) http.Handler {
	if jwtSecret == "" {
		panic("no jwt secret specified")
	}
	if next == nil {
		panic("next handler is nil")
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

// handleProxy proxies requests to the target URL
// NOTE: this handler uses the the logger that is passed without adding any breadcrumbs
func handleProxy(l *jst_log.Logger, targetUrl string) http.Handler {

	proxyUrl, err := url.Parse(targetUrl)
	if err != nil {
		l.Error("handleProxy: error parsing target URL: %s\n", err)
		panic(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(proxyUrl)
	proxy.Rewrite = func(r *httputil.ProxyRequest) {
		r.SetXForwarded()
		r.SetURL(proxyUrl)
		r.Out.Host = r.In.Host
	}
	proxy.Director = nil

	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		l.Error("error proxying request: %s\n", err)
		http.Error(w, "error proxying request", http.StatusBadGateway)
	}

	l.Debug("ready (%s)", targetUrl)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		l.Debug("proxying request %s %s to %s\n", r.Method, r.URL.Path, targetUrl)
		proxy.ServeHTTP(w, r)
	})
}

// - auth

func handleAuth(l *jst_log.Logger, nc *nats.Conn, jwtSecret string) http.Handler {
	type Req struct {
		Email    string `json:"email,omitempty"`
		Username string `json:"username,omitempty"`
		Password string `json:"password,omitempty"`
		Token    string `json:"token,omitempty"`
	}
	type Resp struct {
		Subject     string              `json:"subject"`
		ExpiresAt   int64               `json:"expiresAt"`
		Permissions []whoApi.Permission `json:"permissions"`
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		l.Debug("cookies=%v\n", r.Cookies())
		var (
			err      error
			req      Req
			resp     Resp
			whoReq   whoApi.AuthRequest
			whoBytes []byte
			whoMsg   *nats.Msg
			whoResp  whoApi.AuthResponse
			cookie   *http.Cookie
		)

		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			l.Warn("Failed to decode request", "error", err)
			http.Error(w, "Invalid request body", http.StatusBadRequest)
			return
		}
		if req.Token != "" {
			l.Debug("token: %s\n", req.Token)
		} else if req.Email != "" {
			l.Debug("email: %s\n", req.Email)
		} else if req.Username != "" {
			l.Debug("username: %s\n", req.Username)
		}

		whoReq = whoApi.AuthRequest{
			Username: req.Username,
			Email:    req.Email,
			Password: req.Password,
		}
		whoBytes, err = json.Marshal(whoReq)
		if err != nil {
			l.Debug("error marshalling request: %s\n", err)
			http.Error(w, "error marshalling request", http.StatusInternalServerError)
			return
		}
		l.Debug("request: %s\n", string(whoBytes))
		l.Debug("subject: %s\n", whoApi.Subj.AuthGroup+"."+whoApi.Subj.AuthLogin)

		whoMsg, err = nc.Request(fmt.Sprintf("%s.%s", whoApi.Subj.AuthGroup, whoApi.Subj.AuthLogin), whoBytes, 10*time.Second)
		if err != nil {
			l.Debug("error requesting auth: %s\n", err)
			http.Error(w, "error requesting auth", http.StatusInternalServerError)
			return
		}
		l.Debug("msg.Data: %s\n", string(whoMsg.Data))
		err = json.Unmarshal(whoMsg.Data, &whoResp)
		if err != nil {
			l.Debug("error unmarshalling auth response: %s\n", err)
			http.Error(w, "error unmarshalling auth response", http.StatusInternalServerError)
			return
		}

		l.Debug("token: %s\n", whoResp.Token)
		subject, permissions, err := whoApi.JwtVerify(jwtSecret, audience, whoResp.Token)
		if err != nil {
			l.Debug("error verifying jwt: %s\n", err)
			http.Error(w, "error verifying jwt", http.StatusInternalServerError)
			return
		}
		l.Debug("subject: %s\n", subject)
		l.Debug("permissions: %v\n", permissions)
		l.Debug("token: %s\n", whoResp.Token)

		cookie = &http.Cookie{
			Name:     cookieAuth,
			Value:    whoResp.Token,
			MaxAge:   30 * 60,
			Path:     "/",
			HttpOnly: true,
			Secure:   true,
			SameSite: http.SameSiteStrictMode,
		}
		err = cookie.Valid()
		if err != nil {
			l.Debug("error validating cookie: %s\n", err)
			http.Error(w, "error validating cookie", http.StatusInternalServerError)
			return
		}
		http.SetCookie(w, cookie)
		l.Debug("setting cookie %s with value length %d\n", cookie.Name, len(cookie.Value))

		resp.Subject = subject
		resp.Permissions = permissions
		resp.ExpiresAt = time.Now().Add(30 * time.Minute).Unix()

		respJson(w, resp, http.StatusOK)
	})
}

func handleAuthLogout(_ *jst_log.Logger, _ *nats.Conn) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.SetCookie(w, &http.Cookie{Name: cookieAuth, MaxAge: -1, Path: "/"})
	})
}

func handleAuthCheck(l *jst_log.Logger, _ *nats.Conn, _ string) http.Handler {
	type Resp struct {
		Subject     string              `json:"subject"`
		ExpiresAt   int64               `json:"expiresAt"`
		Permissions []whoApi.Permission `json:"permissions"`
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, ok := r.Context().Value(who.UserKey).(whoApi.User)
		if !ok {
			respJson(w, Resp{
				Subject:     "",
				ExpiresAt:   0,
				Permissions: nil,
			}, http.StatusUnauthorized)
			return
		}
		l.Debug("user: %+v\n", user)

		respJson(w, Resp{
			Subject:     user.ID,
			ExpiresAt:   time.Now().Add(30 * time.Minute).Unix(), // Use int64
			Permissions: user.Permissions,
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

func handlePurge(l *jst_log.Logger, repo articles.ArticleRepo) http.Handler {
	logger := l.WithBreadcrumb("purge")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger.Debug("called")
		err := repo.Purge()
		if err != nil {
			logger.Error("failed to purge repo: %s", err.Error())
			http.Error(w, "failed to purge repo", http.StatusInternalServerError)
			return
		}
		respJson(w, "purged", http.StatusOK)
	})
}

// - articles

// handleArticleList creates a handler for listing all articles
func handleArticleList(l *jst_log.Logger, repo articles.ArticleRepo) http.Handler {
	type Resp struct {
		Articles []articles.Article `json:"articles"`
	}

	logger := l.WithBreadcrumb("articles").WithBreadcrumb("list")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger.Debug("called")
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
	logger := l.WithBreadcrumb("articles").WithBreadcrumb("get")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var art articles.Article
		logger.Debug("called")
		id := r.PathValue("id")
		idUuid, err := uuid.Parse(id)
		if err != nil {
			logger.Error("failed to parse id: %s", err.Error())
			http.Error(w, "failed to parse id", http.StatusBadRequest)
			return
		}
		logger.Debug("idUuid: %s", idUuid)
		art, err = repo.Get(idUuid)
		if err != nil {
			logger.Error("failed to get article: %s", err.Error())
			http.Error(w, "failed to get article", http.StatusInternalServerError)
			return
		}
		if art.Id == uuid.Nil {
			logger.Info("not found, article \"%s\"", id)
			http.NotFound(w, r)
			return
		}
		logger.Debug("article: %s (rev: %d)", art.Slug, art.Rev)
		respJson(w, art, http.StatusOK)
	})
}

// handleArticleNew creates a handler for creating a new article
func handleArticleNew(l *jst_log.Logger, repo articles.ArticleRepo) http.Handler {

	logger := l.WithBreadcrumb("articles").WithBreadcrumb("new")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var (
			art = articles.Article{}
		)
		logger.Debug("called")
		if err := json.NewDecoder(r.Body).Decode(&art); err != nil {
			logger.Warn("Failed to decode request", "error", err)
			http.Error(w, "Invalid request body", http.StatusBadRequest)
			return
		}
		art_created, err := repo.Create(art)
		if err != nil {
			logger.Error("failed to Create new article in repo: %v", err)
			http.Error(w, "failed to Create new article in repo", http.StatusInternalServerError)
			return
		}
		if art_created.Id == uuid.Nil {
			logger.Error("article was nil")
			http.Error(w, "article was nil", http.StatusInternalServerError)
			return
		}
		logger.Debug("created article with slug: %s", art_created.Slug)
		respJson(w, art_created, http.StatusOK)
	})
}

// handleArticleUpdate creates a handler for updating an existing article
func handleArticleUpdate(l *jst_log.Logger, repo articles.ArticleRepo) http.Handler {
	logger := l.WithBreadcrumb("articles").WithBreadcrumb("save")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var art articles.Article
		logger.Debug("called")
		id := r.PathValue("id")
		idUuid, err := uuid.Parse(id)
		if err != nil {
			logger.Error("failed to parse id: %s", err.Error())
			http.Error(w, "failed to parse id", http.StatusBadRequest)
			return
		}
		logger.Debug("idUuid: %s", idUuid)
		// Check user permissions
		user, ok := r.Context().Value(who.UserKey).(whoApi.User)
		if !ok {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		hasPermission := slices.Contains(user.Permissions, whoApi.PermissionPostEditAny)
		if !hasPermission {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}

		logger.Debug("permissions ok")
		// Get current article to verify it exists.
		// TODO: not necessary as we can check the update error
		art, err = repo.Get(idUuid)
		if err != nil {
			logger.Error("failed to get current article: %s", err.Error())
			http.Error(w, "failed to get current article", http.StatusInternalServerError)
			return
		}
		if art.Id == uuid.Nil {
			logger.Error("article not found: %s", id)
			http.Error(w, "article not found", http.StatusNotFound)
			return
		}

		// Decode request body
		if err := json.NewDecoder(r.Body).Decode(&art); err != nil {
			logger.Warn("Failed to decode request", "error", err)
			http.Error(w, "Invalid request body", http.StatusBadRequest)
			return
		}

		// Update article using client's revision - preserve all fields
		art, err = repo.Update(articles.Article{
			Id:            idUuid,
			StructVersion: 1,
			Rev:           uint64(art.Rev), // Use client's revision, NATS will handle CAS (Compare and Swap)
			Slug:          art.Slug,
			Title:         art.Title,
			Subtitle:      art.Subtitle,
			Leading:       art.Leading,
			Author:        art.Author,      // Preserve author
			PublishedAt:   art.PublishedAt, // Preserve published date
			Tags:          art.Tags,        // Preserve tags
			Content:       art.Content,
		})
		if err != nil {
			logger.Error("failed to save article in repo: %v", err)
			http.Error(w, fmt.Sprintf("failed to save article in repo: %s", err.Error()), http.StatusInternalServerError)
			return
		}

		logger.Debug("updated article with slug: %s", art.Slug)
		// Return the new revision number
		respJson(w, art, http.StatusOK)
	})
}

// handleArticleDelete creates a handler for deleting an article
func handleArticleDelete(l *jst_log.Logger, repo articles.ArticleRepo) http.Handler {
	logger := l.WithBreadcrumb("articles").WithBreadcrumb("delete")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger.Debug("called")
		id := r.PathValue("id")
		idUuid, err := uuid.Parse(id)
		if err != nil {
			logger.Error("failed to parse id: %s", err.Error())
			http.Error(w, "failed to parse id", http.StatusBadRequest)
			return
		}
		logger.Debug("idUuid: %s", idUuid)
		// Check user permissions
		user, ok := r.Context().Value(who.UserKey).(whoApi.User)
		if !ok {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		hasPermission := slices.Contains(user.Permissions, whoApi.PermissionPostEditAny)
		if !hasPermission {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		logger.Debug("permissions ok")
		err = repo.Delete(idUuid)
		if err != nil {
			logger.Error("failed to delete article: %s", err.Error())
			http.Error(w, "failed to delete article", http.StatusInternalServerError)
			return
		}

		logger.Debug("deleted article: %s", id)
		respJson(w, "deleted", http.StatusOK)
	})
}

// handleArticleRevisions creates a handler for getting all revisions of an article
func handleArticleRevisions(l *jst_log.Logger, repo articles.ArticleRepo) http.Handler {
	logger := l.WithBreadcrumb("article_revisions").WithBreadcrumb("list")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger.Debug("called")
		id := r.PathValue("id")
		idUuid, err := uuid.Parse(id)
		if err != nil {
			logger.Error("failed to parse id: %s", err.Error())
			http.Error(w, "failed to parse id", http.StatusBadRequest)
			return
		}
		logger.Debug("idUuid: %s", idUuid)
		revisions, err := repo.GetHistory(idUuid)
		if err != nil {
			logger.Error("failed to get article revisions: %s", err.Error())
			http.Error(w, "failed to get article revisions", http.StatusInternalServerError)
			return
		}

		logger.Debug("found %d revisions for article: %s", len(revisions), id)
		respJson(w, revisions, http.StatusOK)
	})
}

// handleArticleRevision creates a handler for getting a specific revision of an article
func handleArticleRevision(l *jst_log.Logger, repo articles.ArticleRepo) http.Handler {
	logger := l.WithBreadcrumb("article_revisions").WithBreadcrumb("get")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var art articles.Article
		id := r.PathValue("id")
		revision := r.PathValue("revision")

		logger.Debug("called with id: %s and revision: %s", id, revision)

		idUuid, err := uuid.Parse(id)
		if err != nil {
			logger.Error("failed to parse id: %s", err.Error())
			http.Error(w, "failed to parse id", http.StatusBadRequest)
			return
		}

		// Parse revision as uint64
		var rev uint64
		if _, err := fmt.Sscanf(revision, "%d", &rev); err != nil {
			logger.Error("failed to parse revision: %s", err.Error())
			http.Error(w, "failed to parse revision", http.StatusBadRequest)
			return
		}

		art, err = repo.GetRevision(idUuid, rev)
		if err != nil {
			logger.Error("failed to get article revision: %s", err.Error())
			http.Error(w, "failed to get article revision", http.StatusInternalServerError)
			return
		}
		if art.Id == uuid.Nil {
			logger.Info("not found, article \"%s\" revision %d", id, rev)
			http.NotFound(w, r)
			return
		}

		logger.Debug("article: %s (rev: %d)", art.Slug, art.Rev)
		respJson(w, art, http.StatusOK)
	})
}

func handleStaticFile(l *jst_log.Logger, embeddedFSs fs.FS, filename string) http.Handler {

	logger := l.WithBreadcrumb("static").WithBreadcrumb(filename)

	// Check if file exists and log size, panic if not found
	info, err := fs.Stat(embeddedFSs, filename)
	if err != nil {
		logger.Error("static file not found: %s", filename)
		panic(fmt.Sprintf("static file not found: %s", filename))
	}
	logger.Debug("ready - file size: %d bytes", info.Size())

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger.Debug("called")
		http.ServeFileFS(w, r, embeddedFSs, filename)
	})
}

func handleStaticFS(l *jst_log.Logger, embeddedFS fs.FS) http.Handler {

	logger := l.WithBreadcrumb("static")

	err := fs.WalkDir(embeddedFS, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() {
			info, err := d.Info()
			if err != nil {
				logger.Warn("failed to get info for file %s: %v", path, err)
				return nil
			}
			logger.Debug("found file: %s (size: %d bytes)", path, info.Size())
		}
		return nil
	})
	if err != nil {
		logger.Error("failed to walk directory: %v", err)
		panic(fmt.Sprintf("failed to walk directory: %v", err))
	}
	logger.Debug("ready")

	return http.StripPrefix("/static/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger.Debug("called")
		http.ServeFileFS(w, r, embeddedFS, "/"+r.URL.Path)
	}))
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
