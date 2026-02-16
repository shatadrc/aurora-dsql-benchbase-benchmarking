#!/bin/bash
#
# Distributed Benchmark Runner Script
#
# This script coordinates the execution of TPC-C benchmarks across multiple
# EC2 instances for Aurora DSQL. It runs different phases of the benchmark
# depending on the instance ID and operation mode.
#
# Usage:
#   ./run-distributed-benchmark.sh [options]
#
# Options:
#   -c, --cluster-endpoint   Aurora DSQL cluster endpoint (required)
#   -r, --region             AWS region (default: us-east-1)
#   -w, --warehouses         Total number of warehouses (default: 20)
#   -i, --instance-id        Instance ID (1, 2, or 3) - auto-detected if not specified
#   -t, --total-instances    Total number of instances (default: 3)
#   -p, --phase              Benchmark phase: init, load, execute, all (default: all)
#   -l, --loader-threads     Number of loader threads per instance (default: 20)
#   --time                   Benchmark execution time in seconds (default: 3600)
#   --warmup                 Warmup time in seconds (default: 600)
#   -h, --help               Show this help message
#
# Examples:
#   # Run all phases on instance 1
#   ./run-distributed-benchmark.sh -c <endpoint> -i 1
#
#   # Run only initialization (schema + items) on instance 1
#   ./run-distributed-benchmark.sh -c <endpoint> -i 1 -p init
#
#   # Run only data loading on instance 2
#   ./run-distributed-benchmark.sh -c <endpoint> -i 2 -p load
#
#   # Run only execution on instance 3
#   ./run-distributed-benchmark.sh -c <endpoint> -i 3 -p execute

set -e

# Default values
CLUSTER_ENDPOINT=""
REGION="us-east-1"
WAREHOUSES=20
INSTANCE_ID=""
TOTAL_INSTANCES=3
PHASE="all"
LOADER_THREADS=20
EXECUTION_TIME=3600
WARMUP_TIME=600

# Load environment if available
if [ -f /opt/benchmark/benchmark-env.sh ]; then
    source /opt/benchmark/benchmark-env.sh
fi

# Set defaults from environment
INSTANCE_ID="${INSTANCE_ID:-}"
BENCHMARK_HOME="${BENCHMARK_HOME:-/opt/benchmark/aurora-dsql-benchbase-benchmarking/target/benchbase-auroradsql}"

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

# Print timestamped log message
log() {
    local msg=$1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--cluster-endpoint)
            CLUSTER_ENDPOINT="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -w|--warehouses)
            WAREHOUSES="$2"
            shift 2
            ;;
        -i|--instance-id)
            INSTANCE_ID="$2"
            shift 2
            ;;
        -t|--total-instances)
            TOTAL_INSTANCES="$2"
            shift 2
            ;;
        -p|--phase)
            PHASE="$2"
            shift 2
            ;;
        -l|--loader-threads)
            LOADER_THREADS="$2"
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
    print_msg "$RED" "Error: Cluster endpoint is required (-c, --cluster-endpoint)"
    exit 1
fi

if [ -z "$INSTANCE_ID" ]; then
    print_msg "$RED" "Error: Instance ID is required (-i, --instance-id)"
    print_msg "$YELLOW" "Tip: Set INSTANCE_ID in /opt/benchmark/benchmark-env.sh or use -i option"
    exit 1
fi

# Validate instance ID
if [[ ! "$INSTANCE_ID" =~ ^[1-9][0-9]*$ ]] || [ "$INSTANCE_ID" -gt "$TOTAL_INSTANCES" ]; then
    print_msg "$RED" "Error: Instance ID must be between 1 and $TOTAL_INSTANCES"
    exit 1
fi

# Check benchbase installation
if [ ! -f "$BENCHMARK_HOME/benchbase.jar" ]; then
    print_msg "$RED" "Error: benchbase.jar not found at $BENCHMARK_HOME"
    print_msg "$YELLOW" "Make sure benchbase is built and extracted"
    exit 1
fi

# Calculate instance-specific parameters
STRIDE=$TOTAL_INSTANCES
START_WAREHOUSE=$INSTANCE_ID
END_WAREHOUSE=$WAREHOUSES

# Calculate terminals (warehouses this instance handles)
TERMINALS=$(( (WAREHOUSES - START_WAREHOUSE) / STRIDE + 1 ))
if [ $(( START_WAREHOUSE + (TERMINALS - 1) * STRIDE )) -gt $WAREHOUSES ]; then
    TERMINALS=$((TERMINALS - 1))
fi

# Build JDBC URL
JDBC_URL="jdbc:postgresql://${CLUSTER_ENDPOINT}:5432/postgres?sslmode=require&ApplicationName=tpcc&reWriteBatchedInserts=true"

# Config file path
CONFIG_FILE="config/auroradsql/sample_tpcc_config.xml"

print_msg "$GREEN" "=========================================="
print_msg "$GREEN" "DSQL Distributed Benchmark Runner"
print_msg "$GREEN" "=========================================="
print_msg "$NC" ""
print_msg "$NC" "Configuration:"
print_msg "$NC" "  Cluster Endpoint: $CLUSTER_ENDPOINT"
print_msg "$NC" "  Region:           $REGION"
print_msg "$NC" "  Total Warehouses: $WAREHOUSES"
print_msg "$NC" "  Instance ID:      $INSTANCE_ID of $TOTAL_INSTANCES"
print_msg "$NC" "  Phase:            $PHASE"
print_msg "$NC" "  Start Warehouse:  $START_WAREHOUSE"
print_msg "$NC" "  Stride:           $STRIDE"
print_msg "$NC" "  Terminals:        $TERMINALS"
print_msg "$NC" "  Loader Threads:   $LOADER_THREADS"
print_msg "$NC" "  Execution Time:   ${EXECUTION_TIME}s"
print_msg "$NC" "  Warmup Time:      ${WARMUP_TIME}s"
print_msg "$NC" ""

cd "$BENCHMARK_HOME"

# Function to run benchmark with specified options
run_benchmark() {
    local create=$1
    local load=$2
    local execute=$3
    local skip_item_load=$4
    local skip_main_data_load=$5
    local clear=$6
    local extra_args="${7:-}"
    
    local cmd="java -jar benchbase.jar \
        -b tpcc \
        -c $CONFIG_FILE \
        --url \"$JDBC_URL\" \
        --region $REGION \
        --scalefactor $WAREHOUSES \
        --create $create \
        --load $load \
        --execute $execute"
    
    if [ "$skip_item_load" = "true" ]; then
        cmd="$cmd --skipItemLoad true"
    fi
    
    if [ "$skip_main_data_load" = "true" ]; then
        cmd="$cmd --skipMainDataLoad true"
    fi
    
    if [ "$clear" = "true" ]; then
        cmd="$cmd --clear true"
    else
        cmd="$cmd --clear false"
    fi
    
    if [ -n "$extra_args" ]; then
        cmd="$cmd $extra_args"
    fi
    
    log "Executing: $cmd"
    eval $cmd
}

# Phase: Initialization (Schema + Items)
# Only instance 1 runs this phase
run_init_phase() {
    if [ "$INSTANCE_ID" -eq 1 ]; then
        print_msg "$BLUE" "=========================================="
        print_msg "$BLUE" "Phase 1: Schema and Item Initialization"
        print_msg "$BLUE" "=========================================="
        log "Creating schema and loading items..."
        
        run_benchmark "true" "true" "false" "false" "true" "true"
        
        print_msg "$GREEN" "Initialization phase completed!"
        log "Schema created and items loaded successfully"
    else
        print_msg "$YELLOW" "Skipping init phase (only instance 1 runs initialization)"
    fi
}

# Phase: Distributed Data Loading
run_load_phase() {
    print_msg "$BLUE" "=========================================="
    print_msg "$BLUE" "Phase 2: Distributed Warehouse Loading"
    print_msg "$BLUE" "=========================================="
    log "Loading warehouses with stride pattern..."
    log "This instance handles warehouses: $START_WAREHOUSE, $(($START_WAREHOUSE + $STRIDE)), $(($START_WAREHOUSE + 2*$STRIDE)), ..."
    
    run_benchmark "false" "true" "false" "true" "false" "false" \
        "--startWarehouseIndex $START_WAREHOUSE \
         --endWarehouseIndex $END_WAREHOUSE \
         --stride $STRIDE \
         --loaderThreads $LOADER_THREADS"
    
    print_msg "$GREEN" "Data loading phase completed!"
    log "Warehouse data loaded successfully for instance $INSTANCE_ID"
}

# Phase: Distributed Benchmark Execution
run_execute_phase() {
    print_msg "$BLUE" "=========================================="
    print_msg "$BLUE" "Phase 3: Distributed Benchmark Execution"
    print_msg "$BLUE" "=========================================="
    log "Executing benchmark with $TERMINALS terminals..."
    log "Execution time: ${EXECUTION_TIME}s, Warmup: ${WARMUP_TIME}s"
    
    run_benchmark "false" "false" "true" "false" "false" "false" \
        "--startWarehouseIndex $START_WAREHOUSE \
         --endWarehouseIndex $END_WAREHOUSE \
         --stride $STRIDE \
         --terminals $TERMINALS \
         --time $EXECUTION_TIME \
         --warmup $WARMUP_TIME"
    
    print_msg "$GREEN" "Benchmark execution completed!"
    log "Benchmark execution finished for instance $INSTANCE_ID"
}

# Main execution based on phase
case $PHASE in
    init)
        run_init_phase
        ;;
    load)
        run_load_phase
        ;;
    execute)
        run_execute_phase
        ;;
    all)
        if [ "$INSTANCE_ID" -eq 1 ]; then
            run_init_phase
            print_msg "$NC" ""
            print_msg "$YELLOW" "Waiting 30 seconds for schema propagation before loading..."
            sleep 30
        else
            print_msg "$YELLOW" "Instance $INSTANCE_ID: Waiting for instance 1 to complete initialization..."
            print_msg "$YELLOW" "Once instance 1 reports 'Initialization phase completed!', press Enter to continue"
            read -p "Press Enter to continue with data loading..."
        fi
        
        run_load_phase
        
        print_msg "$NC" ""
        print_msg "$YELLOW" "Data loading complete. Waiting for all instances to finish loading..."
        print_msg "$YELLOW" "Once all instances report 'Data loading phase completed!', press Enter to continue"
        read -p "Press Enter to continue with benchmark execution..."
        
        run_execute_phase
        ;;
    *)
        print_msg "$RED" "Unknown phase: $PHASE"
        print_msg "$YELLOW" "Valid phases: init, load, execute, all"
        exit 1
        ;;
esac

print_msg "$NC" ""
print_msg "$GREEN" "=========================================="
print_msg "$GREEN" "Benchmark Complete!"
print_msg "$GREEN" "=========================================="
print_msg "$NC" "Results are saved in the current directory."
print_msg "$NC" "Look for files matching: results_*.csv and results_*.json"
log "All phases completed for instance $INSTANCE_ID"
