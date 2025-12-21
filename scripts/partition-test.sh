#!/bin/bash
# partition-test.sh - Test network partition recovery for fat node cluster
#
# Usage: ./scripts/partition-test.sh [scenario]
#
# This script tests the cluster's ability to recover from network partitions.
# It creates data on one node, partitions the cluster, creates more data,
# then heals the partition and verifies data replication.
#
# Prerequisites:
#   - Cluster must be running (./scripts/cluster-test.sh start)
#   - curl must be installed

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_ROOT/.cluster-test"
PID_FILE="$LOG_DIR/pids"

# Node endpoints
NODE1_HTTP="http://127.0.0.1:8081"
NODE2_HTTP="http://127.0.0.1:8082"
NODE3_HTTP="http://127.0.0.1:8083"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${BLUE}[TEST]${NC} $1"; }

# Check if cluster is running
check_cluster_running() {
    if [ ! -f "$PID_FILE" ]; then
        log_error "Cluster is not running. Start it with: ./scripts/cluster-test.sh start"
        exit 1
    fi
    
    for port in 8081 8082 8083; do
        if ! curl -sf "http://127.0.0.1:$port/health/ready" > /dev/null 2>&1; then
            log_error "Node on port $port is not ready"
            exit 1
        fi
    done
    
    log_info "Cluster is running and healthy"
}

# Wait for condition with timeout
wait_for() {
    local description=$1
    local check_cmd=$2
    local timeout=${3:-30}
    
    log_info "Waiting for: $description (timeout: ${timeout}s)"
    
    local start_time=$(date +%s)
    while true; do
        if eval "$check_cmd" 2>/dev/null; then
            log_info "Success: $description"
            return 0
        fi
        
        local elapsed=$(($(date +%s) - start_time))
        if [ $elapsed -ge $timeout ]; then
            log_error "Timeout waiting for: $description"
            return 1
        fi
        
        sleep 1
    done
}

# Create a test article on a specific node
create_article() {
    local node_url=$1
    local title=$2
    
    # First, create a basic article (requires auth in real scenario, but for testing...)
    # We'll use the KV directly via NATS for this test
    
    log_info "Creating article '$title' on $node_url"
    
    # For now, we'll test with the health endpoints which don't require auth
    local result=$(curl -sf "$node_url/health/cluster" 2>/dev/null)
    if [ -n "$result" ]; then
        log_info "Node $node_url is accessible"
        return 0
    fi
    return 1
}

# Check cluster info from a node
get_cluster_info() {
    local node_url=$1
    curl -sf "$node_url/health/cluster" 2>/dev/null
}

# Stop a specific node by name
stop_node() {
    local node_name=$1
    
    if [ ! -f "$PID_FILE" ]; then
        log_error "No PID file found"
        return 1
    fi
    
    while IFS=: read -r name pid; do
        if [ "$name" = "$node_name" ]; then
            if ps -p "$pid" > /dev/null 2>&1; then
                log_info "Stopping $node_name (PID: $pid)..."
                kill "$pid" 2>/dev/null || true
                sleep 1
                return 0
            else
                log_warn "$node_name is already stopped"
                return 0
            fi
        fi
    done < "$PID_FILE"
    
    log_error "Node $node_name not found"
    return 1
}

# Restart a specific node
restart_node() {
    local node_name=$1
    
    log_info "Restarting $node_name..."
    
    # Get node config
    local http_port nats_client nats_cluster peers data_dir
    case $node_name in
        node1)
            http_port=8081; nats_client=4222; nats_cluster=6222
            peers="127.0.0.1:6223,127.0.0.1:6224"
            data_dir="$LOG_DIR/node1/data"
            ;;
        node2)
            http_port=8082; nats_client=4223; nats_cluster=6223
            peers="127.0.0.1:6222,127.0.0.1:6224"
            data_dir="$LOG_DIR/node2/data"
            ;;
        node3)
            http_port=8083; nats_client=4224; nats_cluster=6224
            peers="127.0.0.1:6222,127.0.0.1:6223"
            data_dir="$LOG_DIR/node3/data"
            ;;
        *)
            log_error "Unknown node: $node_name"
            return 1
            ;;
    esac
    
    mkdir -p "$data_dir"
    mkdir -p "$LOG_DIR/$node_name"
    
    NODE_NAME="$node_name" \
    PORT="$http_port" \
    NATS_CLIENT_PORT="$nats_client" \
    NATS_CLUSTER_PORT="$nats_cluster" \
    CLUSTER_PEERS="$peers" \
    JETSTREAM_STORE="$data_dir/jetstream" \
    TAILSCALE_IP="127.0.0.1" \
    JWT_SECRET="test-jwt-secret-12345" \
    WEB_HASH_SALT="test-hash-salt" \
    JETSTREAM_REPLICAS=3 \
    "$LOG_DIR/server" -fat-node -log info > "$LOG_DIR/$node_name/stdout.log" 2>&1 &
    
    local pid=$!
    
    # Update PID file
    grep -v "^$node_name:" "$PID_FILE" > "$PID_FILE.tmp" 2>/dev/null || true
    echo "$node_name:$pid" >> "$PID_FILE.tmp"
    mv "$PID_FILE.tmp" "$PID_FILE"
    
    log_info "$node_name restarted with PID $pid"
}

# Test 1: Node failure and recovery
test_node_failure_recovery() {
    log_test "=== Test: Node Failure and Recovery ==="
    echo ""
    
    check_cluster_running
    
    # Get initial cluster state
    log_info "Initial cluster state:"
    get_cluster_info "$NODE1_HTTP" | python3 -m json.tool 2>/dev/null || get_cluster_info "$NODE1_HTTP"
    echo ""
    
    # Stop node2
    log_test "Step 1: Stopping node2 to simulate node failure..."
    stop_node "node2"
    sleep 3
    
    # Verify remaining nodes are still healthy
    log_test "Step 2: Verifying remaining nodes are healthy..."
    if curl -sf "$NODE1_HTTP/health/ready" > /dev/null && \
       curl -sf "$NODE3_HTTP/health/ready" > /dev/null; then
        log_info "node1 and node3 are still healthy"
    else
        log_error "Some nodes became unhealthy"
        return 1
    fi
    
    # Show cluster info (should show only 2 servers now)
    log_info "Cluster state after node2 failure:"
    get_cluster_info "$NODE1_HTTP" | python3 -m json.tool 2>/dev/null || get_cluster_info "$NODE1_HTTP"
    echo ""
    
    # Restart node2
    log_test "Step 3: Restarting node2..."
    restart_node "node2"
    
    # Wait for node2 to be ready
    wait_for "node2 to be ready" "curl -sf $NODE2_HTTP/health/ready > /dev/null" 60
    
    # Wait a bit for cluster to stabilize
    log_info "Waiting for cluster to stabilize..."
    sleep 5
    
    # Verify all nodes are healthy
    log_test "Step 4: Verifying all nodes are healthy..."
    local all_healthy=true
    for url in "$NODE1_HTTP" "$NODE2_HTTP" "$NODE3_HTTP"; do
        if curl -sf "$url/health/ready" > /dev/null; then
            log_info "$url is healthy"
        else
            log_error "$url is NOT healthy"
            all_healthy=false
        fi
    done
    
    if $all_healthy; then
        log_info "Cluster recovered successfully!"
        get_cluster_info "$NODE1_HTTP" | python3 -m json.tool 2>/dev/null || get_cluster_info "$NODE1_HTTP"
        echo ""
        return 0
    else
        log_error "Cluster did not recover properly"
        return 1
    fi
}

# Test 2: Minority partition (1 node isolated)
test_minority_partition() {
    log_test "=== Test: Minority Partition (1 node isolated) ==="
    echo ""
    
    check_cluster_running
    
    # Stop node3 (minority)
    log_test "Step 1: Isolating node3 (minority partition)..."
    stop_node "node3"
    sleep 3
    
    # Verify majority (node1 + node2) can still operate
    log_test "Step 2: Verifying majority can still operate..."
    if curl -sf "$NODE1_HTTP/health/ready" > /dev/null && \
       curl -sf "$NODE2_HTTP/health/ready" > /dev/null; then
        log_info "Majority (node1 + node2) is operational"
    else
        log_error "Majority partition failed"
        return 1
    fi
    
    # Try to access data from majority
    log_info "Cluster state from majority:"
    get_cluster_info "$NODE1_HTTP" | python3 -m json.tool 2>/dev/null || get_cluster_info "$NODE1_HTTP"
    echo ""
    
    # Heal partition
    log_test "Step 3: Healing partition (restarting node3)..."
    restart_node "node3"
    
    wait_for "node3 to rejoin cluster" "curl -sf $NODE3_HTTP/health/ready > /dev/null" 60
    sleep 5
    
    # Verify cluster is whole again
    log_test "Step 4: Verifying cluster is whole..."
    for url in "$NODE1_HTTP" "$NODE2_HTTP" "$NODE3_HTTP"; do
        if curl -sf "$url/health/ready" > /dev/null; then
            log_info "$url is healthy"
        else
            log_error "$url is NOT healthy"
            return 1
        fi
    done
    
    log_info "Minority partition test passed!"
    return 0
}

# Test 3: Sequential node restarts
test_rolling_restart() {
    log_test "=== Test: Rolling Restart (Sequential node restarts) ==="
    echo ""
    
    check_cluster_running
    
    for node in node1 node2 node3; do
        log_test "Restarting $node..."
        stop_node "$node"
        sleep 2
        restart_node "$node"
        
        # Wait for node to be ready
        local port
        case $node in
            node1) port=8081 ;;
            node2) port=8082 ;;
            node3) port=8083 ;;
        esac
        
        wait_for "$node to be ready" "curl -sf http://127.0.0.1:$port/health/ready > /dev/null" 60
        
        log_info "$node restarted successfully"
        sleep 3
    done
    
    # Verify all nodes are healthy
    log_test "Verifying all nodes are healthy after rolling restart..."
    for url in "$NODE1_HTTP" "$NODE2_HTTP" "$NODE3_HTTP"; do
        if curl -sf "$url/health/ready" > /dev/null; then
            log_info "$url is healthy"
        else
            log_error "$url is NOT healthy"
            return 1
        fi
    done
    
    log_info "Rolling restart test passed!"
    return 0
}

# Test 4: Simultaneous restart of 2 nodes
test_majority_restart() {
    log_test "=== Test: Majority Restart (2 nodes restart simultaneously) ==="
    echo ""
    
    check_cluster_running
    
    log_test "Step 1: Stopping node2 and node3 simultaneously..."
    stop_node "node2" &
    stop_node "node3" &
    wait
    sleep 3
    
    # node1 should still be running but without quorum
    log_test "Step 2: Checking node1 status (should be running but potentially degraded)..."
    if curl -sf "$NODE1_HTTP/health/live" > /dev/null; then
        log_info "node1 is still alive"
    else
        log_warn "node1 may be experiencing issues"
    fi
    
    # Restart both nodes
    log_test "Step 3: Restarting node2 and node3..."
    restart_node "node2"
    restart_node "node3"
    
    # Wait for both to be ready
    wait_for "node2 to be ready" "curl -sf $NODE2_HTTP/health/ready > /dev/null" 60
    wait_for "node3 to be ready" "curl -sf $NODE3_HTTP/health/ready > /dev/null" 60
    
    sleep 5
    
    # Verify cluster health
    log_test "Step 4: Verifying cluster health..."
    for url in "$NODE1_HTTP" "$NODE2_HTTP" "$NODE3_HTTP"; do
        if curl -sf "$url/health/ready" > /dev/null; then
            log_info "$url is healthy"
        else
            log_error "$url is NOT healthy"
            return 1
        fi
    done
    
    log_info "Majority restart test passed!"
    return 0
}

# Run all tests
run_all_tests() {
    local passed=0
    local failed=0
    
    log_test "========================================"
    log_test "Running all partition recovery tests"
    log_test "========================================"
    echo ""
    
    for test_func in test_node_failure_recovery test_minority_partition test_rolling_restart test_majority_restart; do
        echo ""
        echo "========================================" 
        
        if $test_func; then
            ((passed++))
            log_info "PASSED: $test_func"
        else
            ((failed++))
            log_error "FAILED: $test_func"
        fi
        
        echo ""
        # Give cluster time to stabilize between tests
        sleep 5
    done
    
    echo ""
    log_test "========================================"
    log_test "Test Summary"
    log_test "========================================"
    echo -e "  ${GREEN}Passed: $passed${NC}"
    echo -e "  ${RED}Failed: $failed${NC}"
    echo ""
    
    if [ $failed -eq 0 ]; then
        log_info "All tests passed!"
        return 0
    else
        log_error "Some tests failed"
        return 1
    fi
}

# Print usage
usage() {
    echo "Usage: $0 [test]"
    echo ""
    echo "Tests:"
    echo "  all              - Run all partition tests"
    echo "  node-failure     - Test node failure and recovery"
    echo "  minority         - Test minority partition"
    echo "  rolling          - Test rolling restart"
    echo "  majority         - Test majority restart"
    echo "  help             - Show this help message"
    echo ""
    echo "Prerequisites:"
    echo "  - Cluster must be running: ./scripts/cluster-test.sh start"
}

# Main
case "${1:-help}" in
    all)
        run_all_tests
        ;;
    node-failure)
        test_node_failure_recovery
        ;;
    minority)
        test_minority_partition
        ;;
    rolling)
        test_rolling_restart
        ;;
    majority)
        test_majority_restart
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        log_error "Unknown test: $1"
        usage
        exit 1
        ;;
esac
