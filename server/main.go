package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"jst_dev/server/articles"
	"jst_dev/server/jst_log"
	"jst_dev/server/ntfy"
	"jst_dev/server/talk"
	"jst_dev/server/urlShort"
	web "jst_dev/server/web"
	"jst_dev/server/who"

	"github.com/joho/godotenv"
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
	cleanShutdown := &sync.WaitGroup{}
	ctx, cancel := signal.NotifyContext(ctx, os.Interrupt)
	defer cancel()

	// - conf
	conf, err := loadConf(getenv)
	if err != nil {
		return fmt.Errorf("load conf: %w", err)
	}

	// - logger (create)
	lRoot := jst_log.NewLogger(conf.AppName, jst_log.DefaultSubjects())
	l := lRoot.WithBreadcrumb("main")

	// - context
	ctx, cancel = context.WithCancel(ctx)
	defer cancel()

	// - talk
	l.Debug("starting talk")
	var nc *nats.Conn
	if conf.Flags.NatsEmbedded {
		nc, err = talk.EmbeddedServer(
			context.Background(),
			conf.Talk,
			lRoot.WithBreadcrumb("talk"),
		)
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
		l.Fatal("Failed to connect to NATS cluster: %v", err)
		panic(fmt.Sprintf("Failed to connect to NATS cluster: %v", err))
	}
	defer nc.Close()

	// Verify connection is established
	if nc.Status() != nats.CONNECTED {
		l.Fatal("NATS connection not in CONNECTED state: %s", nc.Status())
		panic(fmt.Sprintf("NATS connection not in CONNECTED state: %s", nc.Status()))
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
	// err = blogSvc.Start(ctx)
	// if err != nil {
	// 	return fmt.Errorf("start blog: %w", err)
	// }

	// - ntfy
	l.Debug("starting ntfy")
	ntfySvc, err := ntfy.NewWithConfig(ctx, nc, lRoot.WithBreadcrumb("ntfy"), ntfy.DefaultNtfyServer, conf.NtfyToken)
	if err != nil {
		return fmt.Errorf("new ntfy: %w", err)
	}
	err = ntfySvc.Start(ctx)
	if err != nil {
		return fmt.Errorf("start ntfy: %w", err)
	}

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
	err = whoSvc.Start(ctx)
	if err != nil {
		return fmt.Errorf("start who: %w", err)
	}

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
	err = shortUrlSvc.Start(ctx)
	if err != nil {
		return fmt.Errorf("start short url: %w", err)
	}

	// - articles
	l.Debug("starting articles")
	articleRepo, err := articles.Repo(ctx, nc, lRoot.WithBreadcrumb("articles"))
	if err != nil {
		return fmt.Errorf("new articles: %w", err)
	}

	// - web
	l.Debug("http server, start")
	httpServer := web.New(ctx, nc, conf.WebJwtSecret, lRoot.WithBreadcrumb("http"), articleRepo, conf.Flags.ProxyFrontend)
	go httpServer.Run(cleanShutdown, conf.WebPort)

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

	// ------------------------------------------------------------
	// RUNNING
	// ------------------------------------------------------------

	l.Debug("started all services")

	// ------------------------------------------------------------
	// SHUTDOWN
	// ------------------------------------------------------------

	// Wait for interrupt signal to gracefully shut down
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	// Wait for first interrupt
	<-sigCh
	cancel()

	l.Info("Received interrupt signal, starting graceful shutdown...")

	// Drain connections
	l.Debug("draining connections")
	err = nc.Drain()
	if err != nil {
		l.Error("Failed to drain connections: %v", err)
	}
	
	// Check final connection status
	if nc.Status() != nats.CLOSED {
		l.Debug("closing NATS connection")
		nc.Close()
	}

	// Wait for second interrupt for force quit
	go func() {
		<-sigCh
		l.Warn("Received second interrupt signal, force quitting...")
		fmt.Println("Received second interrupt signal, force quitting...")
		// Sleep for a short time to allow for logging operations to complete
		time.Sleep(1 * time.Second)
		os.Exit(1)
	}()

	// Shutdown talk
	// talkSvc.Shutdown()
	cleanShutdown.Wait()
	fmt.Println("Server shutdown complete")
	return nil
}
