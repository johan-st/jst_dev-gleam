#!/bin/bash
# cluster-test.sh - Start a 3-node fat node cluster for local testing
#
# Usage: ./scripts/cluster-test.sh [start|status|logs]
#
# This script starts 3 local fat nodes that cluster together using localhost.
# Each node uses different ports to avoid conflicts:
#   - Node 1: HTTP 8081, NATS Client 4222, NATS Cluster 6222
#   - Node 2: HTTP 8082, NATS Client 4223, NATS Cluster 6223  
#   - Node 3: HTTP 8083, NATS Client 4224, NATS Cluster 6224

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SERVER_DIR="$PROJECT_ROOT/server"
LOG_DIR="$PROJECT_ROOT/.cluster-test"
PID_FILE="$LOG_DIR/pids"

# Environment variables for all nodes
export JWT_SECRET="test-jwt-secret-12345"
export WEB_HASH_SALT="test-hash-salt"
export JETSTREAM_REPLICAS=3

# Node configurations
declare -A NODE1=(
    [name]="node1"
    [http_port]="8081"
    [nats_client]="4222"
    [nats_cluster]="6222"
    [peers]="127.0.0.1:6223,127.0.0.1:6224"
    [data_dir]="$LOG_DIR/node1/data"
)

declare -A NODE2=(
    [name]="node2"
    [http_port]="8082"
    [nats_client]="4223"
    [nats_cluster]="6223"
    [peers]="127.0.0.1:6222,127.0.0.1:6224"
    [data_dir]="$LOG_DIR/node2/data"
)

declare -A NODE3=(
    [name]="node3"
    [http_port]="8083"
    [nats_client]="4224"
    [nats_cluster]="6224"
    [peers]="127.0.0.1:6222,127.0.0.1:6223"
    [data_dir]="$LOG_DIR/node3/data"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Build the server if needed
build_server() {
    log_info "Building server..."
    cd "$SERVER_DIR"
    go build -o "$LOG_DIR/server" .
    log_info "Server built at $LOG_DIR/server"
}

# Start a single node
start_node() {
    local name=$1
    local http_port=$2
    local nats_client=$3
    local nats_cluster=$4
    local peers=$5
    local data_dir=$6
    
    mkdir -p "$data_dir"
    mkdir -p "$LOG_DIR/$name"
    
    log_info "Starting $name (HTTP: $http_port, NATS: $nats_client, Cluster: $nats_cluster)..."
    
    NODE_NAME="$name" \
    PORT="$http_port" \
    NATS_CLIENT_PORT="$nats_client" \
    NATS_CLUSTER_PORT="$nats_cluster" \
    CLUSTER_PEERS="$peers" \
    JETSTREAM_STORE="$data_dir/jetstream" \
    TAILSCALE_IP="127.0.0.1" \
    "$LOG_DIR/server" -fat-node -log info > "$LOG_DIR/$name/stdout.log" 2>&1 &
    
    local pid=$!
    echo "$name:$pid" >> "$PID_FILE"
    log_info "$name started with PID $pid"
}

# Start the 3-node cluster
start_cluster() {
    log_info "Starting 3-node cluster..."
    
    # Create log directory
    mkdir -p "$LOG_DIR"
    rm -f "$PID_FILE"
    
    # Build server
    build_server
    
    # Start nodes with staggered timing
    start_node "${NODE1[name]}" "${NODE1[http_port]}" "${NODE1[nats_client]}" "${NODE1[nats_cluster]}" "${NODE1[peers]}" "${NODE1[data_dir]}"
    sleep 2
    
    start_node "${NODE2[name]}" "${NODE2[http_port]}" "${NODE2[nats_client]}" "${NODE2[nats_cluster]}" "${NODE2[peers]}" "${NODE2[data_dir]}"
    sleep 2
    
    start_node "${NODE3[name]}" "${NODE3[http_port]}" "${NODE3[nats_client]}" "${NODE3[nats_cluster]}" "${NODE3[peers]}" "${NODE3[data_dir]}"
    
    log_info "All nodes started. Waiting for cluster to form..."
    sleep 5
    
    # Check health
    check_cluster_health
}

# Check if nodes are healthy
check_cluster_health() {
    log_info "Checking cluster health..."
    
    local all_healthy=true
    
    for port in 8081 8082 8083; do
        if curl -sf "http://127.0.0.1:$port/health/ready" > /dev/null 2>&1; then
            log_info "Node on port $port is healthy"
        else
            log_warn "Node on port $port is NOT ready"
            all_healthy=false
        fi
    done
    
    if $all_healthy; then
        log_info "All nodes are healthy!"
        
        # Get cluster info from first node
        echo ""
        log_info "Cluster info from node1:"
        curl -s "http://127.0.0.1:8081/health/cluster" | python3 -m json.tool 2>/dev/null || curl -s "http://127.0.0.1:8081/health/cluster"
        echo ""
    else
        log_warn "Some nodes are not ready yet. Check logs in $LOG_DIR/"
    fi
}

# Show status of running nodes
show_status() {
    if [ ! -f "$PID_FILE" ]; then
        log_info "No cluster running (no PID file found)"
        return
    fi
    
    log_info "Checking node status..."
    echo ""
    
    while IFS=: read -r name pid; do
        if ps -p "$pid" > /dev/null 2>&1; then
            echo -e "  ${GREEN}[RUNNING]${NC} $name (PID: $pid)"
        else
            echo -e "  ${RED}[STOPPED]${NC} $name (PID: $pid)"
        fi
    done < "$PID_FILE"
    
    echo ""
    check_cluster_health
}

# Show logs for a node
show_logs() {
    local node=${1:-node1}
    local log_file="$LOG_DIR/$node/stdout.log"
    
    if [ ! -f "$log_file" ]; then
        log_error "Log file not found: $log_file"
        return 1
    fi
    
    log_info "Showing logs for $node (Ctrl+C to exit)..."
    tail -f "$log_file"
}

# Stop all nodes
stop_cluster() {
    if [ ! -f "$PID_FILE" ]; then
        log_info "No cluster running"
        return
    fi
    
    log_info "Stopping cluster..."
    
    while IFS=: read -r name pid; do
        if ps -p "$pid" > /dev/null 2>&1; then
            log_info "Stopping $name (PID: $pid)..."
            kill "$pid" 2>/dev/null || true
        fi
    done < "$PID_FILE"
    
    # Wait for processes to stop
    sleep 2
    
    # Force kill any remaining
    while IFS=: read -r name pid; do
        if ps -p "$pid" > /dev/null 2>&1; then
            log_warn "Force killing $name (PID: $pid)..."
            kill -9 "$pid" 2>/dev/null || true
        fi
    done < "$PID_FILE"
    
    rm -f "$PID_FILE"
    log_info "Cluster stopped"
}

# Clean up all data
clean() {
    stop_cluster
    log_info "Cleaning up cluster data..."
    rm -rf "$LOG_DIR"
    log_info "Cleanup complete"
}

# Print usage
usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  start   - Start the 3-node cluster"
    echo "  stop    - Stop all cluster nodes"
    echo "  status  - Show status of running nodes"
    echo "  logs    - Show logs for node1 (or specify: logs node2)"
    echo "  health  - Check cluster health"
    echo "  clean   - Stop cluster and remove all data"
    echo "  help    - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 start           # Start cluster"
    echo "  $0 status          # Check status"
    echo "  $0 logs node2      # Follow node2 logs"
    echo "  $0 stop            # Stop cluster"
    echo "  $0 clean           # Stop and clean up"
}

# Main
case "${1:-help}" in
    start)
        start_cluster
        ;;
    stop)
        stop_cluster
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs "${2:-node1}"
        ;;
    health)
        check_cluster_health
        ;;
    clean)
        clean
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        log_error "Unknown command: $1"
        usage
        exit 1
        ;;
esac
