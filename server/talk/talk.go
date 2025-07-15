package talk

import (
	"context"
	"fmt"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"

	"jst_dev/server/jst_log"
)

type Conf struct {
	ServerName        string
	EnableLogging     bool
	ListenOnLocalhost bool
}

// EmbeddedServer starts an embedded NATS server with JetStream enabled and returns a client connection.
// The server is configured according to the provided Conf struct and is automatically shut down when the context is canceled.
// Returns a connected NATS client or an error if initialization, startup, or subscription setup fails.
func EmbeddedServer(
	ctx context.Context,
	conf Conf,
	l *jst_log.Logger,
) (*nats.Conn, error) {
	var (
		err        error
		serverOpts *server.Options
		clientOpts []nats.Option
		ns         *server.Server
		nc         *nats.Conn
	)
	if l == nil {
		return nil, fmt.Errorf("logger can not be nil")
	}

	// Server
	serverOpts = &server.Options{
		ServerName: conf.ServerName,
		// Debugging
		NoLog:      !conf.EnableLogging,
		DontListen: !conf.ListenOnLocalhost,

		// JetStream
		JetStreamDomain: "jet",
		JetStream:       true,
		StoreDir:        "./data",
	}
	ns, err = server.NewServer(serverOpts)
	if err != nil {
		return nil, fmt.Errorf("new NATS server: %w", err)
	}
	if conf.EnableLogging {
		ns.ConfigureLogger()
	}
	if ctx == nil {
		return nil, fmt.Errorf("context is nil")
	}

	go ns.Start()
	if !ns.ReadyForConnections(4 * time.Second) {
		ns.Shutdown()
		return nil, fmt.Errorf("NATS server failed to start")
	}

	// Client options
	clientOpts = []nats.Option{}
	if !conf.ListenOnLocalhost {
		clientOpts = append(clientOpts, nats.InProcessServer(ns))
	}

	// Connect to server
	nc, err = nats.Connect(ns.ClientURL(), clientOpts...)
	if err != nil {
		return nil, fmt.Errorf("connect to NATS: %w", err)
	}

	go func() {
		<-ctx.Done()
		ns.Shutdown()
	}()

	err = subscriptions(nc, l)
	if err != nil {
		return nil, fmt.Errorf("subscriptions: %w", err)
	}

	return nc, nil
}

// subscriptions registers NATS message handlers for "ping" and "stats" subjects on the provided connection.
// The "ping" handler responds with "pong", and the "stats" handler responds with formatted connection statistics.
// Returns an error if subscription setup fails.
func subscriptions(nc *nats.Conn, l *jst_log.Logger) error {
	var (
		err   error
		stats nats.Statistics
		msg   []byte
	)

	_, err = nc.Subscribe("ping", func(m *nats.Msg) {
		if err := m.Respond([]byte("pong")); err != nil {
			l.Error("failed to respond", "error", err)
		}
	})
	if err != nil {
		return fmt.Errorf("failed to subscribe")
	}

	_, err = nc.Subscribe("stats", func(m *nats.Msg) {
		l.Info("stats")
		stats = nc.Stats()
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
