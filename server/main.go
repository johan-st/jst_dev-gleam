package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"jst_dev/server/blog"
	"jst_dev/server/jst_log"
	"jst_dev/server/talk"
	"jst_dev/server/web"
	"jst_dev/server/who"

	"github.com/nats-io/nats.go"
)

const (
	SHARED_ENV_AppName   = "local-dev"
	SHARED_ENV_jwtSecret = "jst_dev_secret"
)

func main() {
	ctx := context.Background()
	if err := run(ctx, os.Stdout, os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "%s\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, w io.Writer, args []string) error {
	ctx, cancel := signal.NotifyContext(ctx, os.Interrupt)
	defer cancel()
	var (
		err     error
		lRoot   *jst_log.Logger
		l       *jst_log.Logger
		blogSvc *blog.Blog
		whoSvc  *who.Who
		nc      *nats.Conn
		conf    *GlobalConfig
	)

	// - conf
	conf, err = loadConf()
	if err != nil {
		return fmt.Errorf("load conf: %w", err)
	}

	// - logger (create)
	lRoot = jst_log.NewLogger(SHARED_ENV_AppName, jst_log.DefaultSubjects())
	l = lRoot.WithBreadcrumb("main")

	// - context
	ctx, cancel = context.WithCancel(ctx)
	defer cancel()

	// - talk
	l.Debug("starting talk")
	nc, err = talk.EmbeddedServer(
		context.Background(),
		conf.Talk,
		lRoot.WithBreadcrumb("talk"),
	)
	if err != nil {
		return fmt.Errorf("TALK, connection: %v", err)

	}
	defer nc.Close()

	// - logger (connect)
	lRoot.Connect(nc)
	jst_log.StdOut(nc, "log."+SHARED_ENV_AppName, jst_log.DefaultSubjects(), jst_log.LogLevelDebug)
	time.Sleep(1 * time.Millisecond)

	// - blog
	l.Debug("starting blog")
	blogSvc, err = blog.New(nc, lRoot.WithBreadcrumb("blog"))
	if err != nil {
		return fmt.Errorf("new blog: %w", err)
	}
	err = blogSvc.Start(ctx)
	if err != nil {
		return fmt.Errorf("start blog: %w", err)
	}

	// - web
	l.Debug("starting web")
	webSvc, err := web.New(ctx, nc, lRoot.WithBreadcrumb("web"))
	if err != nil {
		return fmt.Errorf("new web: %w", err)
	}
	err = webSvc.Start(ctx)
	if err != nil {
		return fmt.Errorf("start web: %w", err)
	}

	// --- Who ---
	l.Debug("starting who")
	whoConf := &who.Conf{
		Logger:    lRoot.WithBreadcrumb("who"),
		NatsConn:  nc,
		JwtSecret: []byte(SHARED_ENV_jwtSecret),
		HashSalt:  "jst_dev_salt",
	}
	whoSvc, err = who.New(whoConf)
	if err != nil {
		return fmt.Errorf("new who: %w", err)
	}
	err = whoSvc.Start(ctx)
	if err != nil {
		return fmt.Errorf("start who: %w", err)
	}

	// - debug
	// initDefaultUserCleanup := initDefaultUser(lRoot.WithBreadcrumb("initDefaultUser"), nc)

	// ------------------------------------------------------------
	// RUNNING
	// ------------------------------------------------------------

	l.Debug("started all services")
	// Wait for interrupt signal to gracefully shut down
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	// Wait for first interrupt
	<-sigCh
	cancel()

	l.Info("Received interrupt signal, starting graceful shutdown...")
	// if initDefaultUserCleanup != nil {
	// 	initDefaultUserCleanup()
	// }
	// Drain connections
	l.Debug("draining connections")
	err = nc.Drain()
	if err != nil {
		l.Error("Failed to drain connections: %v", err)
	}

	// Wait for second interrupt for force quit
	go func() {
		<-sigCh
		l.Warn("Received second interrupt signal, force quitting...")
		fmt.Println("Received second interrupt signal, force quitting...")
		// Sleep for a short time to allow for logging operations to complete
		time.Sleep(5 * time.Second)
		os.Exit(1)
	}()

	// Shutdown talk
	// talkSvc.Shutdown()
	fmt.Println("Server shutdown complete")

	return nil
}

func initDefaultUser(l *jst_log.Logger, nc *nats.Conn) func() {
	type userCreateReq struct {
		Username string `json:"username"`
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	type userCreateResp struct {
		ID string `json:"id"`
	}

	reqData := userCreateReq{
		Username: "johan",
		Email:    "johan@example.com",
		Password: "password",
	}
	reqDataBytes, err := json.Marshal(reqData)
	if err != nil {
		l.Error("marshal: %w", err)
		return nil
	}

	if nc == nil {
		l.Error("nc is nil")
		return nil
	}

	if nc.Status() != nats.CONNECTED {
		l.Error("nc is not connected")
		return nil
	}

	l.Debug("nc status: %s", nc.Status())
	l.Debug("nc connected: %t", nc.IsConnected())
	l.Debug("nc draining: %t", nc.IsDraining())
	l.Debug("nc reconnecting: %t", nc.IsReconnecting())
	l.Debug("nc closed: %t", nc.IsClosed())

	time.Sleep(1 * time.Second)

	l.Debug("requesting user create")
	msg, err := nc.Request("svc.who.users.create", reqDataBytes, 10*time.Second)
	if err != nil {
		l.Error("request: %w", err)
		return nil
	}

	var respData userCreateResp
	err = json.Unmarshal(msg.Data, &respData)
	if err != nil {
		l.Error("unmarshal: %w", err)
		return nil
	}

	l.Debug("got response: %+v", respData)
	return func() {
		l.Debug("cleaning up")
		nc.Publish("who.users.delete", []byte(respData.ID))
	}
}
