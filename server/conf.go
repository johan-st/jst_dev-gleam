package main

import "jst_dev/server/talk"

// TODO: think this through.. atm all we need is an app name
type GlobalConfig struct {
	Talk talk.Conf
}

// loadConf returns a GlobalConfig instance with default settings for the talk component.
func loadConf() (*GlobalConfig, error) {
	conf := &GlobalConfig{
		Talk: talk.Conf{
			ServerName:        "jst",
			EnableLogging:     false,
			ListenOnLocalhost: true,
		},
	}

	return conf, nil
}
