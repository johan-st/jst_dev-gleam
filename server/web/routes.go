package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"net/http/httputil"
	"net/url"
	"time"

	"slices"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"

	"jst_dev/server/articles"
	"jst_dev/server/jst_log"
	"jst_dev/server/ntfy"
	shortUrlApi "jst_dev/server/urlShort/api"
	"jst_dev/server/who"
	whoApi "jst_dev/server/who/api"
)

const (
	cookieAuth = "jst_dev_who"
	audience   = "jst_dev.who"
)

func routes(mux *http.ServeMux, l *jst_log.Logger, repo articles.ArticleRepo, nc *nats.Conn, embeddedFS fs.FS, jwtSecret string, dev bool) {
	// Add routes with their respective handlers
	mux.Handle("GET /api/articles", handleArticleList(l, repo))
	mux.Handle("POST /api/articles", handleArticleNew(l, repo, nc))
	mux.Handle("GET /api/articles/{id}", handleArticle(l, repo))
	mux.Handle("PUT /api/articles/{id}", handleArticleUpdate(l, repo))
	mux.Handle("DELETE /api/articles/{id}", handleArticleDelete(l, repo))
	mux.Handle("GET /api/articles/{id}/revisions", handleArticleRevisions(l, repo))
	mux.Handle("GET /api/articles/{id}/revisions/{revision}", handleArticleRevision(l, repo))

	// auth
	mux.Handle("POST /api/auth", handleAuth(l, nc, jwtSecret))
	mux.Handle("POST /api/auth/refresh", handleAuthRefresh(l, nc, jwtSecret))
	mux.Handle("GET /api/auth/logout", handleAuthLogout(l, nc))
	mux.Handle("GET /api/auth", handleAuthCheck(l, nc, jwtSecret))

	// user profile by id (use JWT subject to authorize)
	mux.Handle("GET /api/users/{id}", handleUserGetByID(l, nc))
	mux.Handle("PUT /api/users/{id}", handleUserUpdateByID(l, nc))

	// short urls
	mux.Handle("GET /api/url", handleShortUrlList(l, nc))
	mux.Handle("POST /api/url", handleShortUrlCreate(l, nc))
	mux.Handle("GET /api/url/{id}", handleShortUrlGet(l, nc))
	mux.Handle("PUT /api/url/{id}", handleShortUrlUpdate(l, nc))
	mux.Handle("DELETE /api/url/{id}", handleShortUrlDelete(l, nc))
	mux.Handle("GET /u/{shortCode}", handleShortUrlRedirect(l, nc))
	mux.Handle("GET u.jst.dev/{shortCode}", handleShortUrlRedirect(l, nc))
	mux.Handle("GET url.jst.dev/{shortCode}", handleShortUrlRedirect(l, nc))

	// notifications
	mux.Handle("POST /api/notifications", handleNotificationSend(l, nc))

	// web
	if dev {
		// DEV routes
		mux.Handle("GET /dev/seed", handleSeed(l, repo))   // TODO: remove this
		mux.Handle("GET /dev/purge", handlePurge(l, repo)) // TODO: remove this
		mux.Handle("/", handleProxy(l.WithBreadcrumb("proxy_frontend"), "http://127.0.0.1:1234"))
	} else {
		mux.Handle("GET /", handleStaticFsFile(l, embeddedFS, "index.html"))
		mux.Handle("GET /static/", handleStaticFs(l, embeddedFS))
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

// authJwt middleware validates JWT tokens from cookies and sets user context
//
// get user with:
//
//	user, ok := r.Context().Value(who.UserKey).(whoApi.User)
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
//
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

// handleAuthRefresh refreshes JWT using the current auth cookie.
// It verifies the existing token, then asks who service to mint a fresh one for the same subject.
func handleAuthRefresh(l *jst_log.Logger, nc *nats.Conn, jwtSecret string) http.Handler {
	type Resp struct {
		Subject     string              `json:"subject"`
		ExpiresAt   int64               `json:"expiresAt"`
		Permissions []whoApi.Permission `json:"permissions"`
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var (
			err      error
			cookie   *http.Cookie
			whoReq   whoApi.AuthRefreshRequest
			whoBytes []byte
			whoMsg   *nats.Msg
			whoResp  whoApi.AuthResponse
			resp     Resp
		)

		// Validate current cookie
		jwtCookie, err := r.Cookie(cookieAuth)
		if err != nil || jwtCookie == nil || jwtCookie.Value == "" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		subject, _, err := whoApi.JwtVerify(jwtSecret, audience, jwtCookie.Value)
		if err != nil {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		// Request refreshed token from who
		whoReq = whoApi.AuthRefreshRequest{Subject: subject}
		whoBytes, err = json.Marshal(whoReq)
		if err != nil {
			http.Error(w, "error marshalling request", http.StatusInternalServerError)
			return
		}
		whoMsg, err = nc.Request(fmt.Sprintf("%s.%s", whoApi.Subj.AuthGroup, whoApi.Subj.AuthRefresh), whoBytes, 10*time.Second)
		if err != nil {
			http.Error(w, "error requesting auth refresh", http.StatusInternalServerError)
			return
		}
		if whoMsg.Header.Get("Nats-Service-Error") != "" {
			http.Error(w, string(whoMsg.Data), http.StatusBadGateway)
			return
		}
		if err := json.Unmarshal(whoMsg.Data, &whoResp); err != nil {
			http.Error(w, "error unmarshalling refresh response", http.StatusInternalServerError)
			return
		}

		// Verify refreshed token and set cookie
		subject2, permissions2, err := whoApi.JwtVerify(jwtSecret, audience, whoResp.Token)
		if err != nil {
			http.Error(w, "error verifying jwt", http.StatusInternalServerError)
			return
		}

		cookie = &http.Cookie{
			Name:     cookieAuth,
			Value:    whoResp.Token,
			MaxAge:   30 * 60,
			Path:     "/",
			HttpOnly: true,
			Secure:   true,
			SameSite: http.SameSiteStrictMode,
		}
		if err := cookie.Valid(); err != nil {
			http.Error(w, "error validating cookie", http.StatusInternalServerError)
			return
		}
		http.SetCookie(w, cookie)

		resp.Subject = subject2
		resp.Permissions = permissions2
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
			ExpiresAt:   time.Now().Add(30 * time.Minute).Unix(), // Unix seconds
			Permissions: user.Permissions,
		}, http.StatusOK)
	})
}

// - user (me)

func handleUserGetByID(l *jst_log.Logger, nc *nats.Conn) http.Handler {
	type Resp whoApi.UserFullResponse

	logger := l.WithBreadcrumb("user").WithBreadcrumb("get")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var (
			msg    *nats.Msg
			err    error
			whoReq whoApi.UserGetRequest
			whoRes Resp
		)

		authUser, ok := r.Context().Value(who.UserKey).(whoApi.User)
		if !ok || authUser.ID == "" {
			http.Error(w, "not authorized", http.StatusUnauthorized)
			return
		}
		id := r.PathValue("id")
		if id == "" {
			http.Error(w, "invalid id", http.StatusBadRequest)
			return
		}
		if authUser.ID != id {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}

		whoReq = whoApi.UserGetRequest{ID: id}
		reqBytes, err := json.Marshal(whoReq)
		if err != nil {
			logger.Error("failed to marshal who request: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}

		msg, err = nc.Request(whoApi.Subj.UserGroup+"."+whoApi.Subj.UserGet, reqBytes, 5*time.Second)
		if err != nil {
			logger.Error("failed to request who: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if err := json.Unmarshal(msg.Data, &whoRes); err != nil {
			logger.Error("failed to unmarshal who response: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}

		respJson(w, whoRes, http.StatusOK)
	})
}

func handleUserUpdateByID(l *jst_log.Logger, nc *nats.Conn) http.Handler {
	type Req struct {
		Username    string `json:"username,omitempty"`
		Email       string `json:"email,omitempty"`
		Password    string `json:"password,omitempty"`
		OldPassword string `json:"oldPassword,omitempty"`
	}
	type Resp whoApi.UserUpdateResponse

	logger := l.WithBreadcrumb("user").WithBreadcrumb("update")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var (
			req    Req
			err    error
			msg    *nats.Msg
			whoReq whoApi.UserUpdateRequest
			whoRes Resp
		)

		authUser, ok := r.Context().Value(who.UserKey).(whoApi.User)
		if !ok || authUser.ID == "" {
			http.Error(w, "not authorized", http.StatusUnauthorized)
			return
		}
		id := r.PathValue("id")
		if id == "" {
			http.Error(w, "invalid id", http.StatusBadRequest)
			return
		}
		if authUser.ID != id {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}

		if err = json.NewDecoder(r.Body).Decode(&req); err != nil {
			logger.Warn("failed to decode request: %v", err)
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}

		whoReq = whoApi.UserUpdateRequest{
			ID:          id,
			Username:    req.Username,
			Email:       req.Email,
			Password:    req.Password,
			OldPassword: req.OldPassword,
		}
		reqBytes, err := json.Marshal(whoReq)
		if err != nil {
			logger.Error("failed to marshal who request: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}

		msg, err = nc.Request(whoApi.Subj.UserGroup+"."+whoApi.Subj.UserUpdate, reqBytes, 5*time.Second)
		if err != nil {
			logger.Error("failed to request who: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}
		if err := json.Unmarshal(msg.Data, &whoRes); err != nil {
			logger.Error("failed to unmarshal who response: %v", err)
			http.Error(w, "server error", http.StatusInternalServerError)
			return
		}

		respJson(w, whoRes, http.StatusOK)
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
// We do not use any information from the Post request body when
// creating the new article.
func handleArticleNew(l *jst_log.Logger, repo articles.ArticleRepo, nc *nats.Conn) http.Handler {
	logger := l.WithBreadcrumb("articles").WithBreadcrumb("new")
	logger.Debug("ready")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var (
			art articles.Article
			// whoResp whoApi.UserFullResponse
		)
		logger.Debug("called")

		// get and check user permissions
		user, ok := r.Context().Value(who.UserKey).(whoApi.User)
		if !ok {
			logger.Warn("user not found in context")
			http.Error(w, "not allowed", http.StatusForbidden)
			return
		}
		if !user.Permissions.Includes(whoApi.PermissionPostEditAny) {
			logger.Warn("user does not have create_article permission")
			http.Error(w, "not allowed", http.StatusForbidden)
			return
		}

		// get full user
		whoReq, err := json.Marshal(whoApi.UserGetRequest{
			ID: user.ID,
		})
		if err != nil {
			logger.Error("failed to marshal user request: %v", err)
			http.Error(w, "failed to marshal user request", http.StatusInternalServerError)
			return
		}
		msg, err := nc.Request(
			whoApi.Subj.UserGroup+"."+whoApi.Subj.UserGet,
			whoReq,
			5*time.Second,
		)
		if err != nil {
			logger.Error("failed to get user data: %w", err)
			http.Error(w, "failed to get user data", http.StatusInternalServerError)
			return
		}
		err = json.Unmarshal(msg.Data, &user)
		if err != nil {
			logger.Error("failed to unmarshal user data: %v", err)
			http.Error(w, "failed to unmarshal user data", http.StatusInternalServerError)
			return
		}

		// build article and save it in repo
		art.Id = uuid.New()
		art.Slug = art.Id.String()
		art.Author = user.Username
		art.Tags = []string{"new"}
		art.Content = "no content yet"
		art.Title = "new article"
		art.Subtitle = ""
		art.Leading = "One paragraph summary/ eyecatching synopsis."
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

		// log and respond
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

func handleStaticFsFile(l *jst_log.Logger, embeddedFSs fs.FS, filename string) http.Handler {
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

func handleStaticFs(l *jst_log.Logger, embeddedFS fs.FS) http.Handler {
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

// - short urls

// handleShortUrlList creates a handler for listing short URLs
func handleShortUrlList(l *jst_log.Logger, nc *nats.Conn) http.Handler {
	logger := l.WithBreadcrumb("shorturls").WithBreadcrumb("list")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger.Debug("called")

		// Get user from context
		// user, ok := r.Context().Value(who.UserKey).(whoApi.User)
		// if !ok {
		// 	logger.Warn("user not found in context")
		// 	http.Error(w, "unauthorized", http.StatusUnauthorized)
		// 	return
		// }

		// Parse query parameters
		createdBy := r.URL.Query().Get("createdBy")
		limit := 50
		offset := 0
		if limitStr := r.URL.Query().Get("limit"); limitStr != "" {
			if l, err := fmt.Sscanf(limitStr, "%d", &limit); err != nil || l != 1 {
				http.Error(w, "invalid limit parameter", http.StatusBadRequest)
				return
			}
		}
		if offsetStr := r.URL.Query().Get("offset"); offsetStr != "" {
			if o, err := fmt.Sscanf(offsetStr, "%d", &offset); err != nil || o != 1 {
				http.Error(w, "invalid offset parameter", http.StatusBadRequest)
				return
			}
		}

		// If no createdBy specified, use current user
		// if createdBy == "" {
		// 	createdBy = user.ID
		// }

		// Create request
		req := shortUrlApi.ShortUrlListRequest{
			CreatedBy: createdBy,
			Limit:     limit,
			Offset:    offset,
		}

		reqBytes, err := json.Marshal(req)
		if err != nil {
			logger.Error("failed to marshal request: %v", err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
			return
		}

		// Send request to short URL service
		msg, err := nc.Request(
			shortUrlApi.Subj.ShortUrlGroup+"."+shortUrlApi.Subj.ShortUrlList,
			reqBytes,
			5*time.Second,
		)
		if err != nil {
			logger.Error("failed to request short urls: %v", err)
			http.Error(w, "failed to get short urls", http.StatusInternalServerError)
			return
		}

		// Parse response
		var resp shortUrlApi.ShortUrlListResponse
		if err := json.Unmarshal(msg.Data, &resp); err != nil {
			logger.Error("failed to unmarshal response: %v", err)
			http.Error(w, "failed to parse response", http.StatusInternalServerError)
			return
		}

		logger.Debug("found %d short urls", len(resp.ShortUrls))
		respJson(w, resp, http.StatusOK)
	})
}

// handleShortUrlCreate creates a handler for creating new short URLs
func handleShortUrlCreate(l *jst_log.Logger, nc *nats.Conn) http.Handler {
	logger := l.WithBreadcrumb("shorturls").WithBreadcrumb("create")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger.Debug("called")

		// Parse request body
		var req shortUrlApi.ShortUrlCreateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			logger.Warn("failed to decode request: %v", err)
			http.Error(w, "invalid request body", http.StatusBadRequest)
			return
		}

		// Get user from context and set created by
		user, ok := r.Context().Value(who.UserKey).(whoApi.User)
		if ok && user.ID != "" {
			req.CreatedBy = user.ID
			logger.Debug("using authenticated user: %s", user.ID)
		} else {
			logger.Debug("no authenticated user, createdBy will be empty")
		}

		// Validate required fields
		if req.TargetURL == "" {
			http.Error(w, "target URL is required", http.StatusBadRequest)
			return
		}

		reqBytes, err := json.Marshal(req)
		if err != nil {
			logger.Error("failed to marshal request: %v", err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
			return
		}

		// Send request to short URL service
		msg, err := nc.Request(
			shortUrlApi.Subj.ShortUrlGroup+"."+shortUrlApi.Subj.ShortUrlCreate,
			reqBytes,
			5*time.Second,
		)
		if err != nil {
			logger.Error("failed to create short url: %v", err)
			http.Error(w, "failed to create short url", http.StatusInternalServerError)
			return
		}

		// Check for service errors
		if msg.Header.Get("Nats-Service-Error") != "" {
			errorCode := msg.Header.Get("Nats-Service-Error-Code")
			errorMsg := string(msg.Data)
			logger.Error("service error: %s - %s", errorCode, errorMsg)

			switch errorCode {
			case "SHORT_CODE_TAKEN":
				http.Error(w, "short code already exists", http.StatusConflict)
			case "INVALID_REQUEST":
				http.Error(w, errorMsg, http.StatusBadRequest)
			default:
				http.Error(w, "service error", http.StatusInternalServerError)
			}
			return
		}

		// Parse response
		var resp shortUrlApi.ShortUrl
		if err := json.Unmarshal(msg.Data, &resp); err != nil {
			logger.Error("failed to unmarshal response: %v", err)
			http.Error(w, "failed to parse response", http.StatusInternalServerError)
			return
		}

		logger.Debug("created short url: %s", resp.ShortCode)
		respJson(w, resp, http.StatusCreated)
	})
}

// handleShortUrlGet creates a handler for getting a single short URL
func handleShortUrlGet(l *jst_log.Logger, nc *nats.Conn) http.Handler {
	logger := l.WithBreadcrumb("shorturls").WithBreadcrumb("get")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger.Debug("called")

		id := r.PathValue("id")
		if id == "" {
			http.Error(w, "id is required", http.StatusBadRequest)
			return
		}

		// Create request
		req := shortUrlApi.ShortUrlGetRequest{
			ID: id,
		}

		reqBytes, err := json.Marshal(req)
		if err != nil {
			logger.Error("failed to marshal request: %v", err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
			return
		}

		// Send request to short URL service
		msg, err := nc.Request(
			shortUrlApi.Subj.ShortUrlGroup+"."+shortUrlApi.Subj.ShortUrlGet,
			reqBytes,
			5*time.Second,
		)
		if err != nil {
			logger.Error("failed to get short url: %v", err)
			http.Error(w, "failed to get short url", http.StatusInternalServerError)
			return
		}

		// Check for service errors
		if msg.Header.Get("Nats-Service-Error") != "" {
			errorCode := msg.Header.Get("Nats-Service-Error-Code")
			if errorCode == "NOT_FOUND" {
				http.NotFound(w, r)
				return
			}
			http.Error(w, "service error", http.StatusInternalServerError)
			return
		}

		// Parse response
		var resp shortUrlApi.ShortUrl
		if err := json.Unmarshal(msg.Data, &resp); err != nil {
			logger.Error("failed to unmarshal response: %v", err)
			http.Error(w, "failed to parse response", http.StatusInternalServerError)
			return
		}

		logger.Debug("found short url: %s", resp.ShortCode)
		respJson(w, resp, http.StatusOK)
	})
}

// handleShortUrlUpdate creates a handler for updating short URLs
func handleShortUrlUpdate(l *jst_log.Logger, nc *nats.Conn) http.Handler {
	logger := l.WithBreadcrumb("shorturls").WithBreadcrumb("update")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger.Debug("called")

		// Get user from context
		// _, ok := r.Context().Value(who.UserKey).(whoApi.User)
		// if !ok {
		// 	logger.Warn("user not found in context")
		// 	http.Error(w, "unauthorized", http.StatusUnauthorized)
		// 	return
		// }

		id := r.PathValue("id")
		if id == "" {
			http.Error(w, "id is required", http.StatusBadRequest)
			return
		}

		// Parse request body
		var req shortUrlApi.ShortUrlUpdateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			logger.Warn("failed to decode request: %v", err)
			http.Error(w, "invalid request body", http.StatusBadRequest)
			return
		}

		req.ID = id

		reqBytes, err := json.Marshal(req)
		if err != nil {
			logger.Error("failed to marshal request: %v", err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
			return
		}

		// Send request to short URL service
		msg, err := nc.Request(
			shortUrlApi.Subj.ShortUrlGroup+"."+shortUrlApi.Subj.ShortUrlUpdate,
			reqBytes,
			5*time.Second,
		)
		if err != nil {
			logger.Error("failed to update short url: %v", err)
			http.Error(w, "failed to update short url", http.StatusInternalServerError)
			return
		}

		// Check for service errors
		if msg.Header.Get("Nats-Service-Error") != "" {
			errorCode := msg.Header.Get("Nats-Service-Error-Code")
			errorMsg := string(msg.Data)
			logger.Error("service error: %s - %s", errorCode, errorMsg)

			switch errorCode {
			case "NOT_FOUND":
				http.NotFound(w, r)
			case "SHORT_CODE_TAKEN":
				http.Error(w, "short code already exists", http.StatusConflict)
			case "INVALID_REQUEST":
				http.Error(w, errorMsg, http.StatusBadRequest)
			default:
				http.Error(w, "service error", http.StatusInternalServerError)
			}
			return
		}

		// Parse response
		var resp shortUrlApi.ShortUrl
		if err := json.Unmarshal(msg.Data, &resp); err != nil {
			logger.Error("failed to unmarshal response: %v", err)
			http.Error(w, "failed to parse response", http.StatusInternalServerError)
			return
		}

		logger.Debug("updated short url: %s", resp.ShortCode)
		respJson(w, resp, http.StatusOK)
	})
}

// handleShortUrlDelete creates a handler for deleting short URLs
func handleShortUrlDelete(l *jst_log.Logger, nc *nats.Conn) http.Handler {
	logger := l.WithBreadcrumb("shorturls").WithBreadcrumb("delete")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger.Debug("called")

		// Get user from context
		// _, ok := r.Context().Value(who.UserKey).(whoApi.User)
		// if !ok {
		// 	logger.Warn("user not found in context")
		// 	http.Error(w, "unauthorized", http.StatusUnauthorized)
		// 	return
		// }

		id := r.PathValue("id")
		if id == "" {
			http.Error(w, "id is required", http.StatusBadRequest)
			return
		}

		// Create request
		req := shortUrlApi.ShortUrlDeleteRequest{
			ID: id,
		}

		reqBytes, err := json.Marshal(req)
		if err != nil {
			logger.Error("failed to marshal request: %v", err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
			return
		}

		// Send request to short URL service
		msg, err := nc.Request(
			shortUrlApi.Subj.ShortUrlGroup+"."+shortUrlApi.Subj.ShortUrlDelete,
			reqBytes,
			5*time.Second,
		)
		if err != nil {
			logger.Error("failed to delete short url: %v", err)
			http.Error(w, "failed to delete short url", http.StatusInternalServerError)
			return
		}

		// Check for service errors
		if msg.Header.Get("Nats-Service-Error") != "" {
			errorCode := msg.Header.Get("Nats-Service-Error-Code")
			if errorCode == "NOT_FOUND" {
				http.NotFound(w, r)
				return
			}
			http.Error(w, "service error", http.StatusInternalServerError)
			return
		}

		// Parse response
		var resp shortUrlApi.ShortUrlDeleteResponse
		if err := json.Unmarshal(msg.Data, &resp); err != nil {
			logger.Error("failed to unmarshal response: %v", err)
			http.Error(w, "failed to parse response", http.StatusInternalServerError)
			return
		}

		logger.Debug("deleted short url: %s", resp.IDDeleted)
		respJson(w, resp, http.StatusOK)
	})
}

// handleShortUrlRedirect creates a handler for redirecting short URLs
func handleShortUrlRedirect(l *jst_log.Logger, nc *nats.Conn) http.Handler {
	logger := l.WithBreadcrumb("shorturls").WithBreadcrumb("redirect")
	logger.Debug("ready")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger.Debug("called")

		shortCode := r.PathValue("shortCode")
		if shortCode == "" {
			http.NotFound(w, r)
			return
		}

		// Create request
		req := shortUrlApi.ShortUrlGetRequest{
			ShortCode: shortCode,
		}

		reqBytes, err := json.Marshal(req)
		if err != nil {
			logger.Error("failed to marshal request: %v", err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
			return
		}

		// Send request to short URL service
		msg, err := nc.Request(
			shortUrlApi.Subj.ShortUrlGroup+"."+shortUrlApi.Subj.ShortUrlGet,
			reqBytes,
			5*time.Second,
		)
		if err != nil {
			logger.Error("failed to get short url: %v", err)
			http.Error(w, "failed to get short url", http.StatusInternalServerError)
			return
		}

		// Check for service errors
		if msg.Header.Get("Nats-Service-Error") != "" {
			errorCode := msg.Header.Get("Nats-Service-Error-Code")
			if errorCode == "NOT_FOUND" {
				http.NotFound(w, r)
				return
			}
			http.Error(w, "service error", http.StatusInternalServerError)
			return
		}

		// Parse response
		var shortUrl shortUrlApi.ShortUrl
		if err := json.Unmarshal(msg.Data, &shortUrl); err != nil {
			logger.Error("failed to unmarshal response: %v", err)
			http.Error(w, "failed to parse response", http.StatusInternalServerError)
			return
		}

		// Check if short URL is active
		if !shortUrl.IsActive {
			http.Error(w, "short URL is inactive", http.StatusGone)
			return
		}

		// Increment access count
		go func() {
			accessReq := shortUrlApi.ShortUrlAccessRequest{
				ShortCode: shortCode,
			}
			accessReqBytes, err := json.Marshal(accessReq)
			if err != nil {
				logger.Error("failed to marshal access request: %v", err)
				return
			}

			// Call the access endpoint to track the redirect
			accessMsg, err := nc.Request(
				shortUrlApi.Subj.ShortUrlGroup+"."+shortUrlApi.Subj.ShortUrlAccess,
				accessReqBytes,
				2*time.Second,
			)
			if err != nil {
				logger.Error("failed to track access: %v", err)
				return
			}

			// Check for service errors
			if accessMsg.Header.Get("Nats-Service-Error") != "" {
				logger.Error("access tracking failed: %s", string(accessMsg.Data))
				return
			}
		}()

		logger.Debug("redirecting %s to %s", shortCode, shortUrl.TargetURL)
		http.Redirect(w, r, shortUrl.TargetURL, http.StatusMovedPermanently)
	})
}

// --- NOTIFICATION HANDLERS ---

func handleNotificationSend(l *jst_log.Logger, nc *nats.Conn) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		logger := l.WithBreadcrumb("handleNotificationSend")

		// Get user from context
		user, ok := r.Context().Value(who.UserKey).(whoApi.User)
		if !ok {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		// Parse request body
		var req struct {
			Title     string                 `json:"title"`
			Message   string                 `json:"message"`
			Category  string                 `json:"category"`
			Priority  ntfy.Priority          `json:"priority"`
			NtfyTopic string                 `json:"ntfy_topic"`
			Data      map[string]interface{} `json:"data,omitempty"`
		}

		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			logger.Error("failed to decode request: %v", err)
			http.Error(w, "invalid request body", http.StatusBadRequest)
			return
		}

		// Validate required fields
		if req.Title == "" {
			http.Error(w, "title is required", http.StatusBadRequest)
			return
		}
		if req.Message == "" {
			http.Error(w, "message is required", http.StatusBadRequest)
			return
		}
		if req.Category == "" {
			http.Error(w, "category is required", http.StatusBadRequest)
			return
		}

		// Create notification
		notification := ntfy.Notification{
			ID:        uuid.New().String(),
			UserID:    user.ID,
			Title:     req.Title,
			Message:   req.Message,
			Category:  req.Category,
			Priority:  req.Priority,
			NtfyTopic: req.NtfyTopic,
			Data:      req.Data,
			CreatedAt: time.Now(),
		}

		// Set default priority if not provided
		if notification.Priority == "" {
			notification.Priority = ntfy.PriorityNormal
		}

		// Marshal notification
		notificationBytes, err := json.Marshal(notification)
		if err != nil {
			logger.Error("failed to marshal notification: %v", err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
			return
		}

		// Send notification via NATS
		msg, err := nc.Request(ntfy.SubjectNotification, notificationBytes, 10*time.Second)
		if err != nil {
			logger.Error("failed to send notification: %v", err)
			http.Error(w, "failed to send notification", http.StatusInternalServerError)
			return
		}

		// Check for service errors
		if msg.Header.Get("Nats-Service-Error") != "" {
			errorCode := msg.Header.Get("Nats-Service-Error-Code")
			if errorCode == "400" {
				http.Error(w, string(msg.Data), http.StatusBadRequest)
				return
			}
			http.Error(w, "notification service error", http.StatusInternalServerError)
			return
		}

		// Return success response
		respJson(w, map[string]string{
			"status":  "success",
			"message": "Notification sent successfully",
			"id":      notification.ID,
		}, http.StatusOK)
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
	if _, err := w.Write(respBytes); err != nil {
		http.Error(w, "failed to write response", http.StatusInternalServerError)
		return
	}
}
