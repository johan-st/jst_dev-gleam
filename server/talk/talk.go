package talk

import (
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
	Conn *nats.Conn
	// Service micro.Service
	ns   *server.Server
	l    *jst_log.Logger
	conf Conf
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

	return &Talk{Conn: nil, ns: ns, l: l}, nil
}

func (t *Talk) Start() error {
	if t.ns == nil {
		return fmt.Errorf("NATS server not initialized")
	}

	// start and wait for server to be ready for connections
	go t.ns.Start()
	if !t.ns.ReadyForConnections(4 * time.Second) {
		return fmt.Errorf("NATS server failed to start")
	}

	// Client options
	clientOpts := []nats.Option{}
	if !t.conf.ListenOnLocalhost {
		clientOpts = append(clientOpts, nats.InProcessServer(t.ns))
	}

	// Connect to server
	nc, err := nats.Connect(t.ns.ClientURL(), clientOpts...)
	if err != nil {
		return fmt.Errorf("connect to NATS: %w", err)
	}
	t.Conn = nc

	// setup subscriptions
	err = t.subscriptions()
	if err != nil {
		return fmt.Errorf("subscriptions: %w", err)
	}

	return nil
}

func (t *Talk) Shutdown() {
	t.ns.Shutdown()
}

func (t *Talk) WaitForShutdown() {
	t.ns.WaitForShutdown()
}

func (t *Talk) Drain() error {
	err := t.Conn.Drain()
	if err != nil {
		return fmt.Errorf("drain: %w", err)
	}
	return nil
}

func (t *Talk) subscriptions() error {
	l := t.l.WithBreadcrumb("subscriptions")

	_, err := t.Conn.Subscribe("ping", func(m *nats.Msg) {
		err := m.Respond([]byte("pong"))
		if err != nil {
			l.Error("failed to respond", "error", err)
		}
	})
	if err != nil {
		return fmt.Errorf("failed to subscribe")
	}

	_, err = t.Conn.Subscribe("stats", func(m *nats.Msg) {
		l.Info("stats")
		stats := t.Conn.Stats()
		err := m.Respond(fmt.Appendf(nil,
			"------------------\nMSGS\nin: %d\nout: %d\n\nBYTES\nin: %d\nout: %d\n\nCONN\nreconnects: %d\n------------------",
			stats.InMsgs,
			stats.OutMsgs,
			stats.InBytes,
			stats.OutBytes,
			stats.Reconnects,
		))
		if err != nil {
			fmt.Printf("failed to respond: %s\n", err)
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
