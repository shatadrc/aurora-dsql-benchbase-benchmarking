#!/bin/bash
#
# EC2 Instance Setup Script
#
# This script sets up an EC2 instance for running DSQL benchmarks.
# It can be used as user data or run manually on an existing instance.
#
# Usage:
#   ./setup-ec2-instance.sh [options]
#
# Options:
#   -i, --instance-id    Instance ID (1, 2, or 3) for distributed benchmarking
#   -t, --total          Total number of benchmark instances (default: 3)
#   -r, --region         AWS region (default: us-east-1)
#   -h, --help           Show this help message

set -e

# Default values
INSTANCE_ID=""
TOTAL_INSTANCES=3
REGION="us-east-1"
BENCHMARK_DIR="/opt/benchmark"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
        -i|--instance-id)
            INSTANCE_ID="$2"
            shift 2
            ;;
        -t|--total)
            TOTAL_INSTANCES="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
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

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_msg "$RED" "Error: This script must be run as root (use sudo)"
    exit 1
fi

log "Starting EC2 instance setup..."

# Update system packages
log "Updating system packages..."
if command -v dnf &> /dev/null; then
    dnf update -y
elif command -v yum &> /dev/null; then
    yum update -y
elif command -v apt-get &> /dev/null; then
    apt-get update && apt-get upgrade -y
fi

# Install Java 21 (Amazon Corretto)
log "Installing Java 21 (Amazon Corretto)..."
if command -v dnf &> /dev/null; then
    dnf install -y java-21-amazon-corretto-headless
elif command -v yum &> /dev/null; then
    amazon-linux-extras install java-openjdk21 -y 2>/dev/null || yum install -y java-21-amazon-corretto-headless
elif command -v apt-get &> /dev/null; then
    apt-get install -y openjdk-21-jdk-headless
fi

# Install required tools
log "Installing required tools..."
if command -v dnf &> /dev/null; then
    dnf install -y git wget curl unzip jq htop
elif command -v yum &> /dev/null; then
    yum install -y git wget curl unzip jq htop
elif command -v apt-get &> /dev/null; then
    apt-get install -y git wget curl unzip jq htop
fi

# Set JAVA_HOME
log "Configuring JAVA_HOME..."
if [ -d /usr/lib/jvm/java-21-amazon-corretto ]; then
    JAVA_HOME="/usr/lib/jvm/java-21-amazon-corretto"
elif [ -d /usr/lib/jvm/java-21-openjdk-amd64 ]; then
    JAVA_HOME="/usr/lib/jvm/java-21-openjdk-amd64"
else
    JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
fi

cat > /etc/profile.d/java.sh << EOF
export JAVA_HOME=$JAVA_HOME
export PATH=\$JAVA_HOME/bin:\$PATH
EOF

source /etc/profile.d/java.sh

# Verify Java installation
log "Verifying Java installation..."
java -version

# Create benchmark directory
log "Creating benchmark directory..."
mkdir -p "$BENCHMARK_DIR"
chown -R ec2-user:ec2-user "$BENCHMARK_DIR" 2>/dev/null || chown -R $(logname):$(logname) "$BENCHMARK_DIR"

# Clone benchbase repository
log "Cloning benchbase repository..."
cd "$BENCHMARK_DIR"
if [ -d "aurora-dsql-benchbase-benchmarking" ]; then
    log "Repository already exists, pulling latest changes..."
    cd aurora-dsql-benchbase-benchmarking
    git pull
    cd ..
else
    git clone --depth 1 https://github.com/amazon-contributing/aurora-dsql-benchbase-benchmarking.git
fi
chown -R ec2-user:ec2-user aurora-dsql-benchbase-benchmarking 2>/dev/null || true

# Build benchbase
log "Building benchbase with auroradsql profile..."
cd aurora-dsql-benchbase-benchmarking
sudo -u ec2-user ./mvnw clean package -P auroradsql -DskipTests 2>/dev/null || ./mvnw clean package -P auroradsql -DskipTests

# Extract built artifact
log "Extracting benchbase artifact..."
cd target
if [ -f "benchbase-auroradsql.tgz" ]; then
    tar xvzf benchbase-auroradsql.tgz
    chown -R ec2-user:ec2-user benchbase-auroradsql 2>/dev/null || true
else
    print_msg "$RED" "Error: benchbase-auroradsql.tgz not found. Build may have failed."
    exit 1
fi

# Create environment variables file
log "Creating environment configuration..."
cat > "$BENCHMARK_DIR/benchmark-env.sh" << EOF
# DSQL Benchmark Environment Configuration
export JAVA_HOME=$JAVA_HOME
export PATH=\$JAVA_HOME/bin:\$PATH
export BENCHMARK_HOME=$BENCHMARK_DIR/aurora-dsql-benchbase-benchmarking/target/benchbase-auroradsql
export AWS_DEFAULT_REGION=$REGION

# Instance configuration for distributed benchmarking
export INSTANCE_ID=${INSTANCE_ID:-1}
export TOTAL_INSTANCES=$TOTAL_INSTANCES

# Source this file before running benchmarks:
# source /opt/benchmark/benchmark-env.sh
EOF

# Copy benchmark runner script
log "Setting up benchmark runner scripts..."
if [ -f "$BENCHMARK_DIR/aurora-dsql-benchbase-benchmarking/infrastructure/scripts/run-distributed-benchmark.sh" ]; then
    cp "$BENCHMARK_DIR/aurora-dsql-benchbase-benchmarking/infrastructure/scripts/run-distributed-benchmark.sh" "$BENCHMARK_DIR/"
    chmod +x "$BENCHMARK_DIR/run-distributed-benchmark.sh"
fi

# Set ownership
chown -R ec2-user:ec2-user "$BENCHMARK_DIR" 2>/dev/null || true

print_msg "$GREEN" ""
print_msg "$GREEN" "=========================================="
print_msg "$GREEN" "EC2 Instance Setup Complete!"
print_msg "$GREEN" "=========================================="
print_msg "$NC" ""
print_msg "$NC" "Benchbase has been installed to:"
print_msg "$NC" "  $BENCHMARK_DIR/aurora-dsql-benchbase-benchmarking/target/benchbase-auroradsql"
print_msg "$NC" ""
print_msg "$NC" "To run benchmarks:"
print_msg "$NC" "  1. Source the environment: source $BENCHMARK_DIR/benchmark-env.sh"
print_msg "$NC" "  2. Run the benchmark script: $BENCHMARK_DIR/run-distributed-benchmark.sh -c <cluster-endpoint>"
print_msg "$NC" ""
print_msg "$NC" "Java version: $(java -version 2>&1 | head -1)"
log "Setup completed successfully!"
