package web

import (
	"context"
	"jst_dev/server/jst_log"
	"net/http"
	"time"

	"golang.org/x/time/rate"

	"github.com/coder/websocket"
)

const (
	recvRateLimit      = 100 * time.Millisecond
	recvRateLimitBurst = 8
)

type ClientMsg string

const (
	ClientInit ClientMsg = "client-init"
)

var (
	acceptOptions = &websocket.AcceptOptions{
		Subprotocols:    []string{"jst_dev"},
		OriginPatterns:  []string{"127.0.0.1:1234", "localhost:1234", "127.0.0.1:8080", "localhost:8080", "jst.dev"},
		CompressionMode: websocket.CompressionContextTakeover,
	}
)

// REF: https://github.com/coder/websocket/blob/master/internal/examples

type wsServer struct {
	recvRateLimiter *rate.Limiter
	logf            func(f string, v ...interface{})
}

func newWsServer(l *jst_log.Logger) *wsServer {
	cs := &wsServer{
		logf:            l.Debug,
		recvRateLimiter: rate.NewLimiter(rate.Every(recvRateLimit), recvRateLimitBurst),
	}
	return cs
}

func (cs *wsServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, acceptOptions)
	if err != nil {
		cs.logf("%v", err)
		return
	}
	go cs.handleConn(conn)
}

func (cs *wsServer) handleConn(conn *websocket.Conn) {
	defer conn.Close(websocket.StatusNormalClosure, "np reason")
	for {
		msgType, msg, err := conn.Read(context.Background())
		if err != nil {
			cs.logf("%v", err)
			return
		}
		// msgTypeStr := websocket.MessageType(msgType)
		switch msgType {
		case websocket.MessageText:
			if string(msg) == string(ClientInit) {
				go cs.handleClientInit(conn, msg)
			} else {
				cs.logf("unknown message: %s", string(msg))
			}
		case websocket.MessageBinary:
			cs.logf("binary not supported")
		}
	}
}

func (cs *wsServer) handleClientInit(conn *websocket.Conn, data []byte) {
	cs.logf("client-init: %s", string(data))
	articleMetadata := []byte(
		`{
			"type": "articles_metadata",
			"articles": [
				{
					"id": 1,
					"slug": "nats-all-the-way-down",
					"revision": 1,
					"title": "NATS all the way down",
					"subtitle": "..or, how to replace your stack with one tool.",
					"leading": "I've fallen in love several times these last few years since I started writing code for a living. A few highlights are Docker, Elm, functional programming, Go, simple and portable file formats, my son, markdown, gleam and now NATS. Each infatuation has taught me something important about a technology and usually also about myself."
				},
				{
					"id": 2,
					"slug": "title-missing-article",
					"revision": 12,
					"title": "title missing article",
					"subtitle": "..or, how to not be there",
					"leading": "This article is missing altoghether... Triggering an error "
				},
				{
					"id": 3,
					"slug": "unsupported-format",
					"revision": 4,
					"title": "unsupported format",
					"subtitle": "..or, dealing with the unknown",
					"leading": "This article contains unsuportent content types"
				}
			]
		}`)
	conn.Write(context.Background(), websocket.MessageText, articleMetadata)
}
