package serviceApi

import (
	"context"
	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
)

type ServiceConf struct {
	Logger   *jst_log.Logger // nil = disabled
	NatsConn *nats.Conn      // nil = error
	// internal fields
}

type Service interface {
	New(*ServiceConf) (*Service, error)
	Run(*context.Context) error
}
