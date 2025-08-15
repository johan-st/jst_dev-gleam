package web

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	"github.com/nats-io/nats.go"

	"jst_dev/server/articles"
	"jst_dev/server/jst_log"
	"jst_dev/server/who"
	whoApi "jst_dev/server/who/api"
	"github.com/nats-io/nats.go/jetstream"
)

// Unified protocol messages

type clientMsg struct {
	Op     string          `json:"op"`
	Target string          `json:"target"`
	Inbox  string          `json:"inbox,omitempty"`
	Data   json.RawMessage `json:"data,omitempty"`
}

type serverMsg struct {
	Op     string      `json:"op"`
	Target string      `json:"target"`
	Inbox  string      `json:"inbox,omitempty"`
	Data   interface{} `json:"data,omitempty"`
}

// Article-specific message types
type articleCreateRequest struct {
	Title       string   `json:"title"`
	Subtitle    string   `json:"subtitle"`
	Leading     string   `json:"leading"`
	Content     string   `json:"content"`
	Tags        []string `json:"tags"`
	PublishedAt int      `json:"published_at"`
}

type articleUpdateRequest struct {
	Title       string   `json:"title,omitempty"`
	Subtitle    string   `json:"subtitle,omitempty"`
	Leading     string   `json:"leading,omitempty"`
	Content     string   `json:"content,omitempty"`
	Tags        []string `json:"tags,omitempty"`
	PublishedAt int      `json:"published_at,omitempty"`
}

type articleResponse struct {
	ID            string   `json:"id"`
	Slug          string   `json:"slug"`
	Title         string   `json:"title"`
	Subtitle      string   `json:"subtitle"`
	Leading       string   `json:"leading"`
	Author        string   `json:"author"`
	PublishedAt   int      `json:"published_at"`
	Tags          []string `json:"tags"`
	Content       string   `json:"content,omitempty"`
	Revision      uint64   `json:"revision"`
	StructVersion int      `json:"struct_version"`
}

type articleListResponse struct {
	Articles []articleResponse `json:"articles"`
}

type articleHistoryResponse struct {
	Revisions []articleResponse `json:"revisions"`
}

// Capabilities with pattern-based permissions

type capabilities struct {
	Subjects []string            `json:"subjects"`
	Buckets  map[string][]string `json:"buckets"` // bucket pattern -> allowed key patterns
	Commands []string            `json:"commands"`
	Streams  map[string][]string `json:"streams"` // stream pattern -> allowed filter subject patterns
}

type server struct {
	nc          *nats.Conn
	js          nats.JetStreamContext
	articleRepo articles.ArticleRepo
}

type rtClient struct {
	id         string
	caps       capabilities
	conn       *websocket.Conn
	srv        *server
	subs       map[string]*nats.Subscription
	kvWatchers map[string]interface{} // Can hold both nats.KeyWatcher and jetstream.KeyWatcher
	articleRepo articles.ArticleRepo
	sendCh     chan serverMsg
	mu         sync.Mutex
	ctx        context.Context
	cancel     context.CancelFunc
	log        *jst_log.Logger
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		// TODO: Configure allowed origins based on environment
		allowedOrigins := []string{"https://jst.dev", "https://jst-dev.fly.dev", "http://localhost:8080", "https://jst-dev-preview.fly.dev"}
		origin := r.Header.Get("Origin")
		for _, allowed := range allowedOrigins {
			if origin == allowed {
				return true
			}
		}
		return false
	},
}

// HandleRealtimeWebSocket upgrades the connection and serves the realtime bridge
func HandleRealtimeWebSocket(l *jst_log.Logger, nc *nats.Conn, w http.ResponseWriter, r *http.Request, repo articles.ArticleRepo) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		l.Error("ws upgrade: %v", err)
		return
	}

	js, err := nc.JetStream()
	if err != nil {
		_ = conn.WriteJSON(serverMsg{Op: "error", Data: map[string]string{"reason": "jetstream unavailable"}})
		_ = conn.Close()
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	s := &server{nc: nc, js: js, articleRepo: repo}

	userID := userIDFromRequest(r)
	c := &rtClient{
		id:         userID,
		caps:       authorizeInitial(l, s, userID),
		conn:       conn,
		srv:        s,
		subs:       make(map[string]*nats.Subscription),
		kvWatchers: make(map[string]interface{}),
		articleRepo: repo,
		sendCh:     make(chan serverMsg, 256),
		ctx:        ctx,
		cancel:     cancel,
		log:        l,
	}

	go c.watchAuthKV()
	go c.writeLoop()
	c.readLoop()
}

func userIDFromRequest(r *http.Request) string {
	if u, ok := r.Context().Value(who.UserKey).(whoApi.User); ok {
		if u.ID != "" {
			return u.ID
		}
	}
	return ""
}

// Authorization bootstrap (loads capabilities from Auth KV); fallback to minimal caps
func authorizeInitial(l *jst_log.Logger, s *server, userID string) capabilities {
	caps := capabilities{
		Subjects: []string{"time.>"},
		Buckets:  map[string][]string{"article": {">"}},
		Commands: []string{"article_list", "article_get", "article_create", "article_update", "article_delete", "article_history", "article_revision"},
		Streams:  map[string][]string{},
	}
	if userID == "" {
		return caps
	}
	kv, err := s.js.KeyValue("auth.users")
	if err != nil {
		return caps
	}
	entry, err := kv.Get(userID)
	if err != nil || entry == nil {
		return caps
	}
	_ = json.Unmarshal(entry.Value(), &caps)
	return caps
}

func (c *rtClient) writeLoop() {
	for {
		select {
		case <-c.ctx.Done():
			return
		case msg := <-c.sendCh:
			if err := c.conn.WriteJSON(msg); err != nil {
				c.log.Error("ws write: %v", err)
				c.closeWithError("write error")
				return
			}
		}
	}
}

func (c *rtClient) send(msg serverMsg) {
	select {
	case c.sendCh <- msg:
		return
	case <-time.After(250 * time.Millisecond):
		c.log.Warn("send backpressure; closing client=%s", c.id)
		c.closeWithError("backpressure timeout")
	}
}

func (c *rtClient) closeWithError(reason string) {
	_ = c.conn.WriteJSON(serverMsg{Op: "error", Data: map[string]string{"reason": reason}})
	c.cancel()
	_ = c.conn.Close()
	c.unsubscribeAll()
}

func (c *rtClient) readLoop() {
	defer func() {
		c.cancel()
		_ = c.conn.Close()
		c.unsubscribeAll()
	}()

	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		var m clientMsg
		if err := json.Unmarshal(data, &m); err != nil {
			c.send(serverMsg{Op: "error", Data: map[string]string{"reason": "bad json"}})
			continue
		}
		switch m.Op {
		case "sub":
			c.log.Debug("Received sub message for target=%s", m.Target)
			c.handleSub(m.Target)
		case "unsub":
			c.log.Debug("Received unsub message for target=%s", m.Target)
			c.handleUnsub(m.Target)
		case "kv_sub":
			c.log.Debug("Received kv_sub message for target=%s", m.Target)
			var opts struct {
				Pattern string `json:"pattern"`
			}
			_ = json.Unmarshal(m.Data, &opts)
			if m.Target == "article" {
				c.handleArticleKVSub(opts.Pattern)
			} else {
				c.handleKVSub(m.Target, opts.Pattern)
			}
		case "js_sub":
			var opts struct {
				StartSeq uint64 `json:"start_seq"`
				Batch    int    `json:"batch"`
				Filter   string `json:"filter"`
			}
			_ = json.Unmarshal(m.Data, &opts)
			c.handleJSSub(m.Target, opts.StartSeq, opts.Batch, opts.Filter)
		case "cmd":
			c.handleCommand(m.Target, m.Data, m.Inbox)
		case "article_list":
			c.handleArticleList(m.Inbox)
		case "article_get":
			var opts struct {
				ID string `json:"id"`
			}
			_ = json.Unmarshal(m.Data, &opts)
			c.handleArticleGet(opts.ID, m.Inbox)
		case "article_create":
			var req articleCreateRequest
			_ = json.Unmarshal(m.Data, &req)
			c.handleArticleCreate(req, m.Inbox)
		case "article_update":
			var opts struct {
				ID   string                `json:"id"`
				Data articleUpdateRequest  `json:"data"`
			}
			_ = json.Unmarshal(m.Data, &opts)
			c.handleArticleUpdate(opts.ID, opts.Data, m.Inbox)
		case "article_delete":
			var opts struct {
				ID string `json:"id"`
			}
			_ = json.Unmarshal(m.Data, &opts)
			c.handleArticleDelete(opts.ID, m.Inbox)
		case "article_history":
			var opts struct {
				ID string `json:"id"`
			}
			_ = json.Unmarshal(m.Data, &opts)
			c.handleArticleRevision(opts.ID, 0, m.Inbox)
		case "article_revision":
			var opts struct {
				ID        string `json:"id"`
				Revision  uint64 `json:"revision"`
			}
			_ = json.Unmarshal(m.Data, &opts)
			c.handleArticleRevision(opts.ID, opts.Revision, m.Inbox)
		}
	}
}

func (c *rtClient) unsubscribeAll() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, s := range c.subs {
		_ = s.Unsubscribe()
	}
	for _, w := range c.kvWatchers {
		if watcher, ok := w.(nats.KeyWatcher); ok {
			_ = watcher.Stop()
		} else if watcher, ok := w.(jetstream.KeyWatcher); ok {
			_ = watcher.Stop()
		}
	}
}

// ---- Capability checks

// subjectMatch implements NATS-like matching with '*' (single token) and '>' (tail)
func subjectMatch(pattern, subject string) bool {
	pp := strings.Split(pattern, ".")
	su := strings.Split(subject, ".")
	for i, pi := range pp {
		if pi == ">" {
			return true
		}
		if i >= len(su) {
			return false
		}
		si := su[i]
		if pi == "*" {
			continue
		}
		if pi != si {
			return false
		}
	}
	return len(su) == len(pp) || (len(pp) > 0 && pp[len(pp)-1] == ">")
}

func containsPattern(patterns []string, subject string) bool {
	for _, p := range patterns {
		if subjectMatch(p, subject) {
			return true
		}
	}
	return false
}

func (c *rtClient) isAllowedSubject(subject string) bool {
	return containsPattern(c.caps.Subjects, subject)
}

func (c *rtClient) isAllowedKV(bucket, keyPattern string) bool {
	for bucketPattern, allowedKeys := range c.caps.Buckets {
		if subjectMatch(bucketPattern, bucket) {
			if keyPattern == "" {
				return containsPattern(allowedKeys, ">")
			}
			return containsPattern(allowedKeys, keyPattern)
		}
	}
	return false
}

func (c *rtClient) isAllowedStream(stream, filter string) bool {
	for streamPattern, allowedFilters := range c.caps.Streams {
		if subjectMatch(streamPattern, stream) {
			if filter == "" {
				return containsPattern(allowedFilters, ">")
			}
			return containsPattern(allowedFilters, filter)
		}
	}
	return false
}

// ---- Handlers

func (c *rtClient) handleSub(subject string) {
	if !c.isAllowedSubject(subject) {
		return
	}
	sub, err := c.srv.nc.Subscribe(subject, func(m *nats.Msg) {
		var payload interface{}
		if err := json.Unmarshal(m.Data, &payload); err != nil {
			payload = string(m.Data)
		}
		c.send(serverMsg{Op: "msg", Target: subject, Data: payload})
	})
	if err != nil {
		return
	}
	c.mu.Lock()
	c.subs[subject] = sub
	c.mu.Unlock()
}

func (c *rtClient) handleUnsub(subject string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if s, ok := c.subs[subject]; ok {
		_ = s.Unsubscribe()
		delete(c.subs, subject)
	}
	if w, ok := c.kvWatchers[subject]; ok {
		if watcher, ok := w.(nats.KeyWatcher); ok {
			_ = watcher.Stop()
		} else if watcher, ok := w.(jetstream.KeyWatcher); ok {
			_ = watcher.Stop()
		}
		delete(c.kvWatchers, subject)
	}
}

func (c *rtClient) handleKVSub(bucket, pattern string) {
	c.log.Debug("handleKVSub called with bucket=%s, pattern=%s", bucket, pattern)
	if !c.isAllowedKV(bucket, pattern) {
		c.log.Debug("KV subscription not allowed for bucket=%s, pattern=%s", bucket, pattern)
		return
	}
	kv, err := c.srv.js.KeyValue(bucket)
	if err != nil {
		c.log.Error("Failed to get KV bucket %s: %v", bucket, err)
		return
	}
	c.log.Debug("Successfully got KV bucket %s", bucket)
	var watcher nats.KeyWatcher
	if pattern != "" {
		// try pattern-specific watch if supported; otherwise fallback to WatchAll and filter client-side
		w, werr := kv.Watch(pattern)
		if werr == nil {
			watcher = w
		} else {
			watcher, _ = kv.WatchAll()
		}
	} else {
		watcher, _ = kv.WatchAll()
	}
	if watcher == nil {
		c.log.Error("Failed to create watcher for bucket %s", bucket)
		return
	}
	c.log.Debug("Successfully created watcher for bucket %s", bucket)
	c.kvWatchers[bucket] = watcher
	go func() {
		for {
			select {
			case <-c.ctx.Done():
				_ = watcher.Stop()
				return
			case entry := <-watcher.Updates():
				if entry == nil {
					continue
				}
				// If we had to fallback to WatchAll, filter by pattern here
				if pattern != "" && !subjectMatch(pattern, entry.Key()) {
					continue
				}
				var opStr string
				switch entry.Operation() {
				case nats.KeyValueDelete:
					opStr = "delete"
				case nats.KeyValuePurge:
					opStr = "purge"
				default:
					opStr = "put"
				}
				c.send(serverMsg{Op: "msg", Target: bucket, Data: map[string]interface{}{
					"key":   entry.Key(),
					"value": string(entry.Value()),
					"rev":   entry.Revision(),
					"op":    opStr,
				}})
			}
		}
	}()
}

func (c *rtClient) handleJSSub(stream string, startSeq uint64, batch int, filter string) {
	if !c.isAllowedStream(stream, filter) {
		return
	}
	// Require a filter subject for JS subscribe to ensure a concrete subject
	if filter == "" {
		return
	}

	if batch <= 0 {
		batch = 50
	}

	// Create durable name per connection/user and filter
	durable := durableName(c.id, stream, filter)

	// Create a pull consumer bound to stream with optional start sequence
	opts := []nats.SubOpt{nats.BindStream(stream)}
	if startSeq > 0 {
		opts = append(opts, nats.StartSequence(startSeq))
	}

	sub, err := c.srv.js.PullSubscribe(filter, durable, opts...)
	if err != nil {
		return
	}

	c.mu.Lock()
	c.subs[stream] = sub
	c.mu.Unlock()

	go func() {
		defer func() {
			_ = sub.Drain()
		}()
		for {
			select {
			case <-c.ctx.Done():
				return
			default:
				msgs, err := sub.Fetch(batch, nats.MaxWait(200*time.Millisecond))
				if err != nil {
					// Timeout is expected when idle; other errors exit
					if err == nats.ErrTimeout {
						continue
					}
					return
				}
				for _, msg := range msgs {
					// Forward to client; on backpressure, send() will close the connection
					c.send(serverMsg{Op: "msg", Target: stream, Data: json.RawMessage(msg.Data)})
					if c.ctx.Err() != nil {
						// Connection closed; messages will be redelivered to next consumer with same durable name
						// TODO: Consider implementing a resume mechanism with sequence tracking
						c.log.Warn("Connection closed with %d unacked messages for stream=%s", len(msgs)-1, stream)
						return
					}
					_ = msg.Ack()
				}
			}
		}
	}()
}

func (c *rtClient) handleCommand(target string, data json.RawMessage, inbox string) {
	if !containsPattern(c.caps.Commands, target) {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(c.ctx, 5*time.Second)
		defer cancel()
		msg, err := c.srv.nc.RequestWithContext(ctx, target, data)
		if err != nil {
			c.send(serverMsg{Op: "reply", Target: target, Inbox: inbox, Data: map[string]string{"error": err.Error()}})
			return
		}
		var payload interface{}
		if err := json.Unmarshal(msg.Data, &payload); err != nil {
			payload = string(msg.Data)
		}
		c.send(serverMsg{Op: "reply", Target: target, Inbox: inbox, Data: payload})
	}()
}

// Capability updates via Auth KV
func (c *rtClient) watchAuthKV() {
	kv, err := c.srv.js.KeyValue("auth.users")
	if err != nil {
		return
	}
	watcher, err := kv.Watch(c.id)
	if err != nil {
		return
	}
	go func() {
		for {
			select {
			case <-c.ctx.Done():
				_ = watcher.Stop()
				return
			case entry := <-watcher.Updates():
				if entry == nil {
					continue
				}
				var newCaps capabilities
				if err := json.Unmarshal(entry.Value(), &newCaps); err != nil {
					continue
				}
				c.applyCapabilities(newCaps)
				c.send(serverMsg{Op: "cap_update", Data: newCaps})
			}
		}
	}()
}

func (c *rtClient) applyCapabilities(newCaps capabilities) {
	c.mu.Lock()
	defer c.mu.Unlock()
	// Unsubscribe from disallowed subjects
	for subject, sub := range c.subs {
		if subject == "" {
			continue
		}
		if !containsPattern(newCaps.Subjects, subject) {
			_ = sub.Unsubscribe()
			delete(c.subs, subject)
		}
	}
	for bucket, w := range c.kvWatchers {
		allowed := false
		for bucketPattern := range newCaps.Buckets {
			if subjectMatch(bucketPattern, bucket) {
				allowed = true
				break
			}
		}
		if !allowed {
			if watcher, ok := w.(nats.KeyWatcher); ok {
				_ = watcher.Stop()
			} else if watcher, ok := w.(jetstream.KeyWatcher); ok {
				_ = watcher.Stop()
			}
			delete(c.kvWatchers, bucket)
		}
	}
	c.caps = newCaps
}

// ---- Article Handlers ----

func (c *rtClient) handleArticleList(inbox string) {
	if !c.isAllowedKV("article", ">") {
		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "insufficient permissions"}})
		return
	}

	go func() {
		articles, err := c.articleRepo.AllNoContent()
		if err != nil {
			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to list articles"}})
			return
		}

		var articleResponses []articleResponse
		for _, art := range articles {
			articleResponses = append(articleResponses, articleResponse{
				ID:            art.Id.String(),
				Slug:          art.Slug,
				Title:         art.Title,
				Subtitle:      art.Subtitle,
				Leading:       art.Leading,
				Author:        art.Author,
				PublishedAt:   art.PublishedAt,
				Tags:          art.Tags,
				Revision:      art.Rev,
				StructVersion: art.StructVersion,
			})
		}

		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: articleListResponse{Articles: articleResponses}})
	}()
}

func (c *rtClient) handleArticleGet(id string, inbox string) {
	if !c.isAllowedKV("article", id) {
		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "insufficient permissions"}})
		return
	}

	go func() {
		articleID, err := uuid.Parse(id)
		if err != nil {
			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "invalid article ID"}})
			return
		}

		art, err := c.articleRepo.Get(articleID)
		if err != nil {
			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "article not found"}})
			return
		}

		articleResp := articleResponse{
			ID:            art.Id.String(),
			Slug:          art.Slug,
			Title:         art.Title,
			Subtitle:      art.Subtitle,
			Leading:       art.Leading,
			Author:        art.Author,
			PublishedAt:   art.PublishedAt,
			Tags:          art.Tags,
			Content:       art.Content,
			Revision:      art.Rev,
			StructVersion: art.StructVersion,
		}

		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: articleResp})
	}()
}

func (c *rtClient) handleArticleCreate(req articleCreateRequest, inbox string) {
	if !c.isAllowedKV("article", ">") {
		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "insufficient permissions"}})
		return
	}

	go func() {
		// Create article using the repository
		article := articles.Article{
			Title:       req.Title,
			Subtitle:    req.Subtitle,
			Leading:     req.Leading,
			Content:     req.Content,
			Author:      c.id, // Use current user ID
			PublishedAt: req.PublishedAt,
			Tags:        req.Tags,
		}

		createdArticle, err := c.articleRepo.Create(article)
		if err != nil {
			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to create article"}})
			return
		}

		// Convert to response format
		articleResp := articleResponse{
			ID:            createdArticle.Id.String(),
			Slug:          createdArticle.Slug,
			Title:         createdArticle.Title,
			Subtitle:      createdArticle.Subtitle,
			Leading:       createdArticle.Leading,
			Content:       createdArticle.Content,
			Author:        createdArticle.Author,
			PublishedAt:   createdArticle.PublishedAt,
			Tags:          createdArticle.Tags,
			Revision:      createdArticle.Rev,
			StructVersion: createdArticle.StructVersion,
		}

		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: articleResp})
	}()
}

func (c *rtClient) handleArticleUpdate(id string, req articleUpdateRequest, inbox string) {
	if !c.isAllowedKV("article", id) {
		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "insufficient permissions"}})
		return
	}

	go func() {
		// Parse article ID
		articleID, err := uuid.Parse(id)
		if err != nil {
			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "invalid article ID"}})
			return
		}

		// Get existing article
		existing, err := c.articleRepo.Get(articleID)
		if err != nil {
			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "article not found"}})
			return
		}

		// Update fields if provided
		if req.Title != "" {
			existing.Title = req.Title
		}
		if req.Subtitle != "" {
			existing.Subtitle = req.Subtitle
		}
		if req.Leading != "" {
			existing.Leading = req.Leading
		}
		if req.Content != "" {
			existing.Content = req.Content
		}
		if req.Tags != nil {
			existing.Tags = req.Tags
		}
		if req.PublishedAt != 0 {
			existing.PublishedAt = req.PublishedAt
		}

		// Update article using repository
		updatedArticle, err := c.articleRepo.Update(existing)
		if err != nil {
			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to update article"}})
			return
		}

		// Convert to response format
		articleResp := articleResponse{
			ID:            updatedArticle.Id.String(),
			Slug:          updatedArticle.Slug,
			Title:         updatedArticle.Title,
			Subtitle:      updatedArticle.Subtitle,
			Leading:       updatedArticle.Leading,
			Content:       updatedArticle.Content,
			Author:        updatedArticle.Author,
			PublishedAt:   updatedArticle.PublishedAt,
			Tags:          updatedArticle.Tags,
			Revision:      updatedArticle.Rev,
			StructVersion: updatedArticle.StructVersion,
		}

		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: articleResp})
	}()
}

func (c *rtClient) handleArticleDelete(id string, inbox string) {
	if !c.isAllowedKV("article", id) {
		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "insufficient permissions"}})
		return
	}

	go func() {
		// Parse article ID
		articleID, err := uuid.Parse(id)
		if err != nil {
			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "invalid article ID"}})
			return
		}

		// Delete article using repository
		err = c.articleRepo.Delete(articleID)
		if err != nil {
			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to delete article"}})
			return
		}

		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"status": "deleted"}})
	}()
}

func (c *rtClient) handleArticleRevision(id string, revision uint64, inbox string) {
	if !c.isAllowedKV("article", id) {
		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "insufficient permissions"}})
		return
	}

	go func() {
		// Parse article ID
		articleID, err := uuid.Parse(id)
		if err != nil {
			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "invalid article ID"}})
			return
		}

		if revision == 0 {
			// Get history
			history, err := c.articleRepo.GetHistory(articleID)
			if err != nil {
				c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to get article history"}})
				return
			}

			var revisions []articleResponse
			for _, art := range history {
				revisions = append(revisions, articleResponse{
					ID:            art.Id.String(),
					Slug:          art.Slug,
					Title:         art.Title,
					Subtitle:      art.Subtitle,
					Leading:       art.Leading,
					Author:        art.Author,
					PublishedAt:   art.PublishedAt,
					Tags:          art.Tags,
					Content:       art.Content,
					Revision:      art.Rev,
					StructVersion: art.StructVersion,
				})
			}

			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: articleHistoryResponse{Revisions: revisions}})
		} else {
			// Get specific revision
			art, err := c.articleRepo.GetRevision(articleID, revision)
			if err != nil {
				c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "revision not found"}})
				return
			}

			articleResp := articleResponse{
				ID:            art.Id.String(),
				Slug:          art.Slug,
				Title:         art.Title,
				Subtitle:      art.Subtitle,
				Leading:       art.Leading,
				Author:        art.Author,
				PublishedAt:   art.PublishedAt,
				Tags:          art.Tags,
				Content:       art.Content,
				Revision:      art.Rev,
				StructVersion: art.StructVersion,
			}

			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: articleResp})
		}
	}()
}

func (c *rtClient) handleArticleKVSub(pattern string) {
	c.log.Debug("handleArticleKVSub called with pattern=%s", pattern)
	if !c.isAllowedKV("article", pattern) {
		c.log.Debug("Article KV subscription not allowed for pattern=%s", pattern)
		return
	}

	// Use the article repository's WatchAll method
	watcher, err := c.articleRepo.WatchAll()
	if err != nil {
		c.log.Error("Failed to create article watcher: %v", err)
		return
	}

	c.log.Debug("Successfully created article watcher")
	c.kvWatchers["article"] = watcher

	go func() {
		for {
			select {
			case <-c.ctx.Done():
				_ = watcher.Stop()
				return
			case entry := <-watcher.Updates():
				if entry == nil {
					continue
				}
				
				// Filter by pattern if specified
				if pattern != "" && !subjectMatch(pattern, entry.Key()) {
					continue
				}

				var opStr string
				switch entry.Operation() {
				case jetstream.KeyValueDelete:
					opStr = "delete"
				case jetstream.KeyValuePurge:
					opStr = "purge"
				default:
					opStr = "put"
				}

				// For article updates, we can also include the article data
				var articleData interface{}
				if entry.Operation() == jetstream.KeyValuePut {
					var art articles.Article
					if err := json.Unmarshal(entry.Value(), &art); err == nil {
						articleData = map[string]interface{}{
							"id":             art.Id.String(),
							"slug":           art.Slug,
							"title":          art.Title,
							"subtitle":       art.Subtitle,
							"leading":        art.Leading,
							"author":         art.Author,
							"published_at":   art.PublishedAt,
							"tags":           art.Tags,
							"revision":       art.Rev,
							"struct_version": art.StructVersion,
						}
					} else {
						articleData = string(entry.Value())
					}
				} else {
					articleData = entry.Key()
				}

				c.send(serverMsg{Op: "msg", Target: "article", Data: map[string]interface{}{
					"key":   entry.Key(),
					"value": articleData,
					"rev":   entry.Revision(),
					"op":    opStr,
				}})
			}
		}
	}()
}

func durableName(userID, stream, filter string) string {
	// Create a unique, stable hash to avoid collisions between sanitized inputs
	h := sha256.New()
	_, _ = h.Write([]byte(fmt.Sprintf("%s:%s:%s", userID, stream, filter)))
	hash := hex.EncodeToString(h.Sum(nil))[:16] // first 16 chars is plenty of entropy

	shorten := func(s string, n int) string {
		if len(s) > n {
			return s[:n]
		}
		return s
	}

	userPart := shorten(sanitizeName(userID), 20)
	streamPart := shorten(sanitizeName(stream), 20)

	name := fmt.Sprintf("ws_%s_%s_%s", userPart, streamPart, hash)
	if len(name) > 200 { // keep well under typical JetStream durable limits
		name = name[:200]
	}
	return name
}

func sanitizeName(s string) string {
	var b strings.Builder
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	if b.Len() == 0 {
		return "_"
	}
	return b.String()
}
