package main

import (
	"flag"
	"jst_dev/server/talk"
	"log"
	"os"

	"github.com/joho/godotenv"
)

// TODO: think this through.. atm all we need is an app name
type GlobalConfig struct {
	NatsJWT      string
	NatsNKEY     string
	WebJwtSecret string
	WebHashSalt  string
	WebPort      string

	AppName string
	Talk    talk.Conf
	Flags   Flags
}
type Flags struct {
	NatsEmbedded  bool
	ProxyFrontend bool
}

// loadConf returns a GlobalConfig instance with default settings for the talk component.
func loadConf() (*GlobalConfig, error) {
	var (
		natsEmbedded, proxyFrontend bool
	)
	flag.BoolVar(&natsEmbedded, "local", false, "run an embedded nats server")
	flag.BoolVar(&proxyFrontend, "proxy", false, "proxy frontend to dev server")
	flag.Parse()

	_ = godotenv.Load()

	envNatsJwt := os.Getenv("NATS_JWT")
	if envNatsJwt == "" {
		log.Fatalf("missing env-var: NATS_JWT")
	}

	envNatsNkey := os.Getenv("NATS_NKEY")
	if envNatsNkey == "" {
		log.Fatalf("missing env-var: NKEY")
	}

	envJwtSecret := os.Getenv("JWT_SECRET")
	if envJwtSecret == "" {
		log.Fatalf("missing env-var: JWT_SECRET")
	}

	envHashSalt := os.Getenv("WEB_HASH_SALT")
	if envHashSalt == "" {
		log.Fatalf("missing env-var: WEB_HASH_SALT")
	}

	envPort := os.Getenv("PORT")
	if envPort == "" {
		log.Fatalf("missing env-var: PORT")
	}
	conf := &GlobalConfig{
		NatsJWT:      envNatsJwt,
		NatsNKEY:     envNatsNkey,
		WebJwtSecret: envJwtSecret,
		WebHashSalt:  envHashSalt,
		WebPort:      envPort,

		AppName: os.Getenv("FLY_APP_NAME") + "-" + os.Getenv("PRIMARY_REGION"),
		Talk: talk.Conf{
			ServerName:        "jst",
			EnableLogging:     false,
			ListenOnLocalhost: true,
		},
		Flags: Flags{
			NatsEmbedded:  natsEmbedded,
			ProxyFrontend: proxyFrontend,
		},
	}

	return conf, nil
}
