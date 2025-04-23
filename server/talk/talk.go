package talk

import (
	"context"
	"fmt"
	"jst_dev/server/jst_log"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
)

// SETUP

type Conf struct {
	ServerName        string
	EnableLogging     bool
	ListenOnLocalhost bool
}

type Talk struct {
	nc   *nats.Conn
	ns   *server.Server
	l    *jst_log.Logger
	conf Conf
	ctx  context.Context
}

func New(conf Conf, l *jst_log.Logger) (*Talk, error) {
	if l == nil {
		return nil, fmt.Errorf("logger is nil")
	}

	opts := &server.Options{
		ServerName: conf.ServerName,
		// Debugging
		NoLog:      !conf.EnableLogging,
		DontListen: !conf.ListenOnLocalhost,

		// JetStream
		JetStreamDomain: "jet",
		JetStream:       true,
		StoreDir:        "./data",
	}

	ns, err := server.NewServer(opts)
	if err != nil {
		return nil, fmt.Errorf("new NATS server: %w", err)
	}
	if conf.EnableLogging {
		ns.ConfigureLogger()
	}

	return &Talk{nc: nil, ns: ns, l: l}, nil
}

func (t *Talk) Start(ctx context.Context) (*nats.Conn, error) {
	var (
		err        error
		nc         *nats.Conn
		clientOpts []nats.Option
	)

	if t == nil {
		return nil, fmt.Errorf("talk is nil")
	}
	if ctx == nil {
		return nil, fmt.Errorf("context is nil")
	}
	if t.ns == nil {
		return nil, fmt.Errorf("NATS server not initialized")
	}
	t.ctx = ctx

	// start and wait for server to be ready for connections
	go t.ns.Start()
	if !t.ns.ReadyForConnections(4 * time.Second) {
		return nil, fmt.Errorf("NATS server failed to start")
	}

	// Client options
	clientOpts = []nats.Option{}
	if !t.conf.ListenOnLocalhost {
		clientOpts = append(clientOpts, nats.InProcessServer(t.ns))
	}

	// Connect to server
	nc, err = nats.Connect(t.ns.ClientURL(), clientOpts...)
	if err != nil {
		return nil, fmt.Errorf("connect to NATS: %w", err)
	}
	t.nc = nc
	// setup subscriptions
	err = t.subscriptions()
	if err != nil {
		return nil, fmt.Errorf("subscriptions: %w", err)
	}

	return nc, nil
}

func (t *Talk) Shutdown() {
	t.ns.Shutdown()
}

func (t *Talk) WaitForShutdown() {
	t.ns.WaitForShutdown()
}

func (t *Talk) subscriptions() error {
	var (
		err   error
		stats nats.Statistics
		msg   []byte
		l     = t.l.WithBreadcrumb("sub		scriptions")
	)

	_, err = t.nc.Subscribe("ping", func(m *nats.Msg) {
		if err := m.Respond([]byte("pong")); err != nil {
			l.Error("failed to respond", "error", err)
		}
	})
	if err != nil {
		return fmt.Errorf("failed to subscribe")
	}

	_, err = t.nc.Subscribe("stats", func(m *nats.Msg) {
		l.Info("stats")
		stats = t.nc.Stats()
		msg = fmt.Appendf(nil,
			"------------------\nMSGS\nin: %d\nout: %d\n\nBYTES\nin: %d\nout: %d\n\nCONN\nreconnects: %d\n------------------",
			stats.InMsgs,
			stats.OutMsgs,
			stats.InBytes,
			stats.OutBytes,
			stats.Reconnects,
		)
		err = m.Respond(msg)
		if err != nil {
			l.Error("failed to respond", "error", err)
		}
	})
	if err != nil {
		return fmt.Errorf("failed to subscribe")
	}

	return nil
}

// func GlobalNats(conf confNatsGlobal) (*nats.Conn, error) {
// 	nc, err := nats.Connect(conf.Url, nats.UserCredentials(conf.Creds))
// 	if err != nil {
// 		return nil, fmt.Errorf("connect to NATS: %w", err)
// 	}
// 	return nc, nil
// }
