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

	"github.com/gorilla/websocket"
	"github.com/nats-io/nats.go"

	"jst_dev/server/jst_log"
	"jst_dev/server/who"
	whoApi "jst_dev/server/who/api"
)

// protocol messages

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

type serverKvMsg struct {
	Op    string `json:"op"`
	Rev   uint64 `json:"rev"`
	Key   string `json:"key"`
	Value string `json:"value"`
}

// Article
// type articleCreateRequest struct {
// 	Title       string   `json:"title"`
// 	Subtitle    string   `json:"subtitle"`
// 	Leading     string   `json:"leading"`
// 	Content     string   `json:"content"`
// 	Tags        []string `json:"tags"`
// 	PublishedAt int      `json:"published_at"`
// }

// type articleUpdateRequest struct {
// 	Title       string   `json:"title,omitempty"`
// 	Subtitle    string   `json:"subtitle,omitempty"`
// 	Leading     string   `json:"leading,omitempty"`
// 	Content     string   `json:"content,omitempty"`
// 	Tags        []string `json:"tags,omitempty"`
// 	PublishedAt int      `json:"published_at,omitempty"`
// }

// type articleResponse struct {
// 	ID            string   `json:"id"`
// 	Slug          string   `json:"slug"`
// 	Title         string   `json:"title"`
// 	Subtitle      string   `json:"subtitle"`
// 	Leading       string   `json:"leading"`
// 	Author        string   `json:"author"`
// 	PublishedAt   int      `json:"published_at"`
// 	Tags          []string `json:"tags"`
// 	Content       string   `json:"content,omitempty"`
// 	Revision      uint64   `json:"revision"`
// 	StructVersion int      `json:"struct_version"`
// }

// type articleListResponse struct {
// 	Articles []articleResponse `json:"articles"`
// }

// type articleHistoryResponse struct {
// 	Revisions []articleResponse `json:"revisions"`
// }

// Capabilities (authorization)
type capabilities struct {
	Subjects []string            `json:"subjects"`
	Buckets  map[string][]string `json:"buckets"` // bucket pattern -> allowed key patterns
	Commands []string            `json:"commands"`
	Streams  map[string][]string `json:"streams"` // stream pattern -> allowed filter subject patterns
}

// Server
type server struct {
	nc *nats.Conn
	js nats.JetStreamContext
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
func HandleRealtimeWebSocket(l *jst_log.Logger, nc *nats.Conn, w http.ResponseWriter, r *http.Request) {
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
	s := &server{nc: nc, js: js}

	userID := userIDFromRequest(r)
	c := &rtClient{
		id:         userID,
		caps:       authorizeInitial(l, s, userID),
		conn:       conn,
		srv:        s,
		subs:       make(map[string]*nats.Subscription),
		kvWatchers: make(map[string]nats.KeyWatcher),
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

// Authorization bootstrap TODO: implement proper
func authorizeInitial(l *jst_log.Logger, s *server, userID string) capabilities {
	caps := capabilities{
		Subjects: []string{"time.seconds"},
		Buckets:  map[string][]string{"article": {">"}, "url_short": {">"}},
		Commands: []string{},
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

// websocket
type rtClient struct {
	id         string
	caps       capabilities
	conn       *websocket.Conn
	srv        *server
	subs       map[string]*nats.Subscription
	kvWatchers map[string]nats.KeyWatcher
	sendCh     chan serverMsg
	mu         sync.Mutex
	ctx        context.Context
	cancel     context.CancelFunc
	log        *jst_log.Logger
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
			c.handleKVSub(m.Target, opts.Pattern)
		// case "kv_unsub:"
		case "js_sub":
			var opts struct {
				StartSeq uint64 `json:"start_seq"`
				Batch    int    `json:"batch"`
				Filter   string `json:"filter"`
			}
			_ = json.Unmarshal(m.Data, &opts)
			c.handleJSSub(m.Target, opts.StartSeq, opts.Batch, opts.Filter)
		// case "js_unsub":
		default:
			c.log.Warn("Unknown operation: %s", m.Op)
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
		_ = w.Stop()
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
		c.send(serverMsg{Op: "sub_msg", Target: subject, Data: payload})
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
		_ = w.Stop()
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
					c.send(serverMsg{Op: "kv_msg", Target: bucket, Data: serverKvMsg{Op: "in_sync", Rev: 0, Key: "", Value: ""}})
					continue
				}

				var opStr string
				switch entry.Operation() {
				case nats.KeyValueDelete:
					opStr = "delete"
				case nats.KeyValuePurge:
					opStr = "purge"
				case nats.KeyValuePut:
					opStr = "put"
				default:
					opStr = "unknown"
				}
				c.send(serverMsg{
					Op:     "kv_msg",
					Target: bucket,
					Data: serverKvMsg{
						Op:    opStr,
						Rev:   entry.Revision(),
						Key:   entry.Key(),
						Value: string(entry.Value()),
					},
				})
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
					c.send(serverMsg{Op: "js_msg", Target: stream, Data: json.RawMessage(msg.Data)})
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

// func (c *rtClient) handleCommand(target string, data json.RawMessage, inbox string) {
// 	if !containsPattern(c.caps.Commands, target) {
// 		return
// 	}
// 	go func() {
// 		ctx, cancel := context.WithTimeout(c.ctx, 5*time.Second)
// 		defer cancel()
// 		msg, err := c.srv.nc.RequestWithContext(ctx, target, data)
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Target: target, Inbox: inbox, Data: map[string]string{"error": err.Error()}})
// 			return
// 		}
// 		var payload interface{}
// 		if err := json.Unmarshal(msg.Data, &payload); err != nil {
// 			payload = string(msg.Data)
// 		}
// 		c.send(serverMsg{Op: "reply", Target: target, Inbox: inbox, Data: payload})
// 	}()
// }

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
			_ = w.Stop()
			delete(c.kvWatchers, bucket)
		}
	}
	c.caps = newCaps
}

// ---- Article Handlers ----

// func (c *rtClient) handleArticleList(inbox string) {
// 	if !c.isAllowedKV("article", ">") {
// 		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "insufficient permissions"}})
// 		return
// 	}

// 	go func() {
// 		kv, err := c.srv.js.KeyValue("article")
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to access article bucket"}})
// 			return
// 		}

// 		keys, err := kv.ListKeys()
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to list articles"}})
// 			return
// 		}

// 		var articles []articleResponse
// 		for key := range keys.Keys() {
// 			entry, err := kv.Get(key)
// 			if err != nil {
// 				continue // Skip articles we can't read
// 			}

// 			var art struct {
// 				ID            string   `json:"id"`
// 				Slug          string   `json:"slug"`
// 				Title         string   `json:"title"`
// 				Subtitle      string   `json:"subtitle"`
// 				Leading       string   `json:"leading"`
// 				Author        string   `json:"author"`
// 				PublishedAt   int      `json:"published_at"`
// 				Tags          []string `json:"tags"`
// 				StructVersion int      `json:"struct_version"`
// 			}

// 			if err := json.Unmarshal(entry.Value(), &art); err != nil {
// 				continue
// 			}

// 			articles = append(articles, articleResponse{
// 				ID:            art.ID,
// 				Slug:          art.Slug,
// 				Title:         art.Title,
// 				Subtitle:      art.Subtitle,
// 				Leading:       art.Leading,
// 				Author:        art.Author,
// 				PublishedAt:   art.PublishedAt,
// 				Tags:          art.Tags,
// 				Revision:      entry.Revision(),
// 				StructVersion: art.StructVersion,
// 			})
// 		}

// 		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: articleListResponse{Articles: articles}})
// 	}()
// }

// func (c *rtClient) handleArticleGet(id string, inbox string) {
// 	if !c.isAllowedKV("article", id) {
// 		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "insufficient permissions"}})
// 		return
// 	}

// 	go func() {
// 		kv, err := c.srv.js.KeyValue("article")
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to access article bucket"}})
// 			return
// 		}

// 		entry, err := kv.Get(id)
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "article not found"}})
// 			return
// 		}

// 		var art articleResponse
// 		if err := json.Unmarshal(entry.Value(), &art); err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to parse article"}})
// 			return
// 		}

// 		art.Revision = entry.Revision()
// 		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: art})
// 	}()
// }

// func (c *rtClient) handleArticleCreate(req articleCreateRequest, inbox string) {
// 	if !c.isAllowedKV("article", ">") {
// 		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "insufficient permissions"}})
// 		return
// 	}

// 	go func() {
// 		kv, err := c.srv.js.KeyValue("article")
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to access article bucket"}})
// 			return
// 		}

// 		// Generate new UUID for the article
// 		id := uuid.New().String()

// 		article := articleResponse{
// 			ID:            id,
// 			Slug:          id, // Use ID as slug initially
// 			Title:         req.Title,
// 			Subtitle:      req.Subtitle,
// 			Leading:       req.Leading,
// 			Content:       req.Content,
// 			Author:        c.id, // Use current user ID
// 			PublishedAt:   req.PublishedAt,
// 			Tags:          req.Tags,
// 			StructVersion: 1,
// 			Revision:      1,
// 		}

// 		data, err := json.Marshal(article)
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to marshal article"}})
// 			return
// 		}

// 		rev, err := kv.Create(id, data)
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to create article"}})
// 			return
// 		}

// 		article.Revision = rev
// 		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: article})
// 	}()
// }

// func (c *rtClient) handleArticleUpdate(id string, req articleUpdateRequest, inbox string) {
// 	if !c.isAllowedKV("article", id) {
// 		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "insufficient permissions"}})
// 		return
// 	}

// 	go func() {
// 		kv, err := c.srv.js.KeyValue("article")
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to access article bucket"}})
// 			return
// 		}

// 		// Get existing article
// 		entry, err := kv.Get(id)
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "article not found"}})
// 			return
// 		}

// 		var existing articleResponse
// 		if err := json.Unmarshal(entry.Value(), &existing); err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to parse existing article"}})
// 			return
// 		}

// 		// Update fields if provided
// 		if req.Title != "" {
// 			existing.Title = req.Title
// 		}
// 		if req.Subtitle != "" {
// 			existing.Subtitle = req.Subtitle
// 		}
// 		if req.Leading != "" {
// 			existing.Leading = req.Leading
// 		}
// 		if req.Content != "" {
// 			existing.Content = req.Content
// 		}
// 		if req.Tags != nil {
// 			existing.Tags = req.Tags
// 		}
// 		if req.PublishedAt != 0 {
// 			existing.PublishedAt = req.PublishedAt
// 		}

// 		existing.Revision++

// 		data, err := json.Marshal(existing)
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to marshal updated article"}})
// 			return
// 		}

// 		rev, err := kv.Put(id, data)
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to update article"}})
// 			return
// 		}

// 		existing.Revision = rev
// 		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: existing})
// 	}()
// }

// func (c *rtClient) handleArticleDelete(id string, inbox string) {
// 	if !c.isAllowedKV("article", id) {
// 		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "insufficient permissions"}})
// 		return
// 	}

// 	go func() {
// 		kv, err := c.srv.js.KeyValue("article")
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to access article bucket"}})
// 			return
// 		}

// 		err = kv.Delete(id)
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to delete article"}})
// 			return
// 		}

// 		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"status": "deleted"}})
// 	}()
// }

// func (c *rtClient) handleArticleRevision(id string, revision uint64, inbox string) {
// 	if !c.isAllowedKV("article", id) {
// 		c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "insufficient permissions"}})
// 		return
// 	}

// 	go func() {
// 		kv, err := c.srv.js.KeyValue("article")
// 		if err != nil {
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to access article bucket"}})
// 			return
// 		}

// 		if revision == 0 {
// 			// Get history
// 			history, err := kv.History(id)
// 			if err != nil {
// 				c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to get article history"}})
// 				return
// 			}

// 			var revisions []articleResponse
// 			for _, entry := range history {
// 				if entry.Operation() == nats.KeyValuePut {
// 					var art articleResponse
// 					if err := json.Unmarshal(entry.Value(), &art); err != nil {
// 						continue
// 					}
// 					art.Revision = entry.Revision()
// 					revisions = append(revisions, art)
// 				}
// 			}

// 			// Reverse to show newest first
// 			for i, j := 0, len(revisions)-1; i < j; i, j = i+1, j-1 {
// 				revisions[i], revisions[j] = revisions[j], revisions[i]
// 			}

// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: articleHistoryResponse{Revisions: revisions}})
// 		} else {
// 			// Get specific revision
// 			entry, err := kv.GetRevision(id, revision)
// 			if err != nil {
// 				c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "revision not found"}})
// 				return
// 			}

// 			var art articleResponse
// 			if err := json.Unmarshal(entry.Value(), &art); err != nil {
// 				c.send(serverMsg{Op: "reply", Inbox: inbox, Data: map[string]string{"error": "failed to parse article revision"}})
// 				return
// 			}

// 			art.Revision = entry.Revision()
// 			c.send(serverMsg{Op: "reply", Inbox: inbox, Data: art})
// 		}
// 	}()
// }

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
