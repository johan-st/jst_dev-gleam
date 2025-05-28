package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"jst_dev/server/blog"
	"jst_dev/server/jst_log"
	"jst_dev/server/talk"
	web "jst_dev/server/web"
	"jst_dev/server/who"
)

const (
	SHARED_ENV_AppName   = "local-dev"
	SHARED_ENV_jwtSecret = "jst_dev_secret"
)

// main is the entry point of the server application, initializing the context and running the server.
// If an error occurs during startup or execution, it prints the error to standard error and exits with status code 1.
func main() {
	ctx := context.Background()
	if err := run(
		ctx,
		// os.Args,
		// os.Stdin,
		// os.Stdout,
		// os.Stderr,
		// os.Getenv,
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
	// args []string, // The arguments passed in when executing your program. It’s also used for parsing flags.
	// stdin io.Reader, // For reading input
	// stdout io.Writer, // For writing output
	// stderr io.Writer, // For writing error logs
	// getenv func(string) string, //	For reading environment variables
	// getwd func() (string, error), //	Get the working directory
) error {
	cleanShutdown := &sync.WaitGroup{}
	ctx, cancel := signal.NotifyContext(ctx, os.Interrupt)
	defer cancel()

	// - conf
	conf, err := loadConf()
	if err != nil {
		return fmt.Errorf("load conf: %w", err)
	}

	// - logger (create)
	lRoot := jst_log.NewLogger(SHARED_ENV_AppName, jst_log.DefaultSubjects())
	l := lRoot.WithBreadcrumb("main")

	// - context
	ctx, cancel = context.WithCancel(ctx)
	defer cancel()

	// - talk
	l.Debug("starting talk")
	nc, err := talk.EmbeddedServer(
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
	blogSvc, err := blog.New(nc, lRoot.WithBreadcrumb("blog"))
	if err != nil {
		return fmt.Errorf("new blog: %w", err)
	}
	err = blogSvc.Start(ctx)
	if err != nil {
		return fmt.Errorf("start blog: %w", err)
	}

	// --- Who ---
	l.Debug("starting who")
	whoConf := &who.Conf{
		Logger:    lRoot.WithBreadcrumb("who"),
		NatsConn:  nc,
		JwtSecret: []byte(SHARED_ENV_jwtSecret),
		HashSalt:  "jst_dev_salt",
	}
	whoSvc, err := who.New(whoConf)
	if err != nil {
		return fmt.Errorf("new who: %w", err)
	}
	err = whoSvc.Start(ctx)
	if err != nil {
		return fmt.Errorf("start who: %w", err)
	}

	// - web
	l.Debug("http server, start")
	httpServer := web.New(ctx, nc, SHARED_ENV_jwtSecret, lRoot.WithBreadcrumb("http"))
	go httpServer.Run(cleanShutdown)

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
