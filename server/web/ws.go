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
		logf:            l.WithBreadcrumb("websocket").Debug,
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
	defer conn.Close(websocket.StatusNormalClosure, "")

	for {
		msgType, msg, err := conn.Read(context.Background())
		if err != nil {
			cs.logf("%v", err)
			return
		}
		msgTypeStr := websocket.MessageType(msgType)
		cs.logf("%s: %s", msgTypeStr, msg)

	}
}
