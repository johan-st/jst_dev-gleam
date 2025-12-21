package main

import (
	"flag"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"jst_dev/server/talk"
)

type GlobalConfig struct {
	NatsJWT      string
	NatsNKEY     string
	WebJwtSecret string
	WebHashSalt  string
	WebPort      string
	NtfyToken    string

	AppName       string
	Region        string
	PrimaryRegion string

	Talk  talk.Conf
	Flags Flags
}

type Flags struct {
	NatsEmbedded  bool
	FatNode       bool // New: fat node mode with clustering
	DebugMode     bool
	ProxyFrontend bool
	LogLevel      string
	SlowSocket    time.Duration
}

// detectTailscaleIP attempts to find the Tailscale IP (100.x.x.x range)
func detectTailscaleIP() string {
	// First check environment variable
	if ip := os.Getenv("TAILSCALE_IP"); ip != "" {
		return ip
	}

	// Try to detect from network interfaces
	interfaces, err := net.Interfaces()
	if err != nil {
		return ""
	}

	for _, iface := range interfaces {
		// Tailscale interfaces are usually named "tailscale0" or similar
		if !strings.Contains(iface.Name, "tailscale") && iface.Name != "utun" {
			// On some systems, check all interfaces for 100.x.x.x
		}

		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}

			// Check for Tailscale CGNAT range (100.64.0.0/10)
			if ip != nil && ip.To4() != nil {
				if ip[0] == 100 && ip[1] >= 64 && ip[1] <= 127 {
					return ip.String()
				}
			}
		}
	}

	return ""
}

// parseClusterPeers parses comma-separated peer addresses
func parseClusterPeers(peersStr string) []string {
	if peersStr == "" {
		return nil
	}
	peers := strings.Split(peersStr, ",")
	var result []string
	for _, p := range peers {
		p = strings.TrimSpace(p)
		if p != "" {
			// Add default cluster port if not specified
			if !strings.Contains(p, ":") {
				p = p + ":6222"
			}
			result = append(result, p)
		}
	}
	return result
}

// loadConf returns a GlobalConfig instance with default settings for the talk component.
func loadConf(getenv func(string) string) (*GlobalConfig, error) {
	var (
		natsEmbedded  bool
		fatNode       bool
		proxyFrontend bool
		debugMode     bool
		logLevel      string
		slowSocket    time.Duration
	)
	flag.BoolVar(&natsEmbedded, "local", false, "run an embedded nats server (single node, no clustering)")
	flag.BoolVar(&fatNode, "fat-node", false, "run as fat node with embedded NATS clustering")
	flag.BoolVar(&proxyFrontend, "proxy", false, "proxy frontend to dev server")
	flag.StringVar(&logLevel, "log", "info", "set log level (debug, info, warn, error, fatal)")
	flag.DurationVar(&slowSocket, "slow", 0, "add sleep delay to socket sends (e.g., 100ms, 1s)")
	flag.BoolVar(&debugMode, "debug", false, "enable debug mode")
	flag.Parse()

	// Fat node mode implies embedded NATS
	if fatNode {
		natsEmbedded = true
	}

	// In fat node or local mode, NGS credentials are optional
	envNatsJwt := getenv("NATS_JWT")
	envNatsNkey := getenv("NATS_NKEY")
	if !natsEmbedded {
		if envNatsJwt == "" {
			log.Fatalf("missing env-var: NATS_JWT (required for NGS mode)")
		}
		if envNatsNkey == "" {
			log.Fatalf("missing env-var: NATS_NKEY (required for NGS mode)")
		}
	}

	envJwtSecret := getenv("JWT_SECRET")
	if envJwtSecret == "" {
		log.Fatalf("missing env-var: JWT_SECRET")
	}

	envHashSalt := getenv("WEB_HASH_SALT")
	if envHashSalt == "" {
		log.Fatalf("missing env-var: WEB_HASH_SALT")
	}

	envPort := getenv("PORT")
	if envPort == "" {
		envPort = "8080" // Default port
	}

	// App identity - use defaults for local/fat-node mode
	appName := getenv("FLY_APP_NAME")
	if appName == "" {
		if natsEmbedded {
			appName = "jst-local"
		} else {
			log.Fatalf("missing env-var: FLY_APP_NAME")
		}
	}

	region := getenv("FLY_REGION")
	if region == "" {
		if natsEmbedded {
			region = "local"
		} else {
			log.Fatalf("missing env-var: FLY_REGION")
		}
	}

	primaryRegion := getenv("PRIMARY_REGION")
	if primaryRegion == "" {
		if natsEmbedded {
			primaryRegion = "local"
		} else {
			log.Fatalf("missing env-var: PRIMARY_REGION")
		}
	}

	// Fat node configuration
	nodeName := getenv("NODE_NAME")
	if nodeName == "" {
		hostname, _ := os.Hostname()
		if hostname != "" {
			nodeName = hostname
		} else {
			nodeName = "jst-node"
		}
	}

	// Detect Tailscale IP for fat node clustering
	tailscaleIP := ""
	if fatNode {
		tailscaleIP = detectTailscaleIP()
		// If no Tailscale IP found, use localhost for single-node fat mode
		if tailscaleIP == "" {
			tailscaleIP = "127.0.0.1"
		}
	}

	// Parse cluster peers from environment
	clusterPeers := parseClusterPeers(getenv("CLUSTER_PEERS"))

	// JetStream configuration
	jetStreamStore := getenv("JETSTREAM_STORE")
	if jetStreamStore == "" {
		jetStreamStore = "./data/jetstream"
	}

	// Cluster configuration
	clusterName := getenv("NATS_CLUSTER_NAME")
	if clusterName == "" {
		clusterName = "jst-cluster"
	}

	// NATS ports (allow override for multi-node testing on same machine)
	clientPort := 4222
	if p := getenv("NATS_CLIENT_PORT"); p != "" {
		if n, err := strconv.Atoi(p); err == nil {
			clientPort = n
		}
	}

	clusterPort := 6222
	if p := getenv("NATS_CLUSTER_PORT"); p != "" {
		if n, err := strconv.Atoi(p); err == nil {
			clusterPort = n
		}
	}

	conf := &GlobalConfig{
		NatsJWT:      envNatsJwt,
		NatsNKEY:     envNatsNkey,
		WebJwtSecret: envJwtSecret,
		WebHashSalt:  envHashSalt,
		WebPort:      envPort,
		NtfyToken:    getenv("NTFY_TOKEN"),

		AppName:       appName,
		Region:        region,
		PrimaryRegion: primaryRegion,
		Talk: talk.Conf{
			ServerName:        nodeName,
			EnableLogging:     debugMode,
			ListenOnLocalhost: !fatNode, // Fat nodes listen on Tailscale IP

			// Fat node clustering config
			FatNode:        fatNode,
			TailscaleIP:    tailscaleIP,
			ClusterName:    clusterName,
			ClusterPeers:   clusterPeers,
			ClientPort:     clientPort,
			ClusterPort:    clusterPort,
			JetStreamStore: jetStreamStore,
		},
		Flags: Flags{
			NatsEmbedded:  natsEmbedded,
			FatNode:       fatNode,
			ProxyFrontend: proxyFrontend,
			LogLevel:      logLevel,
			SlowSocket:    slowSocket,
			DebugMode:     debugMode,
		},
	}

	return conf, nil
}
