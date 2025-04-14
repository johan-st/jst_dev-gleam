package talk

import (
	"fmt"
	"jst_dev/server/jst_log"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/micro"
)

func MessagingHandler(nc *nats.Conn) {
	nc.Subscribe("health", func(m *nats.Msg) {
		err := m.Respond([]byte("OK"))
		if err != nil {
			fmt.Println("failed to respond")
		}
	})
}

// SETUP

type Conf struct {
	ServerName        string
	EnableLogging     bool
	ListenOnLocalhost bool
}

type Talk struct {
	Conn    *nats.Conn
	Service micro.Service
	ns      *server.Server
	l       *jst_log.Logger
	conf    Conf
}

func New(conf Conf, l *jst_log.Logger) (*Talk, error) {
	if l == nil {
		return nil, fmt.Errorf("logger not initialized")
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

	return &Talk{Conn: nil, Service: nil, ns: ns, l: l}, nil
}

func (t *Talk) Start() error {
	if t.ns == nil {
		return fmt.Errorf("NATS server not initialized")
	}

	// start and wait for server to be ready for connections
	go t.ns.Start()
	if !t.ns.ReadyForConnections(250 * time.Millisecond) {
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

	// Initialize micro service
	service, err := micro.AddService(nc, micro.Config{
		Name:        "jst",
		Version:     "1.0.0",
		Description: "server for jst.dev and related services",
	})
	if err != nil {
		return fmt.Errorf("add micro service: %w", err)
	}
	t.Service = service

	return nil
}

func (t *Talk) Shutdown() {
	t.ns.Shutdown()
}

func (t *Talk) WaitForShutdown() {
	t.ns.WaitForShutdown()
}

// func (t *Talk) Drain() error {
// 	err := t.Conn.Drain()
// 	if err != nil {
// 		return fmt.Errorf("drain: %w", err)
// 	}
// 	return nil
// }

// func GlobalNats(conf confNatsGlobal) (*nats.Conn, error) {
// 	nc, err := nats.Connect(conf.Url, nats.UserCredentials(conf.Creds))
// 	if err != nil {
// 		return nil, fmt.Errorf("connect to NATS: %w", err)
// 	}
// 	return nc, nil
// }
