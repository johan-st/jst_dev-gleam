package web

import (
	"context"
	"encoding/json"
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

// Capabilities with pattern-based permissions

type capabilities struct {
	Subjects []string            `json:"subjects"`
	Buckets  map[string][]string `json:"buckets"` // bucket pattern -> allowed key patterns
	Commands []string            `json:"commands"`
	Streams  map[string][]string `json:"streams"` // stream pattern -> allowed filter subject patterns
}

type server struct {
	nc *nats.Conn
	js nats.JetStreamContext
}

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

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool { return true },
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
		if u.ID != "" { return u.ID }
	}
	// fallback for dev
	if q := r.URL.Query().Get("user_id"); q != "" { return q }
	return ""
}

// Authorization bootstrap (loads capabilities from Auth KV); fallback to minimal caps
func authorizeInitial(l *jst_log.Logger, s *server, userID string) capabilities {
	caps := capabilities{
		Subjects: nil,
		Buckets:  map[string][]string{},
		Commands: nil,
		Streams:  map[string][]string{},
	}
	if userID == "" { return caps }
	kv, err := s.js.KeyValue("auth.users")
	if err != nil { return caps }
	entry, err := kv.Get(userID)
	if err != nil || entry == nil { return caps }
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
			c.handleSub(m.Target)
		case "unsub":
			c.handleUnsub(m.Target)
		case "kv_sub":
			var opts struct{ Pattern string `json:"pattern"` }
			_ = json.Unmarshal(m.Data, &opts)
			c.handleKVSub(m.Target, opts.Pattern)
		case "js_sub":
			var opts struct{
				StartSeq uint64 `json:"start_seq"`
				Batch    int    `json:"batch"`
				Filter   string `json:"filter"`
			}
			_ = json.Unmarshal(m.Data, &opts)
			c.handleJSSub(m.Target, opts.StartSeq, opts.Batch, opts.Filter)
		case "cmd":
			c.handleCommand(m.Target, m.Data, m.Inbox)
		}
	}
}

func (c *rtClient) unsubscribeAll() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, s := range c.subs { _ = s.Unsubscribe() }
	for _, w := range c.kvWatchers { w.Stop() }
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
		if pi == "*" { continue }
		if pi != si { return false }
	}
	return len(su) == len(pp) || (len(pp) > 0 && pp[len(pp)-1] == ">")
}

func containsPattern(patterns []string, subject string) bool {
	for _, p := range patterns {
		if subjectMatch(p, subject) { return true }
	}
	return false
}

func (c *rtClient) isAllowedSubject(subject string) bool { return containsPattern(c.caps.Subjects, subject) }

func (c *rtClient) isAllowedKV(bucket, keyPattern string) bool {
	for bucketPattern, allowedKeys := range c.caps.Buckets {
		if subjectMatch(bucketPattern, bucket) {
			if keyPattern == "" { return containsPattern(allowedKeys, ">") }
			return containsPattern(allowedKeys, keyPattern)
		}
	}
	return false
}

func (c *rtClient) isAllowedStream(stream, filter string) bool {
	for streamPattern, allowedFilters := range c.caps.Streams {
		if subjectMatch(streamPattern, stream) {
			if filter == "" { return containsPattern(allowedFilters, ">") }
			return containsPattern(allowedFilters, filter)
		}
	}
	return false
}

// ---- Handlers

func (c *rtClient) handleSub(subject string) {
	if !c.isAllowedSubject(subject) { return }
	sub, err := c.srv.nc.Subscribe(subject, func(m *nats.Msg) {
		var payload interface{}
		if err := json.Unmarshal(m.Data, &payload); err != nil { payload = string(m.Data) }
		c.send(serverMsg{Op: "msg", Target: subject, Data: payload})
	})
	if err != nil { return }
	c.mu.Lock(); c.subs[subject] = sub; c.mu.Unlock()
}

func (c *rtClient) handleUnsub(subject string) {
	c.mu.Lock(); defer c.mu.Unlock()
	if s, ok := c.subs[subject]; ok { _ = s.Unsubscribe(); delete(c.subs, subject) }
	if w, ok := c.kvWatchers[subject]; ok { w.Stop(); delete(c.kvWatchers, subject) }
}

func (c *rtClient) handleKVSub(bucket, pattern string) {
	if !c.isAllowedKV(bucket, pattern) { return }
	kv, err := c.srv.js.KeyValue(bucket)
	if err != nil { return }
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
	if watcher == nil { return }
	c.kvWatchers[bucket] = watcher
	go func() {
		for {
			select {
			case <-c.ctx.Done(): watcher.Stop(); return
			case entry := <-watcher.Updates():
				if entry == nil { continue }
				// If we had to fallback to WatchAll, filter by pattern here
				if pattern != "" && !subjectMatch(pattern, entry.Key()) { continue }
				c.send(serverMsg{Op: "msg", Target: bucket, Data: map[string]interface{}{
					"key": entry.Key(), "value": string(entry.Value()), "rev": entry.Revision(),
				}})
			}
		}
	}()
}

func (c *rtClient) handleJSSub(stream string, startSeq uint64, batch int, filter string) {
	if !c.isAllowedStream(stream, filter) { return }
	// Require a filter subject for JS subscribe to ensure a concrete subject
	if filter == "" { return }
	opts := []nats.SubOpt{ nats.StartSequence(startSeq) }
	if batch > 0 { opts = append(opts, nats.MaxDeliver(batch)) }
	sub, err := c.srv.js.Subscribe(filter, func(m *nats.Msg) {
		c.send(serverMsg{Op: "msg", Target: stream, Data: json.RawMessage(m.Data)})
	}, opts...)
	if err != nil { return }
	c.mu.Lock(); c.subs[stream] = sub; c.mu.Unlock()
}

func (c *rtClient) handleCommand(target string, data json.RawMessage, inbox string) {
	if !containsPattern(c.caps.Commands, target) { return }
	go func() {
		ctx, cancel := context.WithTimeout(c.ctx, 5*time.Second)
		defer cancel()
		msg, err := c.srv.nc.RequestWithContext(ctx, target, data)
		if err != nil {
			c.send(serverMsg{Op: "reply", Target: target, Inbox: inbox, Data: map[string]string{"error": err.Error()}})
			return
		}
		var payload interface{}
		if err := json.Unmarshal(msg.Data, &payload); err != nil { payload = string(msg.Data) }
		c.send(serverMsg{Op: "reply", Target: target, Inbox: inbox, Data: payload})
	}()
}

// Capability updates via Auth KV
func (c *rtClient) watchAuthKV() {
	kv, err := c.srv.js.KeyValue("auth.users")
	if err != nil { return }
	watcher, err := kv.Watch(c.id)
	if err != nil { return }
	go func() {
		for {
			select {
			case <-c.ctx.Done(): watcher.Stop(); return
			case entry := <-watcher.Updates():
				if entry == nil { continue }
				var newCaps capabilities
				if err := json.Unmarshal(entry.Value(), &newCaps); err != nil { continue }
				c.applyCapabilities(newCaps)
				c.send(serverMsg{Op: "cap_update", Data: newCaps})
			}
		}
	}()
}

func (c *rtClient) applyCapabilities(newCaps capabilities) {
	c.mu.Lock(); defer c.mu.Unlock()
	// Unsubscribe from disallowed subjects
	for subject, sub := range c.subs {
		if subject == "" { continue }
		if !containsPattern(newCaps.Subjects, subject) {
			_ = sub.Unsubscribe()
			delete(c.subs, subject)
		}
	}
	for bucket, w := range c.kvWatchers {
		allowed := false
		for bucketPattern := range newCaps.Buckets {
			if subjectMatch(bucketPattern, bucket) { allowed = true; break }
		}
		if !allowed { w.Stop(); delete(c.kvWatchers, bucket) }
	}
	c.caps = newCaps
}
