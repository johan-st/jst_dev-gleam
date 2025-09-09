package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"sync"
	"time"

	"jst_dev/server/core"
	"jst_dev/server/jst_log"

	"github.com/joho/godotenv"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
)

// mainNew is the entry point of the server application using the new unified architecture
func mainNew() {
	ctx := context.Background()
	_ = godotenv.Load()

	if err := runNew(ctx, os.Getenv); err != nil {
		fmt.Fprintf(os.Stderr, "%s\n", err)
		os.Exit(1)
	}
}

// runNew initializes and starts all services using the new unified architecture
func runNew(
	ctx context.Context,
	getenv func(string) string,
) error {
	var (
		cleanShutdown                = &sync.WaitGroup{}
		ns            *server.Server = nil
		nc            *nats.Conn     = nil
	)

	// Create signal context for graceful shutdown
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt)
	defer stop()

	// Load configuration
	config, err := loadGlobalConfig(getenv)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	// Setup NATS connection
	nc, ns, err = setupNATS(ctx, config)
	if err != nil {
		return fmt.Errorf("setup NATS: %w", err)
	}
	defer func() {
		if nc != nil {
			nc.FlushTimeout(5 * time.Second)
			nc.Close()
		}
		if ns != nil {
			ns.Shutdown()
			ns.WaitForShutdown()
		}
	}()

	// Set NATS connection in config
	config.NatsConn = nc

	// Setup logging
	if err := setupLogging(config); err != nil {
		return fmt.Errorf("setup logging: %w", err)
	}

	// Create service factory and register all services
	serviceFactory := core.NewServiceFactory(config)
	if err := serviceFactory.CreateAllServices(ctx); err != nil {
		return fmt.Errorf("create services: %w", err)
	}

	// Get service registry
	registry := serviceFactory.GetRegistry()

	// Initialize all services
	if err := registry.InitializeAll(ctx); err != nil {
		return fmt.Errorf("initialize services: %w", err)
	}

	// Start all services
	if err := registry.StartAll(ctx, cleanShutdown); err != nil {
		return fmt.Errorf("start services: %w", err)
	}

	// Start background tasks
	startBackgroundTasks(ctx, nc, config)

	// Wait for shutdown signal
	<-ctx.Done()
	fmt.Println("starting graceful shutdown...")

	// Shutdown all services
	if err := registry.ShutdownAll(ctx); err != nil {
		fmt.Printf("shutdown error: %v\n", err)
	}

	// Wait for all services to cleanly shutdown with timeout
	shutdownDone := make(chan struct{})
	go func() {
		cleanShutdown.Wait()
		close(shutdownDone)
	}()

	select {
	case <-shutdownDone:
		fmt.Println("all services shutdown gracefully")
	case <-time.After(10 * time.Second):
		fmt.Println("shutdown timeout reached, forcing shutdown")
	}

	fmt.Println("shutdown complete")
	return nil
}

// loadGlobalConfig loads and validates the global configuration
func loadGlobalConfig(getenv func(string) string) (*core.GlobalConfig, error) {
	// Load configuration from environment
	config := &core.GlobalConfig{
		AppName:        getenv("FLY_APP_NAME"),
		Region:         getenv("FLY_REGION"),
		PrimaryRegion:  getenv("PRIMARY_REGION"),
		NatsJWT:        getenv("NATS_JWT"),
		NatsNKEY:       getenv("NATS_NKEY"),
		WebPort:        getenv("PORT"),
		WebJwtSecret:   getenv("JWT_SECRET"),
		WebHashSalt:    getenv("WEB_HASH_SALT"),
		NtfyToken:      getenv("NTFY_TOKEN"),
		LogLevel:       getenv("LOG_LEVEL"),
		ServiceTimeout: 30 * time.Second,
	}

	// Set defaults
	if config.LogLevel == "" {
		config.LogLevel = "info"
	}
	if config.Region == "" {
		config.Region = "local"
	}

	// Validate required fields
	if err := config.Validate(); err != nil {
		return nil, fmt.Errorf("config validation failed: %w", err)
	}

	return config, nil
}

// setupNATS establishes the NATS connection
func setupNATS(ctx context.Context, config *core.GlobalConfig) (*nats.Conn, *server.Server, error) {
	var nc *nats.Conn
	var ns *server.Server
	var err error

	if config.NatsEmbedded {
		// Start embedded NATS server
		ns, err = server.NewServer(&server.Options{
			Host:   "127.0.0.1",
			Port:   4222,
			NoLog:  true,
			NoSigs: true,
		})
		if err != nil {
			return nil, nil, fmt.Errorf("create embedded NATS server: %w", err)
		}

		go ns.Start()
		if !ns.ReadyForConnections(10 * time.Second) {
			ns.Shutdown()
			return nil, nil, fmt.Errorf("embedded NATS server not ready")
		}

		// Connect to embedded server
		nc, err = nats.Connect("nats://127.0.0.1:4222")
		if err != nil {
			ns.Shutdown()
			return nil, nil, fmt.Errorf("connect to embedded NATS: %w", err)
		}
	} else {
		// Connect to external NATS
		nc, err = nats.Connect("tls://connect.ngs.global",
			nats.UserJWTAndSeed(config.NatsJWT, config.NatsNKEY),
			nats.Name(config.AppName+"-"+config.Region),
			nats.MaxReconnects(60),
			nats.ReconnectWait(1*time.Second),
			nats.ReconnectJitter(100*time.Millisecond, 1*time.Second),
			nats.Timeout(2*time.Second),
			nats.PingInterval(2*time.Second),
			nats.MaxPingsOutstanding(2),
		)
		if err != nil {
			return nil, nil, fmt.Errorf("connect to NATS: %w", err)
		}
	}

	// Verify connection
	if nc.Status() != nats.CONNECTED {
		return nil, nil, fmt.Errorf("NATS connection not in CONNECTED state: %s", nc.Status())
	}

	return nc, ns, nil
}

// setupLogging configures the logging system
func setupLogging(config *core.GlobalConfig) error {
	// Create root logger
	config.Logger = jst_log.NewLogger(config.AppName, jst_log.DefaultSubjects())

	// Connect logger to NATS
	config.Logger.Connect(config.NatsConn)

	// Parse log level
	logLevel, err := jst_log.LogLevelFromString(config.LogLevel)
	if err != nil {
		return fmt.Errorf("parse log level: %w", err)
	}

	// Setup stdout logging
	jst_log.StdOut(config.NatsConn, "log."+config.AppName, jst_log.DefaultSubjects(), logLevel)
	time.Sleep(1 * time.Millisecond)

	return nil
}

// startBackgroundTasks starts background tasks that don't fit into the service model
func startBackgroundTasks(ctx context.Context, nc *nats.Conn, config *core.GlobalConfig) {
	// Time ticker publisher (NATS core)
	if config.Region != "local" {
		go func() {
			ticker := time.NewTicker(5 * time.Second)
			defer ticker.Stop()

			for {
				select {
				case <-ctx.Done():
					return
				case t := <-ticker.C:
					payload := fmt.Sprintf(`{"unixMilli": %d, "fly_app_name": "%s", "fly_region": "%s", "fly_primary_region": "%s"}`,
						t.UnixMilli(), config.AppName, config.Region, config.PrimaryRegion)
					_ = nc.Publish("time.seconds", []byte(payload))
				}
			}
		}()
	}

	// Development mode tasks
	if config.DebugMode {
		go func() {
			ticker := time.NewTicker(5 * time.Second)
			defer ticker.Stop()

			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					// Example: Publish test messages
					// This would be replaced with actual development tasks
					_ = nc.Publish("dev.test", []byte(`{"message": "test"}`))
				}
			}
		}()
	}
}

// Example of how to add health check endpoint
func addHealthCheckEndpoint(registry *core.ServiceRegistry) {
	// This would be implemented as a separate service or integrated into the web service
	// For now, it's just an example of how you might expose service health
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()

		for {
			select {
			case <-ticker.C:
				health := registry.HealthCheck()
				states := registry.GetServiceStates()

				// Log health status
				for service, err := range health {
					state := states[service]
					if err != nil {
						log.Printf("Service %s (%s): UNHEALTHY - %v", service, state, err)
					} else {
						log.Printf("Service %s (%s): HEALTHY", service, state)
					}
				}
			}
		}
	}()
}
