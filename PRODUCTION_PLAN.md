# Production and Testing Plan

> A comprehensive plan to productionize and test the jst_dev fat nodes architecture.

## Table of Contents

1. [Current State Assessment](#current-state-assessment)
2. [Testing Strategy](#testing-strategy)
3. [Production Readiness Checklist](#production-readiness-checklist)
4. [Deployment Scenarios](#deployment-scenarios)
5. [Monitoring and Observability](#monitoring-and-observability)
6. [Security Hardening](#security-hardening)
7. [Disaster Recovery](#disaster-recovery)
8. [Implementation Timeline](#implementation-timeline)

---

## Current State Assessment

### What's Implemented

| Component | Status | Notes |
|-----------|--------|-------|
| Embedded NATS server | Done | `-local` and `-fat-node` flags |
| JetStream persistence | Done | File-based storage |
| Cluster configuration | Done | `CLUSTER_PEERS` env var |
| Tailscale IP detection | Done | Auto-detect 100.x.x.x |
| Health check endpoints | Done | `/health/live`, `/health/ready`, `/health/cluster` |
| JetStream retry logic | Done | 60s retry window for cluster startup |
| HTTP API + WebSocket | Done | Production-ready |
| All services (who, urlShort, articles, convo, ntfy) | Done | Using KV retry logic |

### What Needs Work

| Component | Priority | Effort |
|-----------|----------|--------|
| Comprehensive test suite | High | Medium |
| Multi-node integration tests | High | High |
| JetStream replication (R=N) | Medium | Low |
| Structured logging | Medium | Low |
| Metrics/tracing | Medium | Medium |
| ARM64 builds | Low | Low |
| Rate limiting | Medium | Low |
| Graceful shutdown improvements | Low | Low |

---

## Testing Strategy

### 1. Unit Tests

**Location:** `server/*_test.go`

#### Required Test Coverage

```bash
# Target: 70%+ coverage for core packages
server/core/         # Repository, service interfaces, JetStream helpers
server/who/          # User management, auth, permissions
server/urlShort/     # URL shortener logic
server/articles/     # Article CRUD
server/convo/        # Chat rooms and messages
server/talk/         # NATS server configuration
```

#### Priority Tests to Add

| Package | Test | Description |
|---------|------|-------------|
| `core` | `TestCreateKeyValueWithRetry` | Verify retry logic works |
| `core` | `TestCreateStreamWithRetry` | Verify stream retry logic |
| `who` | `TestUserCreateDuplicate` | Duplicate email/username handling |
| `who` | `TestJWTExpiration` | Token expiry behavior |
| `urlShort` | `TestShortCodeCollision` | Handle code collisions |
| `talk` | `TestEmbeddedServerStartup` | Verify server starts correctly |
| `talk` | `TestClusterConfiguration` | Verify cluster opts applied |

#### Example Test Implementation

```go
// server/core/jetstream_test.go
func TestCreateKeyValueWithRetry_Success(t *testing.T) {
    // Start embedded NATS server
    ns, nc := startTestNATS(t)
    defer ns.Shutdown()
    defer nc.Close()

    ctx := context.Background()
    cfg := jetstream.KeyValueConfig{
        Bucket: "test-bucket",
    }

    kv, err := CreateKeyValueWithRetry(ctx, nc, cfg, 3, 100*time.Millisecond)
    require.NoError(t, err)
    require.NotNil(t, kv)
}

func TestCreateKeyValueWithRetry_ContextCancelled(t *testing.T) {
    ns, nc := startTestNATS(t)
    defer ns.Shutdown()
    defer nc.Close()

    ctx, cancel := context.WithCancel(context.Background())
    cancel() // Cancel immediately

    cfg := jetstream.KeyValueConfig{
        Bucket: "test-bucket",
    }

    _, err := CreateKeyValueWithRetry(ctx, nc, cfg, 10, 1*time.Second)
    require.Error(t, err)
    require.Contains(t, err.Error(), "context cancelled")
}
```

### 2. Integration Tests

**Location:** `server/integration_test/`

#### Test Scenarios

##### Scenario 1: Single Fat Node

```bash
# Test: Start single fat node, verify all services work
make test-fat-node-single
```

```go
// server/integration_test/single_node_test.go
func TestSingleFatNode(t *testing.T) {
    if testing.Short() {
        t.Skip("skipping integration test in short mode")
    }

    // Start fat node
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()

    go runFatNode(ctx, "node1", 8081, 4222, 6222, nil)
    waitForHealth(t, "http://localhost:8081/health/ready", 30*time.Second)

    // Test API endpoints
    t.Run("CreateUser", testCreateUser)
    t.Run("CreateShortURL", testCreateShortURL)
    t.Run("CreateArticle", testCreateArticle)
    t.Run("WebSocketSync", testWebSocketSync)
}
```

##### Scenario 2: Two-Node Cluster

```bash
# Test: Start 2 nodes, verify clustering and replication
make test-fat-node-cluster-2
```

```go
// server/integration_test/two_node_cluster_test.go
func TestTwoNodeCluster(t *testing.T) {
    if testing.Short() {
        t.Skip("skipping integration test in short mode")
    }

    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()

    // Start node 1
    go runFatNode(ctx, "node1", 8081, 4222, 6222, nil)
    
    // Start node 2 with node 1 as peer
    go runFatNode(ctx, "node2", 8082, 4223, 6223, []string{"127.0.0.1:6222"})

    // Wait for both nodes
    waitForHealth(t, "http://localhost:8081/health/cluster", 60*time.Second)
    waitForHealth(t, "http://localhost:8082/health/cluster", 60*time.Second)

    // Verify cluster formed
    t.Run("ClusterFormed", func(t *testing.T) {
        info := getClusterInfo(t, "http://localhost:8081/health/cluster")
        require.GreaterOrEqual(t, info.ConnectedRoutes, 1)
    })

    // Test cross-node data sync
    t.Run("CrossNodeSync", func(t *testing.T) {
        // Create user on node 1
        user := createUser(t, "http://localhost:8081", "test@example.com")
        
        // Wait for replication
        time.Sleep(2 * time.Second)
        
        // Verify user exists on node 2
        fetched := getUser(t, "http://localhost:8082", user.ID)
        require.Equal(t, user.Email, fetched.Email)
    })
}
```

##### Scenario 3: Three-Node Cluster (Quorum)

```bash
# Test: Full quorum cluster with leader election
make test-fat-node-cluster-3
```

##### Scenario 4: Network Partition

```bash
# Test: Simulate network partition, verify nodes continue operating
make test-fat-node-partition
```

```go
// server/integration_test/partition_test.go
func TestNetworkPartition(t *testing.T) {
    // Start 3-node cluster
    // ...

    // Simulate partition by stopping routes
    t.Run("PartitionSurvival", func(t *testing.T) {
        // Block traffic between node1 and node2/node3
        // Verify node1 continues serving requests
        // Verify node2/node3 continue serving requests
    })

    t.Run("PartitionHealing", func(t *testing.T) {
        // Restore connectivity
        // Verify data syncs correctly
    })
}
```

##### Scenario 5: Node Restart

```bash
# Test: Stop and restart a node, verify it rejoins cluster
make test-fat-node-restart
```

### 3. End-to-End Tests

**Location:** `e2e/`

#### Browser-Based Tests (Playwright/Cypress)

```typescript
// e2e/tests/article-crud.spec.ts
test.describe('Article Management', () => {
  test('should create and view an article', async ({ page }) => {
    await page.goto('http://localhost:8080');
    
    // Login
    await page.fill('[data-testid="email"]', 'admin@example.com');
    await page.fill('[data-testid="password"]', 'password');
    await page.click('[data-testid="login"]');
    
    // Create article
    await page.click('[data-testid="new-article"]');
    await page.fill('[data-testid="title"]', 'Test Article');
    await page.fill('[data-testid="content"]', 'Test content');
    await page.click('[data-testid="save"]');
    
    // Verify article appears
    await expect(page.locator('text=Test Article')).toBeVisible();
  });

  test('should sync article changes via WebSocket', async ({ browser }) => {
    // Open two browser contexts
    const context1 = await browser.newContext();
    const context2 = await browser.newContext();
    const page1 = await context1.newPage();
    const page2 = await context2.newPage();

    // Both pages load the same article
    await page1.goto('http://localhost:8080/article/123');
    await page2.goto('http://localhost:8080/article/123');

    // Edit on page1
    await page1.fill('[data-testid="title"]', 'Updated Title');
    await page1.click('[data-testid="save"]');

    // Verify page2 receives update via WebSocket
    await expect(page2.locator('[data-testid="title"]')).toHaveValue('Updated Title');
  });
});
```

### 4. Load Tests

**Tool:** k6, vegeta, or hey

```javascript
// load/article-crud.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 20 },   // Ramp up
    { duration: '1m', target: 20 },    // Steady state
    { duration: '30s', target: 50 },   // Spike
    { duration: '30s', target: 0 },    // Ramp down
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'],  // 95% of requests under 500ms
    http_req_failed: ['rate<0.01'],    // Less than 1% failure rate
  },
};

export default function() {
  // Create article
  const createRes = http.post('http://localhost:8080/api/articles', JSON.stringify({
    title: `Load Test Article ${Date.now()}`,
    content: 'Test content',
  }), {
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${__ENV.TOKEN}` },
  });
  
  check(createRes, {
    'article created': (r) => r.status === 201,
  });

  sleep(1);
}
```

### 5. Chaos Tests

**Tool:** toxiproxy, chaos-mesh, or custom scripts

```bash
# chaos/network_latency.sh
#!/bin/bash
# Introduce 500ms latency between nodes
toxiproxy-cli toxic add -n latency -t latency -a latency=500 nats_cluster
sleep 60
toxiproxy-cli toxic remove -n latency nats_cluster
```

```bash
# chaos/node_crash.sh
#!/bin/bash
# Kill random node, verify cluster continues
NODES=("8081" "8082" "8083")
VICTIM=${NODES[$RANDOM % ${#NODES[@]}]}
echo "Killing node on port $VICTIM"
kill $(lsof -t -i:$VICTIM)
sleep 30
# Restart node
./server -fat-node -port $VICTIM &
```

---

## Production Readiness Checklist

### Configuration Management

- [ ] **Environment variables documented** in `.env.example`
- [ ] **Secrets management** - Use Fly.io secrets, Vault, or similar
- [ ] **Configuration validation** - Fail fast on invalid config
- [ ] **Default values** - Sensible defaults for all optional config

```bash
# .env.example
# Required
JWT_SECRET=                    # Min 12 chars, used for signing tokens
WEB_HASH_SALT=                 # Salt for password hashing

# Fat Node Mode
NODE_NAME=jst-node-1          # Unique identifier for this node
JETSTREAM_STORE=/data/js       # Persistent storage path
CLUSTER_PEERS=                 # Comma-separated peer addresses (ip:port)

# Optional
PORT=8080                      # HTTP server port
NATS_CLIENT_PORT=4222         # NATS client port
NATS_CLUSTER_PORT=6222        # NATS cluster port
NATS_CLUSTER_NAME=jst-cluster # Cluster name
LOG_LEVEL=info                 # debug, info, warn, error
```

### Health Checks

- [x] **Liveness probe** - `/health/live` (basic server alive)
- [x] **Readiness probe** - `/health/ready` (NATS connected, JetStream ready)
- [x] **Cluster status** - `/health/cluster` (routing info, peer count)
- [ ] **Startup probe** - Verify all services initialized

```yaml
# fly.toml additions
[checks]
  [checks.liveness]
    port = 8080
    path = "/health/live"
    interval = "15s"
    timeout = "5s"

  [checks.readiness]
    port = 8080
    path = "/health/ready"
    interval = "10s"
    timeout = "5s"
```

### Graceful Shutdown

- [x] **Signal handling** - SIGTERM/SIGINT triggers shutdown
- [x] **Drain connections** - Wait for in-flight requests
- [x] **Close NATS** - Flush messages, close connection
- [x] **Stop embedded server** - Clean NATS server shutdown
- [ ] **Shutdown timeout** - Force exit after 30s

### Logging

- [ ] **Structured logging** - JSON format for production
- [ ] **Log levels** - Configurable via environment
- [ ] **Request logging** - HTTP method, path, status, duration
- [ ] **Correlation IDs** - Track requests across services

```go
// Recommended: Replace jst_log with structured logger
type LogEntry struct {
    Time      time.Time `json:"time"`
    Level     string    `json:"level"`
    Message   string    `json:"msg"`
    Service   string    `json:"service,omitempty"`
    RequestID string    `json:"request_id,omitempty"`
    Duration  int64     `json:"duration_ms,omitempty"`
    Error     string    `json:"error,omitempty"`
}
```

### Rate Limiting

- [ ] **Per-IP rate limiting** - Prevent DoS
- [ ] **Per-user rate limiting** - Prevent abuse
- [ ] **Endpoint-specific limits** - Higher for reads, lower for writes

```go
// Example using chi middleware
import "github.com/go-chi/httprate"

r.Use(httprate.LimitByIP(100, 1*time.Minute))  // 100 req/min per IP
r.Use(httprate.LimitByRealIP(1000, 1*time.Minute))  // Behind proxy
```

---

## Deployment Scenarios

### Scenario 1: Single Fly.io Node (Current Production)

```bash
# Deploy single instance using NGS
fly deploy
```

**Pros:** Simple, managed NATS
**Cons:** Single point of failure, no offline support

### Scenario 2: Multi-Region Fly.io Fat Nodes

```toml
# fly.toml
app = 'jst-dev'
primary_region = 'arn'

[env]
  CLUSTER_PEERS = "jst-dev.internal:6222"

[mounts]
  source = "jetstream_data"
  destination = "/data/jetstream"

[[vm]]
  memory = '512mb'
  cpu_kind = 'shared'
  cpus = 1
```

```bash
# Deploy to multiple regions
fly regions add fra lhr
fly scale count 3 --max-per-region 1
```

### Scenario 3: Hybrid (Fly.io + Home Server)

```bash
# Home server setup
tailscale up --hostname=jst-home --advertise-tags=tag:jst-node

# Run fat node
NODE_NAME=jst-home \
JETSTREAM_STORE=/data/jetstream \
CLUSTER_PEERS=100.64.0.10:6222 \
JWT_SECRET=$JWT_SECRET \
WEB_HASH_SALT=$SALT \
./server -fat-node -log info
```

### Scenario 4: Edge Deployment (Raspberry Pi)

```bash
# Cross-compile for ARM64
GOOS=linux GOARCH=arm64 go build -o server-arm64 ./server

# Deploy to Pi
scp server-arm64 pi@raspberrypi:/opt/jst/
scp .env.production pi@raspberrypi:/opt/jst/.env

# Run as systemd service
sudo systemctl start jst-dev
```

```ini
# /etc/systemd/system/jst-dev.service
[Unit]
Description=jst-dev Fat Node
After=network.target tailscaled.service

[Service]
Type=simple
User=jst
WorkingDirectory=/opt/jst
EnvironmentFile=/opt/jst/.env
ExecStart=/opt/jst/server-arm64 -fat-node -log info
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

## Monitoring and Observability

### Metrics (Prometheus)

```go
// server/metrics/metrics.go
import "github.com/prometheus/client_golang/prometheus"

var (
    httpRequestsTotal = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total HTTP requests",
        },
        []string{"method", "path", "status"},
    )
    
    httpRequestDuration = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_request_duration_seconds",
            Help:    "HTTP request duration",
            Buckets: prometheus.DefBuckets,
        },
        []string{"method", "path"},
    )
    
    natsPublishTotal = prometheus.NewCounter(prometheus.CounterOpts{
        Name: "nats_publish_total",
        Help: "Total NATS messages published",
    })
    
    jetstreamKvOperations = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "jetstream_kv_operations_total",
            Help: "JetStream KV operations",
        },
        []string{"bucket", "operation"},
    )
)
```

### Tracing (OpenTelemetry)

```go
// server/tracing/tracing.go
import "go.opentelemetry.io/otel"

func InitTracing(serviceName string) func() {
    exporter, _ := jaeger.New(jaeger.WithCollectorEndpoint())
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exporter),
        sdktrace.WithResource(resource.NewWithAttributes(
            semconv.SchemaURL,
            semconv.ServiceName(serviceName),
        )),
    )
    otel.SetTracerProvider(tp)
    return func() { tp.Shutdown(context.Background()) }
}
```

### Alerting Rules

```yaml
# prometheus/alerts.yml
groups:
  - name: jst-dev
    rules:
      - alert: HighErrorRate
        expr: rate(http_requests_total{status=~"5.."}[5m]) > 0.1
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "High error rate on {{ $labels.instance }}"

      - alert: NATSDisconnected
        expr: up{job="jst-nats"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "NATS disconnected on {{ $labels.instance }}"

      - alert: JetStreamLagHigh
        expr: jetstream_consumer_ack_pending > 1000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "JetStream consumer lag high"
```

---

## Security Hardening

### Authentication & Authorization

- [x] **JWT-based auth** - Implemented in `who` service
- [ ] **Token refresh** - Automatic token renewal before expiry
- [ ] **Revocation** - Ability to invalidate tokens
- [ ] **Scope-based permissions** - Fine-grained access control

### Input Validation

- [ ] **Request size limits** - Prevent large payload attacks
- [ ] **Content-Type validation** - Reject unexpected types
- [ ] **SQL/NoSQL injection** - N/A (using KV store)
- [ ] **XSS prevention** - Sanitize user content

### Network Security

- [x] **HTTPS enforcement** - Fly.io handles TLS termination
- [x] **Tailscale encryption** - WireGuard for inter-node traffic
- [ ] **CORS configuration** - Restrict allowed origins
- [ ] **CSP headers** - Content Security Policy

```go
// Recommended security middleware
r.Use(middleware.SetHeader("X-Content-Type-Options", "nosniff"))
r.Use(middleware.SetHeader("X-Frame-Options", "DENY"))
r.Use(middleware.SetHeader("X-XSS-Protection", "1; mode=block"))
r.Use(middleware.SetHeader("Referrer-Policy", "strict-origin-when-cross-origin"))
```

### Secrets Management

```bash
# Fly.io secrets (production)
fly secrets set JWT_SECRET="$(openssl rand -base64 32)"
fly secrets set WEB_HASH_SALT="$(openssl rand -base64 16)"
fly secrets set NTFY_TOKEN="your-ntfy-token"

# Local development
cp .env.example .env
# Edit .env with development secrets (never commit!)
```

---

## Disaster Recovery

### Backup Strategy

#### Automated Backups

```bash
#!/bin/bash
# backup/daily_backup.sh
set -e

BACKUP_DIR="/backups/$(date +%Y-%m-%d)"
mkdir -p "$BACKUP_DIR"

# Export all KV buckets
for bucket in article who_users url_short convo_room; do
    nats kv dump "$bucket" > "$BACKUP_DIR/$bucket.json"
done

# Export streams
nats stream backup convo_message "$BACKUP_DIR/convo_message/"

# Compress
tar -czf "$BACKUP_DIR.tar.gz" "$BACKUP_DIR"
rm -rf "$BACKUP_DIR"

# Upload to S3
aws s3 cp "$BACKUP_DIR.tar.gz" "s3://jst-backups/daily/"

# Cleanup old backups (keep 30 days)
find /backups -name "*.tar.gz" -mtime +30 -delete
```

#### Restore Procedure

```bash
#!/bin/bash
# backup/restore.sh
set -e

BACKUP_FILE="$1"
if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: restore.sh <backup-file.tar.gz>"
    exit 1
fi

# Extract backup
tar -xzf "$BACKUP_FILE" -C /tmp

BACKUP_DIR="/tmp/$(basename "$BACKUP_FILE" .tar.gz)"

# Restore KV buckets
for json in "$BACKUP_DIR"/*.json; do
    bucket=$(basename "$json" .json)
    echo "Restoring $bucket..."
    # Clear existing data
    nats kv rm "$bucket" -f 2>/dev/null || true
    # Recreate and import
    nats kv add "$bucket"
    # Import entries (requires custom tool)
    jst-restore-kv "$bucket" < "$json"
done

# Restore streams
nats stream restore convo_message "$BACKUP_DIR/convo_message/"

echo "Restore complete!"
```

### Recovery Time Objectives

| Scenario | RTO | RPO | Strategy |
|----------|-----|-----|----------|
| Single node failure | 0 (auto-failover) | 0 | Cluster replication |
| Region outage | 5 min | 0 | Multi-region deployment |
| Data corruption | 30 min | 24 hours | Daily backups |
| Complete cluster loss | 1 hour | 24 hours | Backup restore |

---

## Implementation Timeline

### Week 1: Testing Foundation

- [ ] Set up integration test framework
- [ ] Write single-node integration tests
- [ ] Add unit tests for `core/jetstream.go`
- [ ] Add unit tests for `who` service

### Week 2: Cluster Testing

- [ ] Write two-node cluster tests
- [ ] Write three-node quorum tests
- [ ] Set up CI pipeline for tests
- [ ] Add network partition tests

### Week 3: Observability

- [ ] Add Prometheus metrics
- [ ] Add structured logging
- [ ] Set up Grafana dashboards
- [ ] Configure alerting rules

### Week 4: Security & Hardening

- [ ] Add rate limiting
- [ ] Add security headers
- [ ] Audit authentication flow
- [ ] Document secrets management

### Week 5: Production Prep

- [ ] Update Dockerfile for fat-node mode
- [ ] Configure multi-region Fly.io deployment
- [ ] Set up automated backups
- [ ] Write runbooks for common operations

### Week 6: Load Testing & Launch

- [ ] Run load tests
- [ ] Run chaos tests
- [ ] Fix identified issues
- [ ] Deploy to production
- [ ] Monitor and iterate

---

## Makefile Additions

```makefile
# Add to existing Makefile

# Integration tests
.PHONY: test-integration test-fat-node-single test-fat-node-cluster

test-integration: ## Run all integration tests
	cd server && go test -v -tags=integration ./integration_test/...

test-fat-node-single: ## Test single fat node
	cd server && go test -v -tags=integration -run TestSingleFatNode ./integration_test/...

test-fat-node-cluster-2: ## Test 2-node cluster
	cd server && go test -v -tags=integration -run TestTwoNodeCluster ./integration_test/...

test-fat-node-cluster-3: ## Test 3-node cluster  
	cd server && go test -v -tags=integration -run TestThreeNodeCluster ./integration_test/...

# Load tests
.PHONY: test-load

test-load: ## Run load tests
	k6 run load/article-crud.js

# Backup
.PHONY: backup restore

backup: ## Create backup of all data
	./scripts/backup.sh

restore: ## Restore from backup (BACKUP_FILE required)
	./scripts/restore.sh $(BACKUP_FILE)

# Build variants
.PHONY: build-arm64 build-all

build-arm64: ## Build for ARM64 (Raspberry Pi)
	cd server && GOOS=linux GOARCH=arm64 go build -o server-arm64 .

build-all: front-build ## Build all variants
	cd server && GOOS=linux GOARCH=amd64 go build -o server-amd64 .
	cd server && GOOS=linux GOARCH=arm64 go build -o server-arm64 .
	cd server && GOOS=darwin GOARCH=arm64 go build -o server-darwin-arm64 .
```

---

## Next Steps

1. **Start with tests** - Unit tests for the new retry logic, then integration tests
2. **Set up CI** - GitHub Actions to run tests on every PR
3. **Add observability** - Metrics first, then tracing
4. **Harden security** - Rate limiting and security headers
5. **Document operations** - Runbooks for common tasks
6. **Deploy incrementally** - Single fat node first, then cluster

---

## References

- [NATS JetStream Clustering](https://docs.nats.io/running-a-nats-service/configuration/clustering/jetstream_clustering)
- [Fly.io Multi-Region](https://fly.io/docs/getting-started/multi-region-databases/)
- [Tailscale ACLs](https://tailscale.com/kb/1018/acls)
- [Go Testing Best Practices](https://go.dev/doc/tutorial/add-a-test)
- [Prometheus Go Client](https://prometheus.io/docs/guides/go-application/)
