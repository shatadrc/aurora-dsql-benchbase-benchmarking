#!/bin/bash
#
# Coordinate Distributed Benchmark Execution
#
# This script helps coordinate the execution of distributed benchmarks
# across multiple EC2 instances. It can be run from a control machine
# to orchestrate all three benchmark instances.
#
# Usage:
#   ./coordinate-benchmark.sh [options]
#
# Options:
#   -c, --cluster-endpoint   Aurora DSQL cluster endpoint (required)
#   -1, --instance1          IP or hostname of instance 1 (required)
#   -2, --instance2          IP or hostname of instance 2 (required)
#   -3, --instance3          IP or hostname of instance 3 (required)
#   -k, --key-file           SSH key file for connecting to instances (required)
#   -w, --warehouses         Total number of warehouses (default: 20)
#   -r, --region             AWS region (default: us-east-1)
#   --time                   Benchmark execution time in seconds (default: 3600)
#   --warmup                 Warmup time in seconds (default: 600)
#   -h, --help               Show this help message
#
# Example:
#   ./coordinate-benchmark.sh \
#     -c my-cluster.dsql.us-east-1.on.aws \
#     -1 54.123.45.67 \
#     -2 54.123.45.68 \
#     -3 54.123.45.69 \
#     -k ~/.ssh/my-key.pem \
#     -w 20

set -e

# Default values
CLUSTER_ENDPOINT=""
INSTANCE1=""
INSTANCE2=""
INSTANCE3=""
KEY_FILE=""
WAREHOUSES=20
REGION="us-east-1"
EXECUTION_TIME=3600
WARMUP_TIME=600
SSH_USER="ec2-user"
BENCHMARK_SCRIPT="/opt/benchmark/run-distributed-benchmark.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print usage
usage() {
    grep -E '^#' "$0" | grep -v '#!/' | sed 's/^# //' | sed 's/^#//'
    exit 0
}

# Print colored message
print_msg() {
    local color=$1
    local msg=$2
    echo -e "${color}${msg}${NC}"
}

# Log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--cluster-endpoint)
            CLUSTER_ENDPOINT="$2"
            shift 2
            ;;
        -1|--instance1)
            INSTANCE1="$2"
            shift 2
            ;;
        -2|--instance2)
            INSTANCE2="$2"
            shift 2
            ;;
        -3|--instance3)
            INSTANCE3="$2"
            shift 2
            ;;
        -k|--key-file)
            KEY_FILE="$2"
            shift 2
            ;;
        -w|--warehouses)
            WAREHOUSES="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        --time)
            EXECUTION_TIME="$2"
            shift 2
            ;;
        --warmup)
            WARMUP_TIME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_msg "$RED" "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [ -z "$CLUSTER_ENDPOINT" ]; then
    print_msg "$RED" "Error: Cluster endpoint is required (-c)"
    exit 1
fi

if [ -z "$INSTANCE1" ] || [ -z "$INSTANCE2" ] || [ -z "$INSTANCE3" ]; then
    print_msg "$RED" "Error: All three instance IPs are required (-1, -2, -3)"
    exit 1
fi

if [ -z "$KEY_FILE" ]; then
    print_msg "$RED" "Error: SSH key file is required (-k)"
    exit 1
fi

if [ ! -f "$KEY_FILE" ]; then
    print_msg "$RED" "Error: SSH key file not found: $KEY_FILE"
    exit 1
fi

# SSH command helper
ssh_cmd() {
    local host=$1
    local cmd=$2
    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${SSH_USER}@${host}" "$cmd"
}

# SSH command in background
ssh_bg() {
    local host=$1
    local cmd=$2
    local logfile=$3
    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${SSH_USER}@${host}" "$cmd" > "$logfile" 2>&1 &
    echo $!
}

print_msg "$GREEN" "=========================================="
print_msg "$GREEN" "DSQL Distributed Benchmark Coordinator"
print_msg "$GREEN" "=========================================="
print_msg "$NC" ""
print_msg "$NC" "Configuration:"
print_msg "$NC" "  Cluster Endpoint: $CLUSTER_ENDPOINT"
print_msg "$NC" "  Region:           $REGION"
print_msg "$NC" "  Warehouses:       $WAREHOUSES"
print_msg "$NC" "  Execution Time:   ${EXECUTION_TIME}s"
print_msg "$NC" "  Warmup Time:      ${WARMUP_TIME}s"
print_msg "$NC" ""
print_msg "$NC" "Instances:"
print_msg "$NC" "  Instance 1: $INSTANCE1"
print_msg "$NC" "  Instance 2: $INSTANCE2"
print_msg "$NC" "  Instance 3: $INSTANCE3"
print_msg "$NC" ""

# Create temp directory for logs
TEMP_DIR=$(mktemp -d)
log "Log files will be stored in: $TEMP_DIR"

# Test connectivity to all instances
log "Testing connectivity to all instances..."
for i in 1 2 3; do
    eval "host=\$INSTANCE$i"
    if ! ssh_cmd "$host" "echo 'Connection successful'" &>/dev/null; then
        print_msg "$RED" "Error: Cannot connect to instance $i ($host)"
        exit 1
    fi
    print_msg "$GREEN" "  Instance $i ($host): Connected"
done

# Check if benchbase is ready on all instances
log "Checking benchbase installation on all instances..."
for i in 1 2 3; do
    eval "host=\$INSTANCE$i"
    if ! ssh_cmd "$host" "test -f /opt/benchmark/aurora-dsql-benchbase-benchmarking/target/benchbase-auroradsql/benchbase.jar"; then
        print_msg "$RED" "Error: Benchbase not ready on instance $i ($host)"
        print_msg "$YELLOW" "Check /var/log/user-data.log on the instance"
        exit 1
    fi
    print_msg "$GREEN" "  Instance $i ($host): Benchbase ready"
done

# Common benchmark arguments
COMMON_ARGS="-c $CLUSTER_ENDPOINT -r $REGION -w $WAREHOUSES --time $EXECUTION_TIME --warmup $WARMUP_TIME"

# Phase 1: Initialization (only instance 1)
print_msg "$BLUE" ""
print_msg "$BLUE" "=========================================="
print_msg "$BLUE" "Phase 1: Schema and Item Initialization"
print_msg "$BLUE" "=========================================="
log "Running initialization on instance 1..."

ssh_cmd "$INSTANCE1" "source /opt/benchmark/benchmark-env.sh && $BENCHMARK_SCRIPT $COMMON_ARGS -i 1 -p init"

print_msg "$GREEN" "Initialization complete!"
log "Waiting 30 seconds for schema propagation..."
sleep 30

# Phase 2: Distributed Data Loading
print_msg "$BLUE" ""
print_msg "$BLUE" "=========================================="
print_msg "$BLUE" "Phase 2: Distributed Warehouse Loading"
print_msg "$BLUE" "=========================================="
log "Starting parallel data loading on all instances..."

# Start loading on all instances in parallel
PID1=$(ssh_bg "$INSTANCE1" "source /opt/benchmark/benchmark-env.sh && $BENCHMARK_SCRIPT $COMMON_ARGS -i 1 -p load" "$TEMP_DIR/load_instance1.log")
PID2=$(ssh_bg "$INSTANCE2" "source /opt/benchmark/benchmark-env.sh && $BENCHMARK_SCRIPT $COMMON_ARGS -i 2 -p load" "$TEMP_DIR/load_instance2.log")
PID3=$(ssh_bg "$INSTANCE3" "source /opt/benchmark/benchmark-env.sh && $BENCHMARK_SCRIPT $COMMON_ARGS -i 3 -p load" "$TEMP_DIR/load_instance3.log")

print_msg "$NC" "Loading processes started:"
print_msg "$NC" "  Instance 1 PID: $PID1"
print_msg "$NC" "  Instance 2 PID: $PID2"
print_msg "$NC" "  Instance 3 PID: $PID3"

# Wait for all loading processes to complete
log "Waiting for data loading to complete on all instances..."
FAILED=0
for pid in $PID1 $PID2 $PID3; do
    if ! wait $pid; then
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    print_msg "$RED" "Data loading failed on one or more instances. Check logs:"
    print_msg "$RED" "  $TEMP_DIR/load_instance1.log"
    print_msg "$RED" "  $TEMP_DIR/load_instance2.log"
    print_msg "$RED" "  $TEMP_DIR/load_instance3.log"
    exit 1
fi

print_msg "$GREEN" "Data loading complete on all instances!"

# Phase 3: Distributed Benchmark Execution
print_msg "$BLUE" ""
print_msg "$BLUE" "=========================================="
print_msg "$BLUE" "Phase 3: Distributed Benchmark Execution"
print_msg "$BLUE" "=========================================="
log "Starting benchmark execution on all instances..."

# Start execution on all instances in parallel
PID1=$(ssh_bg "$INSTANCE1" "source /opt/benchmark/benchmark-env.sh && $BENCHMARK_SCRIPT $COMMON_ARGS -i 1 -p execute" "$TEMP_DIR/exec_instance1.log")
PID2=$(ssh_bg "$INSTANCE2" "source /opt/benchmark/benchmark-env.sh && $BENCHMARK_SCRIPT $COMMON_ARGS -i 2 -p execute" "$TEMP_DIR/exec_instance2.log")
PID3=$(ssh_bg "$INSTANCE3" "source /opt/benchmark/benchmark-env.sh && $BENCHMARK_SCRIPT $COMMON_ARGS -i 3 -p execute" "$TEMP_DIR/exec_instance3.log")

print_msg "$NC" "Execution processes started:"
print_msg "$NC" "  Instance 1 PID: $PID1"
print_msg "$NC" "  Instance 2 PID: $PID2"
print_msg "$NC" "  Instance 3 PID: $PID3"

# Estimate completion time
TOTAL_TIME=$((WARMUP_TIME + EXECUTION_TIME))
END_TIME=$(date -d "+${TOTAL_TIME} seconds" '+%Y-%m-%d %H:%M:%S')
print_msg "$YELLOW" ""
print_msg "$YELLOW" "Benchmark running... Estimated completion: $END_TIME"
print_msg "$YELLOW" "Total runtime: ${TOTAL_TIME} seconds (warmup: ${WARMUP_TIME}s + execution: ${EXECUTION_TIME}s)"
print_msg "$NC" ""

# Wait for all execution processes to complete
log "Waiting for benchmark execution to complete on all instances..."
FAILED=0
for pid in $PID1 $PID2 $PID3; do
    if ! wait $pid; then
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    print_msg "$RED" "Benchmark execution failed on one or more instances. Check logs:"
    print_msg "$RED" "  $TEMP_DIR/exec_instance1.log"
    print_msg "$RED" "  $TEMP_DIR/exec_instance2.log"
    print_msg "$RED" "  $TEMP_DIR/exec_instance3.log"
    exit 1
fi

print_msg "$GREEN" ""
print_msg "$GREEN" "=========================================="
print_msg "$GREEN" "Benchmark Complete!"
print_msg "$GREEN" "=========================================="
print_msg "$NC" ""

# Collect results
log "Collecting results from all instances..."
RESULTS_DIR="benchmark_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

for i in 1 2 3; do
    eval "host=\$INSTANCE$i"
    mkdir -p "$RESULTS_DIR/instance$i"
    scp -i "$KEY_FILE" -o StrictHostKeyChecking=no \
        "${SSH_USER}@${host}:/opt/benchmark/aurora-dsql-benchbase-benchmarking/target/benchbase-auroradsql/results_*" \
        "$RESULTS_DIR/instance$i/" 2>/dev/null || true
    print_msg "$NC" "  Instance $i results saved to: $RESULTS_DIR/instance$i/"
done

print_msg "$NC" ""
print_msg "$NC" "Results collected to: $RESULTS_DIR"
print_msg "$NC" "Log files are in: $TEMP_DIR"
print_msg "$NC" ""
print_msg "$YELLOW" "To aggregate results, sum the TPS values from all three instances."
log "Distributed benchmark coordination completed successfully!"
