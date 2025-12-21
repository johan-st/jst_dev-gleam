package talk

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"

	"jst_dev/server/jst_log"
)

type Conf struct {
	ServerName        string
	EnableLogging     bool
	ListenOnLocalhost bool

	// Fat node clustering configuration
	FatNode        bool     // Enable fat node mode with clustering
	TailscaleIP    string   // Tailscale IP for this node (100.x.x.x)
	ClusterName    string   // NATS cluster name
	ClusterPeers   []string // Other node addresses (ip:port)
	ClientPort     int      // NATS client port (default 4222)
	ClusterPort    int      // NATS cluster port (default 6222)
	JetStreamStore string   // Path for JetStream storage
}

// checkReachablePeers tests which peers are reachable and returns only the reachable ones
// This allows fat nodes to start in standalone mode when no peers are available
func checkReachablePeers(peers []string, l *jst_log.Logger) []string {
	if len(peers) == 0 {
		return nil
	}

	var reachable []string
	for _, peer := range peers {
		// Try to connect with a short timeout
		conn, err := net.DialTimeout("tcp", peer, 2*time.Second)
		if err != nil {
			l.Debug("peer %s not reachable: %v", peer, err)
			continue
		}
		conn.Close()
		l.Info("peer %s is reachable", peer)
		reachable = append(reachable, peer)
	}
	return reachable
}

// EmbeddedServer starts an embedded NATS server with JetStream enabled and returns a client connection.
// The server is configured according to the provided Conf struct and is automatically shut down when the context is canceled.
// In fat node mode, configures clustering to connect to peer nodes.
// Returns a connected NATS client or an error if initialization, startup, or subscription setup fails.
func EmbeddedServer(
	ctx context.Context,
	conf Conf,
	l *jst_log.Logger,
) (*nats.Conn, *server.Server, error) {
	var (
		err        error
		serverOpts *server.Options
		clientOpts []nats.Option
		ns         *server.Server
		nc         *nats.Conn
	)
	if l == nil {
		return nil, nil, fmt.Errorf("logger can not be nil")
	}

	// Determine ports
	clientPort := conf.ClientPort
	if clientPort == 0 {
		clientPort = 4222
	}
	clusterPort := conf.ClusterPort
	if clusterPort == 0 {
		clusterPort = 6222
	}

	// Determine store directory
	storeDir := conf.JetStreamStore
	if storeDir == "" {
		storeDir = "./data"
	}

	// Determine host to bind to
	host := "127.0.0.1"
	if conf.FatNode && conf.TailscaleIP != "" {
		host = conf.TailscaleIP
	}

	// Server options
	serverOpts = &server.Options{
		ServerName: conf.ServerName,
		Host:       host,
		Port:       clientPort,

		// Debugging
		NoLog:  !conf.EnableLogging,
		NoSigs: true,

		// JetStream
		JetStreamDomain: "jet",
		JetStream:       true,
		StoreDir:        storeDir,
	}

	// Fat node clustering configuration
	if conf.FatNode {
		l.Info("configuring fat node on %s", host)

		if len(conf.ClusterPeers) > 0 {
			// Configure clustering - NATS will handle connection attempts to peers
			l.Info("configuring cluster mode with %d peers", len(conf.ClusterPeers))

			// Cluster name
			clusterName := conf.ClusterName
			if clusterName == "" {
				clusterName = "jst-cluster"
			}

			serverOpts.Cluster = server.ClusterOpts{
				Name: clusterName,
				Host: host,
				Port: clusterPort,
			}

			// Configure routes to peer nodes
			// NATS will keep retrying connections until peers are available
			routes := make([]*url.URL, 0, len(conf.ClusterPeers))
			for _, peer := range conf.ClusterPeers {
				routeURL, err := url.Parse("nats://" + peer)
				if err != nil {
					l.Warn("invalid cluster peer URL %s: %v", peer, err)
					continue
				}
				routes = append(routes, routeURL)
				l.Info("adding cluster route: %s", routeURL.String())
			}
			serverOpts.Routes = routes
		} else {
			l.Info("running as standalone fat node (no cluster peers configured)")
		}

		// Listen on network (not just localhost)
		serverOpts.DontListen = false
	} else {
		// Local mode - in-process only or localhost
		serverOpts.DontListen = !conf.ListenOnLocalhost
	}

	ns, err = server.NewServer(serverOpts)
	if err != nil {
		return nil, nil, fmt.Errorf("new NATS server: %w", err)
	}

	// Configure NATS server logging
	if conf.EnableLogging {
		ns.ConfigureLogger()
	}

	if ctx == nil {
		return nil, nil, fmt.Errorf("context is nil")
	}

	l.Info("starting NATS server on %s:%d...", host, clientPort)
	go ns.Start()

	// Fat nodes may take longer to start due to cluster discovery
	readyTimeout := 5 * time.Second
	if conf.FatNode {
		readyTimeout = 10 * time.Second
	}

	l.Info("waiting for NATS server to be ready (timeout: %v)...", readyTimeout)
	if !ns.ReadyForConnections(readyTimeout) {
		return nil, nil, fmt.Errorf("NATS server failed to be ready for connections (timeout: %v)", readyTimeout)
	}

	l.Info("NATS server ready, client URL: %s", ns.ClientURL())
	if conf.FatNode && len(conf.ClusterPeers) > 0 {
		l.Info("cluster URL: nats://%s:%d", host, clusterPort)
	}

	// Client options
	clientOpts = []nats.Option{
		nats.Name(conf.ServerName + "-internal"),
		nats.MaxReconnects(-1),
		nats.ReconnectWait(time.Second),
	}

	// In non-fat-node mode without localhost listening, use in-process
	if !conf.FatNode && !conf.ListenOnLocalhost {
		clientOpts = append(clientOpts, nats.InProcessServer(ns))
	}

	// Connect to server
	nc, err = nats.Connect(ns.ClientURL(), clientOpts...)
	if err != nil {
		return nil, nil, fmt.Errorf("connect to NATS: %w", err)
	}

	// In fat node mode, wait for JetStream to be fully operational
	// by testing a simple JetStream operation
	clusterModeEnabled := serverOpts.Cluster.Name != ""
	if conf.FatNode {
		l.Info("waiting for JetStream to be ready...")
		js, err := nc.JetStream()
		if err != nil {
			return nil, nil, fmt.Errorf("get jetstream context: %w", err)
		}

		// Try to get account info, which requires meta leader to be elected in cluster mode
		// In standalone mode, this should succeed immediately
		waitSeconds := 10
		if clusterModeEnabled {
			waitSeconds = 120 // Cluster mode needs more time for routing + leader election
			l.Info("cluster mode enabled - waiting up to %d seconds for meta leader election...", waitSeconds)
		}

		for i := 0; i < waitSeconds; i++ {
			_, err = js.AccountInfo()
			if err == nil {
				l.Info("JetStream ready")
				break
			}
			if i == waitSeconds-1 {
				l.Warn("JetStream not fully ready after %d seconds, continuing anyway: %v", waitSeconds, err)
			}
			if i > 0 && i%10 == 0 {
				l.Info("still waiting for JetStream... (%d/%d seconds)", i, waitSeconds)
			}
			time.Sleep(time.Second)
		}
	}

	err = subscriptions(nc, l)
	if err != nil {
		return nil, nil, fmt.Errorf("subscriptions: %w", err)
	}

	return nc, ns, nil
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
