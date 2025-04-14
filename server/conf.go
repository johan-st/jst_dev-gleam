package main

import "jst_dev/server/talk"

// TODO: think this through.. atm all we need is an app name
type GlobalConfig struct {
	Talk talk.Conf
}

func loadConf() (*GlobalConfig, error) {

	conf := &GlobalConfig{
		Talk: talk.Conf{
			ServerName:        "jst",
			EnableLogging:     true,
			ListenOnLocalhost: true,
		},
	}

	return conf, nil
}
