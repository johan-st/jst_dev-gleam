package main

import (
	"flag"
	"log"
	"time"

	"jst_dev/server/talk"
)

// TODO: think this through.. atm all we need is an app name
type GlobalConfig struct {
	NatsJWT      string
	NatsNKEY     string
	WebJwtSecret string
	WebHashSalt  string
	WebPort      string
	NtfyToken    string

	AppName       string
	Region        string
	PrimaryRegion string

	Talk  talk.Conf
	Flags Flags
}

type Flags struct {
	NatsEmbedded  bool
	ProxyFrontend bool
	LogLevel      string
	SlowSocket    time.Duration
}

// loadConf returns a GlobalConfig instance with default settings for the talk component.
func loadConf(getenv func(string) string) (*GlobalConfig, error) {
	var (
		natsEmbedded, proxyFrontend bool
		logLevel                    string
		slowSocket                  time.Duration
	)
	flag.BoolVar(&natsEmbedded, "local", false, "run an embedded nats server")
	flag.BoolVar(&proxyFrontend, "proxy", false, "proxy frontend to dev server")
	flag.StringVar(&logLevel, "log", "info", "set log level (debug, info, warn, error, fatal)")
	flag.DurationVar(&slowSocket, "slow", 0, "add sleep delay to socket sends (e.g., 100ms, 1s)")
	flag.Parse()

	envNatsJwt := getenv("NATS_JWT")
	if envNatsJwt == "" {
		log.Fatalf("missing env-var: NATS_JWT")
	}

	envNatsNkey := getenv("NATS_NKEY")
	if envNatsNkey == "" {
		log.Fatalf("missing env-var: NKEY")
	}

	envJwtSecret := getenv("JWT_SECRET")
	if envJwtSecret == "" {
		log.Fatalf("missing env-var: JWT_SECRET")
	}

	envHashSalt := getenv("WEB_HASH_SALT")
	if envHashSalt == "" {
		log.Fatalf("missing env-var: WEB_HASH_SALT")
	}

	envPort := getenv("PORT")
	if envPort == "" {
		log.Fatalf("missing env-var: PORT")
	}

	// NTFY_TOKEN is optional
	envNtfyToken := getenv("NTFY_TOKEN")
	if envNtfyToken == "" {
		log.Fatalf("missing env-var: NTFY_TOKEN")
	}

	conf := &GlobalConfig{
		NatsJWT:      envNatsJwt,
		NatsNKEY:     envNatsNkey,
		WebJwtSecret: envJwtSecret,
		WebHashSalt:  envHashSalt,
		WebPort:      envPort,
		NtfyToken:    envNtfyToken,

		AppName:       getenv("FLY_APP_NAME"),
		Region:        getenv("FLY_REGION"),
		PrimaryRegion: getenv("PRIMARY_REGION"),
		Talk: talk.Conf{
			ServerName:        "jst",
			EnableLogging:     false,
			ListenOnLocalhost: true,
		},
		Flags: Flags{
			NatsEmbedded:  natsEmbedded,
			ProxyFrontend: proxyFrontend,
			LogLevel:      logLevel,
			SlowSocket:    slowSocket,
		},
	}

	return conf, nil
}
