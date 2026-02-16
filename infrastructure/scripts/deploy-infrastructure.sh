#!/bin/bash
#
# Deploy DSQL Benchmarking Infrastructure
#
# This script deploys the complete infrastructure stack including:
# - VPC with 3 public subnets across AZs
# - Security groups for SSH and DSQL connectivity
# - IAM role and instance profile with DSQL permissions
# - Aurora DSQL cluster
# - 3 x c5.2xlarge EC2 instances for distributed benchmarking
#
# Usage:
#   ./deploy-infrastructure.sh [options]
#
# Options:
#   -e, --environment    Environment name prefix (default: dsql-benchmark)
#   -k, --key-pair       EC2 key pair name (required)
#   -s, --ssh-cidr       CIDR block for SSH access (default: 0.0.0.0/0)
#   -i, --instance-type  EC2 instance type (default: c5.2xlarge)
#   -r, --region         AWS region (default: us-east-1)
#   -b, --bucket         S3 bucket for templates (required for nested stacks)
#   -d, --delete         Delete the stack instead of creating
#   -h, --help           Show this help message

set -e

# Default values
ENVIRONMENT_NAME="dsql-benchmark"
KEY_PAIR_NAME=""
SSH_CIDR="0.0.0.0/0"
INSTANCE_TYPE="c5.2xlarge"
REGION="us-east-1"
TEMPLATES_BUCKET=""
DELETE_STACK=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_DIR="${SCRIPT_DIR}/../cloudformation"

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

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--environment)
            ENVIRONMENT_NAME="$2"
            shift 2
            ;;
        -k|--key-pair)
            KEY_PAIR_NAME="$2"
            shift 2
            ;;
        -s|--ssh-cidr)
            SSH_CIDR="$2"
            shift 2
            ;;
        -i|--instance-type)
            INSTANCE_TYPE="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -b|--bucket)
            TEMPLATES_BUCKET="$2"
            shift 2
            ;;
        -d|--delete)
            DELETE_STACK=true
            shift
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

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    print_msg "$RED" "Error: AWS CLI is not installed"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    print_msg "$RED" "Error: AWS credentials not configured"
    exit 1
fi

# Delete stack if requested
if [ "$DELETE_STACK" = true ]; then
    print_msg "$YELLOW" "Deleting infrastructure stacks..."
    
    # Delete in reverse order of dependencies
    for stack in ec2 dsql security-groups iam vpc; do
        stack_name="${ENVIRONMENT_NAME}-${stack}"
        if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" &> /dev/null; then
            print_msg "$YELLOW" "Deleting stack: $stack_name"
            aws cloudformation delete-stack --stack-name "$stack_name" --region "$REGION"
            aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$REGION"
            print_msg "$GREEN" "Deleted: $stack_name"
        fi
    done
    
    print_msg "$GREEN" "All stacks deleted successfully!"
    exit 0
fi

# Validate required parameters
if [ -z "$KEY_PAIR_NAME" ]; then
    print_msg "$RED" "Error: EC2 key pair name is required (-k, --key-pair)"
    exit 1
fi

# Verify key pair exists
if ! aws ec2 describe-key-pairs --key-names "$KEY_PAIR_NAME" --region "$REGION" &> /dev/null; then
    print_msg "$RED" "Error: Key pair '$KEY_PAIR_NAME' not found in region $REGION"
    exit 1
fi

print_msg "$GREEN" "=========================================="
print_msg "$GREEN" "DSQL Benchmarking Infrastructure Deployment"
print_msg "$GREEN" "=========================================="
print_msg "$NC" ""
print_msg "$NC" "Configuration:"
print_msg "$NC" "  Environment:    $ENVIRONMENT_NAME"
print_msg "$NC" "  Region:         $REGION"
print_msg "$NC" "  Key Pair:       $KEY_PAIR_NAME"
print_msg "$NC" "  Instance Type:  $INSTANCE_TYPE"
print_msg "$NC" "  SSH CIDR:       $SSH_CIDR"
print_msg "$NC" ""

# Function to deploy a stack
deploy_stack() {
    local stack_name=$1
    local template_file=$2
    local parameters=$3
    
    print_msg "$YELLOW" "Deploying stack: $stack_name"
    
    if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" &> /dev/null; then
        # Stack exists, update it
        print_msg "$NC" "  Stack exists, updating..."
        aws cloudformation update-stack \
            --stack-name "$stack_name" \
            --template-body "file://${template_file}" \
            --parameters $parameters \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$REGION" 2>/dev/null || {
                if [[ $? -eq 255 ]]; then
                    print_msg "$NC" "  No updates to be performed"
                    return 0
                fi
            }
        aws cloudformation wait stack-update-complete --stack-name "$stack_name" --region "$REGION"
    else
        # Create new stack
        print_msg "$NC" "  Creating new stack..."
        aws cloudformation create-stack \
            --stack-name "$stack_name" \
            --template-body "file://${template_file}" \
            --parameters $parameters \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$REGION"
        aws cloudformation wait stack-create-complete --stack-name "$stack_name" --region "$REGION"
    fi
    
    print_msg "$GREEN" "  Stack deployed: $stack_name"
}

# Deploy VPC
deploy_stack "${ENVIRONMENT_NAME}-vpc" \
    "${CF_DIR}/vpc.yaml" \
    "ParameterKey=EnvironmentName,ParameterValue=${ENVIRONMENT_NAME}"

# Deploy Security Groups
deploy_stack "${ENVIRONMENT_NAME}-security-groups" \
    "${CF_DIR}/security-groups.yaml" \
    "ParameterKey=EnvironmentName,ParameterValue=${ENVIRONMENT_NAME} ParameterKey=SSHSourceCIDR,ParameterValue=${SSH_CIDR}"

# Deploy IAM
deploy_stack "${ENVIRONMENT_NAME}-iam" \
    "${CF_DIR}/iam.yaml" \
    "ParameterKey=EnvironmentName,ParameterValue=${ENVIRONMENT_NAME}"

# Deploy DSQL Cluster
deploy_stack "${ENVIRONMENT_NAME}-dsql" \
    "${CF_DIR}/dsql.yaml" \
    "ParameterKey=EnvironmentName,ParameterValue=${ENVIRONMENT_NAME}"

# Deploy EC2 Instances
deploy_stack "${ENVIRONMENT_NAME}-ec2" \
    "${CF_DIR}/ec2.yaml" \
    "ParameterKey=EnvironmentName,ParameterValue=${ENVIRONMENT_NAME} ParameterKey=InstanceType,ParameterValue=${INSTANCE_TYPE} ParameterKey=KeyPairName,ParameterValue=${KEY_PAIR_NAME}"

print_msg "$GREEN" ""
print_msg "$GREEN" "=========================================="
print_msg "$GREEN" "Infrastructure Deployment Complete!"
print_msg "$GREEN" "=========================================="
print_msg "$NC" ""

# Get outputs
DSQL_ENDPOINT=$(aws cloudformation describe-stacks --stack-name "${ENVIRONMENT_NAME}-dsql" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`DSQLClusterEndpoint`].OutputValue' --output text)

INSTANCE1_IP=$(aws cloudformation describe-stacks --stack-name "${ENVIRONMENT_NAME}-ec2" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`BenchmarkInstance1PublicIp`].OutputValue' --output text)

INSTANCE2_IP=$(aws cloudformation describe-stacks --stack-name "${ENVIRONMENT_NAME}-ec2" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`BenchmarkInstance2PublicIp`].OutputValue' --output text)

INSTANCE3_IP=$(aws cloudformation describe-stacks --stack-name "${ENVIRONMENT_NAME}-ec2" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`BenchmarkInstance3PublicIp`].OutputValue' --output text)

print_msg "$NC" "DSQL Cluster Endpoint:"
print_msg "$GREEN" "  $DSQL_ENDPOINT"
print_msg "$NC" ""
print_msg "$NC" "EC2 Instance IPs:"
print_msg "$NC" "  Instance 1 (us-east-1a): $INSTANCE1_IP"
print_msg "$NC" "  Instance 2 (us-east-1b): $INSTANCE2_IP"
print_msg "$NC" "  Instance 3 (us-east-1c): $INSTANCE3_IP"
print_msg "$NC" ""
print_msg "$NC" "SSH Commands:"
print_msg "$NC" "  ssh -i ${KEY_PAIR_NAME}.pem ec2-user@${INSTANCE1_IP}"
print_msg "$NC" "  ssh -i ${KEY_PAIR_NAME}.pem ec2-user@${INSTANCE2_IP}"
print_msg "$NC" "  ssh -i ${KEY_PAIR_NAME}.pem ec2-user@${INSTANCE3_IP}"
print_msg "$NC" ""
print_msg "$NC" "Next Steps:"
print_msg "$NC" "  1. Wait for EC2 instances to complete initialization (check /var/log/user-data.log)"
print_msg "$NC" "  2. Copy run-distributed-benchmark.sh to each instance"
print_msg "$NC" "  3. Run the benchmark using the distributed benchmark script"
print_msg "$NC" ""
print_msg "$YELLOW" "Note: EC2 instances are building benchbase. This may take 5-10 minutes."
print_msg "$YELLOW" "Check progress with: ssh -i ${KEY_PAIR_NAME}.pem ec2-user@<IP> 'tail -f /var/log/user-data.log'"
