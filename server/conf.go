package main

import (
	"flag"
	"jst_dev/server/talk"
	"os"
)

// TODO: think this through.. atm all we need is an app name
type GlobalConfig struct {
	Flags    Flags
	NatsJWT  string
	NatsSeed string
	Talk     talk.Conf
}
type Flags struct {
	natsEmbedded bool
}

// loadConf returns a GlobalConfig instance with default settings for the talk component.
func loadConf() (*GlobalConfig, error) {
	var natsEmbedded bool
	flag.BoolVar(&natsEmbedded, "local", false, "run an embedded nats server")
	flag.Parse()

	conf := &GlobalConfig{
		NatsJWT:  os.Getenv("NATS_JWT"),
		NatsSeed: os.Getenv("NATS_SEED"),
		Talk: talk.Conf{
			ServerName:        "jst",
			EnableLogging:     false,
			ListenOnLocalhost: true,
		},
		Flags: Flags{natsEmbedded: natsEmbedded},
	}

	return conf, nil
}
