package core

import (
	"fmt"
	"time"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
)

// GlobalConfig represents the global application configuration
type GlobalConfig struct {
	// Application metadata
	AppName       string
	Region        string
	PrimaryRegion string

	// NATS configuration
	NatsJWT      string
	NatsNKEY     string
	NatsEmbedded bool

	// Web server configuration
	WebPort       string
	WebJwtSecret  string
	WebHashSalt   string
	ProxyFrontend bool
	SlowSocket    time.Duration

	// Service configuration
	ServiceTimeout time.Duration

	// Logging
	LogLevel string

	// External services
	NtfyToken string

	// Development flags
	DebugMode bool

	// Shared resources
	Logger   *jst_log.Logger
	NatsConn *nats.Conn
}

// Validate checks if the configuration is valid
func (c *GlobalConfig) Validate() error {
	if c.AppName == "" {
		return fmt.Errorf("AppName is required")
	}
	if c.WebPort == "" {
		return fmt.Errorf("WebPort is required")
	}
	if c.WebJwtSecret == "" {
		return fmt.Errorf("WebJwtSecret is required")
	}
	if c.WebHashSalt == "" {
		return fmt.Errorf("WebHashSalt is required")
	}
	if c.Logger == nil {
		return fmt.Errorf("logger is required")
	}
	if c.NatsConn == nil {
		return fmt.Errorf("NatsConn is required")
	}
	if c.ServiceTimeout <= 0 {
		c.ServiceTimeout = 30 * time.Second
	}
	return nil
}
