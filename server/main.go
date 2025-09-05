package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"sync"
	"time"

	"jst_dev/server/articles"
	"jst_dev/server/convo"
	convoApi "jst_dev/server/convo/api"
	"jst_dev/server/jst_log"
	"jst_dev/server/ntfy"
	"jst_dev/server/service"
	"jst_dev/server/talk"
	"jst_dev/server/urlShort"
	web "jst_dev/server/web"
	"jst_dev/server/who"

	"github.com/joho/godotenv"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
)

// main is the entry point of the server application, initializing the context and running the server.
// If an error occurs during startup or execution, it prints the error to standard error and exits with status code 1.
func main() {
	ctx := context.Background()
	_ = godotenv.Load()
	if err := run(
		ctx,
		// os.Args,
		// os.Stdin,
		// os.Stdout,
		// os.Stderr,
		os.Getenv,
		// os.Getwd,
	); err != nil {
		fmt.Fprintf(os.Stderr, "%s\n", err)
		os.Exit(1)
	}
}

// run initializes and starts all core services, manages their lifecycle, and handles graceful shutdown on interrupt signals.
//
// It loads configuration, sets up logging, starts embedded messaging, blog, HTTP, and user management services, and waits for OS interrupts to trigger a coordinated shutdown. Returns an error if any service fails to initialize or start.
func run(
	ctx context.Context,
	// args []string, // The arguments passed in when executing your program. It's also used for parsing flags.
	// stdin io.Reader, // For reading input
	// stdout io.Writer, // For writing output
	// stderr io.Writer, // For writing error logs
	getenv func(string) string, //	For reading environment variables
	// getwd func() (string, error), //	Get the working directory
) error {
	var (
		cleanShutdown                = &sync.WaitGroup{}
		ns            *server.Server = nil
		nc            *nats.Conn     = nil
	)

	// Create signal context for graceful shutdown
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt)
	defer stop()

	// - conf
	conf, err := loadConf(getenv)
	if err != nil {
		return fmt.Errorf("load conf: %w", err)
	}

	// - logger (create)
	lRoot := jst_log.NewLogger(conf.AppName, jst_log.DefaultSubjects())
	l := lRoot.WithBreadcrumb("main")

	// - talk
	l.Debug("starting talk")
	if conf.Flags.NatsEmbedded {
		nc, ns, err = talk.EmbeddedServer(
			context.Background(),
			conf.Talk,
			lRoot.WithBreadcrumb("talk"),
		)
		if err != nil {
			return fmt.Errorf("embedded NATS server: %w", err)
		}
	} else {
		l.Info("connecting to nats..")
		// nc, err = nats.Connect(
		// 	"tls://connect.ngs.global",
		// 	// nats.UserCredentials(".creds"),
		// 	nats.Name(os.Getenv("FLY_APP_NAME")+"-"+os.Getenv("PRIMARY_REGION")),
		// )
		// if err != nil {
		nc, err = nats.Connect("tls://connect.ngs.global",
			nats.UserJWTAndSeed(
				conf.NatsJWT,
				conf.NatsNKEY,
			),
			nats.Name(conf.AppName+"-"+conf.Region),
			// Add connection event handlers
			nats.DisconnectHandler(func(nc *nats.Conn) {
				l.Error("NATS connection disconnected")
			}),
			nats.ReconnectHandler(func(nc *nats.Conn) {
				l.Info("NATS connection reconnected")
			}),
			nats.ClosedHandler(func(nc *nats.Conn) {
				l.Error("NATS connection closed")
			}),
			nats.ErrorHandler(func(nc *nats.Conn, sub *nats.Subscription, err error) {
				l.Error("NATS error: %v", err)
			}),
			nats.MaxReconnects(60),
			nats.ReconnectWait(1*time.Second),
			nats.ReconnectJitter(100*time.Millisecond, 1*time.Second),
			nats.Timeout(2*time.Second),
			nats.PingInterval(2*time.Second),
			nats.MaxPingsOutstanding(2),
		)

		// }
	}
	if err != nil {
		// Panic on initial connection failure - server cannot function without NATS
		l.Fatal("failed to connect to NATS cluster: %v", err)
		return fmt.Errorf("failed to connect to NATS cluster: %v", err)
	}

	// Verify connection is established
	if nc.Status() != nats.CONNECTED {
		l.Fatal("NATS connection not in CONNECTED state: %s", nc.Status())
		return fmt.Errorf("NATS connection not in CONNECTED state: %s", nc.Status())
	}

	l.Info("Successfully connected to NATS cluster")

	// - logger (connect)
	lRoot.Connect(nc)

	// Parse log level from configuration
	logLevel, err := jst_log.LogLevelFromString(conf.Flags.LogLevel)
	if err != nil {
		log.Fatalf("Failed to parse log level: %v\n", err)
	}

	jst_log.StdOut(nc, "log."+conf.AppName, jst_log.DefaultSubjects(), logLevel)
	time.Sleep(1 * time.Millisecond)

	// - blog
	// l.Debug("starting blog")
	// blogSvc, err := blog.New(nc, lRoot.WithBreadcrumb("blog"))
	// if err != nil {
	// 	return fmt.Errorf("new blog: %w", err)
	// }

	// - ntfy
	l.Debug("starting ntfy")
	ntfySvc, err := ntfy.NewWithConfig(ctx, nc, lRoot.WithBreadcrumb("ntfy"), ntfy.DefaultNtfyServer, conf.NtfyToken)
	if err != nil {
		return fmt.Errorf("new ntfy: %w", err)
	}
	service.Run(ctx, cleanShutdown, &ntfySvc)

	// - who
	l.Debug("starting who")
	whoConf := &who.Conf{
		Logger:    lRoot.WithBreadcrumb("who"),
		NatsConn:  nc,
		JwtSecret: []byte(conf.WebJwtSecret),
		HashSalt:  "jst_dev_salt",
	}
	whoSvc, err := who.New(ctx, whoConf)
	if err != nil {
		return fmt.Errorf("new who: %w", err)
	}
	service.Run(ctx, cleanShutdown, whoSvc)

	// - short url
	l.Debug("starting short url service")
	shortUrlConf := &urlShort.Conf{
		Logger:   lRoot.WithBreadcrumb("urlshort"),
		NatsConn: nc,
	}
	shortUrlSvc, err := urlShort.New(ctx, shortUrlConf)
	if err != nil {
		return fmt.Errorf("new short url: %w", err)
	}
	service.Run(ctx, cleanShutdown, shortUrlSvc)

	// - articles
	l.Debug("starting articles")
	articleRepo, err := articles.Repo(ctx, nc, lRoot.WithBreadcrumb("articles"))
	if err != nil {
		return fmt.Errorf("new articles: %w", err)
	}

	// - convo
	l.Debug("starting convo")
	convoSvc, err := convo.New(&convo.Conf{
		Logger:   lRoot.WithBreadcrumb("convo"),
		NatsConn: nc,
	})
	if err != nil {
		return fmt.Errorf("new convo: %w", err)
	}
	service.Run(ctx, cleanShutdown, convoSvc)

	// - web
	l.Debug("http server, start")
	httpServer := web.New(ctx, nc, conf.WebJwtSecret, lRoot.WithBreadcrumb("http"), articleRepo, conf.Flags.ProxyFrontend, conf.Flags.SlowSocket)
	service.Run(ctx, cleanShutdown, httpServer)

	// - time ticker publisher (NATS core)
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case t := <-ticker.C:
				// Get Fly.io environment variables
				flyAppName := os.Getenv("FLY_APP_NAME")
				flyRegion := os.Getenv("FLY_REGION")

				// Create payload with Fly.io identifiers
				payload := fmt.Sprintf(`{"unixMilli": %d, "fly_app_name": "%s", "fly_region": "%s"}`,
					t.UnixMilli(), flyAppName, flyRegion)
				_ = nc.Publish("time.seconds", []byte(payload))
			}
		}
	}()

	// - example
	if conf.Flags.DebugMode {
		l.Info("starting example services")
		svcExample1, _ := service.New(1)
		service.Run(ctx, cleanShutdown, svcExample1)
		svcExample2, _ := service.New(2)
		service.Run(ctx, cleanShutdown, svcExample2)
		svcExample3, _ := service.New(3)
		service.Run(ctx, cleanShutdown, svcExample3)
		svcExample4, _ := service.New(4)
		service.Run(ctx, cleanShutdown, svcExample4)
		svcExample5, _ := service.New(5)
		service.Run(ctx, cleanShutdown, svcExample5)
		l.Info("Example service started")
	}

	// - convo message DEBUG
	msgChan, closeSub, err := convoApi.MessageSub(nc, l.WithBreadcrumb("convo-message"), "0442bf5b-10c8-482f-9d0b-769c3f2e3f3a")
	if err != nil {
		return fmt.Errorf("failed to subscribe to messages: %w", err)
	}
	go func() {
		time.Sleep(1 * time.Second)
		l.Debug("subscribed to messages")
		for msg := range msgChan {
			l.Debug("message received: %v", msg)
		}
		l.Debug("unsubscribed from messages")
	}()

	// ------------------------------------------------------------
	// SHUTDOWN
	// ------------------------------------------------------------
	<-ctx.Done()
	fmt.Println("starting graceful shutdown...")

	closeSub()

	// Wait for all services to cleanly shutdown with timeout
	shutdownDone := make(chan struct{})
	go func() {
		cleanShutdown.Wait()
		close(shutdownDone)
	}()

	select {
	case <-shutdownDone:
		l.Info("all services shutdown gracefully")
	case <-time.After(10 * time.Second):
		l.Warn("shutdown timeout reached, forcing shutdown")
	}

	// Close NATS connection with flush timeout
	nc.FlushTimeout(5 * time.Second)
	nc.Close()

	// Shutdown embedded NATS server if running (after connection is closed)
	if ns != nil {
		ns.Shutdown()
		ns.WaitForShutdown()
	}

	fmt.Println("shutdown complete")
	return nil
}
