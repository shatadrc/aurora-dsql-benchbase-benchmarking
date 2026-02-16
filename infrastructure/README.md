# DSQL Benchmarking Infrastructure

This directory contains CloudFormation templates and scripts to deploy and run TPC-C benchmarks against Aurora DSQL using a distributed multi-instance setup.

## Architecture Overview

The infrastructure creates:

- **VPC**: A new VPC in us-east-1 with 3 public subnets (one per AZ)
- **Security Groups**: Configured for SSH access and DSQL connectivity
- **IAM**: Role and instance profile with DSQL permissions
- **Aurora DSQL Cluster**: Benchmark target database
- **EC2 Instances**: 3 x c5.2xlarge instances for distributed benchmark execution

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           VPC (10.0.0.0/16)                              │
│                                                                          │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐                │
│  │ us-east-1a   │   │ us-east-1b   │   │ us-east-1c   │                │
│  │ 10.0.1.0/24  │   │ 10.0.2.0/24  │   │ 10.0.3.0/24  │                │
│  │              │   │              │   │              │                │
│  │ ┌──────────┐ │   │ ┌──────────┐ │   │ ┌──────────┐ │                │
│  │ │Instance 1│ │   │ │Instance 2│ │   │ │Instance 3│ │                │
│  │ │c5.2xlarge│ │   │ │c5.2xlarge│ │   │ │c5.2xlarge│ │                │
│  │ └────┬─────┘ │   │ └────┬─────┘ │   │ └────┬─────┘ │                │
│  └──────┼───────┘   └──────┼───────┘   └──────┼───────┘                │
│         │                  │                  │                         │
│         └──────────────────┼──────────────────┘                         │
│                            │                                            │
│                            ▼                                            │
│                  ┌─────────────────┐                                    │
│                  │  Aurora DSQL    │                                    │
│                  │    Cluster      │                                    │
│                  └─────────────────┘                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

1. AWS CLI configured with appropriate credentials
2. An EC2 key pair in us-east-1 region
3. Sufficient AWS quotas for:
   - VPC
   - 3 x c5.2xlarge instances
   - Aurora DSQL cluster

### GitHub Actions Workflow (Recommended)

The easiest way to deploy and run benchmarks is using the GitHub Actions workflow.

#### Required GitHub Secrets

Configure the following secrets in your repository (Settings > Secrets and variables > Actions):

| Secret Name | Description | Example |
|-------------|-------------|---------|
| `AWS_ACCESS_KEY_ID` | AWS access key with CloudFormation, EC2, DSQL, and S3 permissions | `AKIAIOSFODNN7EXAMPLE` |
| `AWS_SECRET_ACCESS_KEY` | AWS secret access key | `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` |
| `AWS_REGION` | AWS region for deployment (optional, defaults to us-east-1) | `us-east-1` |
| `EC2_KEY_PAIR_NAME` | Name of existing EC2 key pair in the target region | `my-benchmark-keypair` |
| `SSH_PRIVATE_KEY` | Private key content for SSH access to EC2 instances | `-----BEGIN RSA PRIVATE KEY-----...` |

#### Triggering the Workflow

1. Go to **Actions** tab in your repository
2. Select **Deploy and Benchmark DSQL** workflow
3. Click **Run workflow**
4. Configure the parameters:
   - **Environment name**: Prefix for AWS resources (default: `dsql-benchmark`)
   - **Warehouse count**: Number of TPC-C warehouses (default: `20`)
   - **Cleanup after**: Whether to tear down infrastructure after benchmark
   - **Execution time**: Benchmark duration in seconds (default: `3600`)
   - **Warmup time**: Warmup period in seconds (default: `600`)
5. Click **Run workflow**

#### Workflow Jobs

The workflow consists of four jobs:

1. **Deploy Infrastructure**: Creates VPC, Security Groups, IAM, DSQL cluster, and EC2 instances
2. **Execute Benchmark**: Initializes schema, loads data, and runs distributed TPC-C benchmark
3. **Collect Results**: Gathers results from all instances and generates summary report
4. **Cleanup (Optional)**: Tears down all infrastructure if `cleanup_after` is enabled

#### Accessing Results

Benchmark results are uploaded as workflow artifacts and can be downloaded from the workflow run page.

### Manual Deployment

If you prefer to deploy manually, use the scripts below.

### Deploy Infrastructure

```bash
cd infrastructure/scripts

# Deploy the complete infrastructure
./deploy-infrastructure.sh \
  --key-pair your-key-pair-name \
  --ssh-cidr "YOUR_IP/32"  # Restrict SSH access to your IP
```

This will create:
- VPC with 3 public subnets
- Security groups
- IAM role and instance profile
- Aurora DSQL cluster
- 3 EC2 instances (with benchbase pre-installed)

### Run Distributed Benchmark

After infrastructure deployment, you can run benchmarks in two ways:

#### Option 1: Automated Coordination (from control machine)

```bash
./coordinate-benchmark.sh \
  --cluster-endpoint YOUR_CLUSTER.dsql.us-east-1.on.aws \
  --instance1 INSTANCE1_PUBLIC_IP \
  --instance2 INSTANCE2_PUBLIC_IP \
  --instance3 INSTANCE3_PUBLIC_IP \
  --key-file ~/.ssh/your-key.pem \
  --warehouses 20
```

#### Option 2: Manual Execution (on each instance)

SSH into each instance and run phases manually:

```bash
# On Instance 1 only - Initialize schema
source /opt/benchmark/benchmark-env.sh
./run-distributed-benchmark.sh -c YOUR_CLUSTER.dsql.us-east-1.on.aws -i 1 -p init

# On all instances - Load data in parallel
./run-distributed-benchmark.sh -c YOUR_CLUSTER.dsql.us-east-1.on.aws -i 1 -p load  # Instance 1
./run-distributed-benchmark.sh -c YOUR_CLUSTER.dsql.us-east-1.on.aws -i 2 -p load  # Instance 2
./run-distributed-benchmark.sh -c YOUR_CLUSTER.dsql.us-east-1.on.aws -i 3 -p load  # Instance 3

# On all instances - Execute benchmark in parallel
./run-distributed-benchmark.sh -c YOUR_CLUSTER.dsql.us-east-1.on.aws -i 1 -p execute
./run-distributed-benchmark.sh -c YOUR_CLUSTER.dsql.us-east-1.on.aws -i 2 -p execute
./run-distributed-benchmark.sh -c YOUR_CLUSTER.dsql.us-east-1.on.aws -i 3 -p execute
```

### Delete Infrastructure

```bash
./deploy-infrastructure.sh --delete
```

## Directory Structure

```
infrastructure/
├── cloudformation/
│   ├── vpc.yaml              # VPC, subnets, IGW, route tables
│   ├── security-groups.yaml  # Security groups for SSH and DSQL
│   ├── iam.yaml              # IAM role and instance profile
│   ├── dsql.yaml             # Aurora DSQL cluster
│   ├── ec2.yaml              # EC2 benchmark instances
│   └── main.yaml             # Nested stack orchestrator
├── scripts/
│   ├── deploy-infrastructure.sh    # Deployment script
│   ├── run-distributed-benchmark.sh # Per-instance benchmark runner
│   ├── coordinate-benchmark.sh      # Multi-instance coordinator
│   └── setup-ec2-instance.sh        # Manual instance setup
└── README.md                        # This file
```

## CloudFormation Templates

### vpc.yaml
Creates the network infrastructure:
- VPC with DNS support
- 3 public subnets across AZs
- Internet Gateway
- Route tables with default route

### security-groups.yaml
Creates security groups:
- SSH access (port 22) from specified CIDR
- Inter-instance communication
- Outbound internet access for DSQL connectivity

### iam.yaml
Creates IAM resources:
- IAM role with DSQL full access
- CloudWatch metrics permissions
- S3 access for results storage
- Instance profile for EC2 attachment

### dsql.yaml
Creates Aurora DSQL cluster:
- Single-region cluster in us-east-1
- Configurable deletion protection

### ec2.yaml
Creates EC2 instances:
- 3 x c5.2xlarge instances (one per AZ)
- Amazon Linux 2023 with Java 21
- Automated benchbase installation via user data
- Pre-configured environment variables

### main.yaml
Orchestrates nested stack deployment for use with S3-hosted templates.

## Benchmark Configuration

The default configuration (`config/auroradsql/sample_tpcc_config.xml`) is set for:
- **20 warehouses** (scale factor)
- **20 terminals**
- **2 hours** execution time (7200 seconds)
- **30 minutes** warmup (1800 seconds)

Adjust parameters in `run-distributed-benchmark.sh`:
```bash
./run-distributed-benchmark.sh \
  -c YOUR_CLUSTER.dsql.us-east-1.on.aws \
  -w 100 \           # 100 warehouses
  --time 7200 \      # 2 hour execution
  --warmup 1800      # 30 min warmup
```

## Distributed Execution Strategy

The benchmark uses a stride-based distribution pattern:

| Instance | Start | Stride | Warehouses Handled |
|----------|-------|--------|-------------------|
| 1 | 1 | 3 | 1, 4, 7, 10, 13, 16, 19 |
| 2 | 2 | 3 | 2, 5, 8, 11, 14, 17, 20 |
| 3 | 3 | 3 | 3, 6, 9, 12, 15, 18 |

This ensures:
- Even distribution across AZs
- No warehouse overlap
- Balanced load per instance

## Result Aggregation

Each instance produces separate result files. To calculate total cluster performance:

```
Total TPS = Instance1_TPS + Instance2_TPS + Instance3_TPS
```

Results are saved to each instance at:
```
/opt/benchmark/aurora-dsql-benchbase-benchmarking/target/benchbase-auroradsql/results_*.csv
```

## Troubleshooting

### Instance Setup Not Complete
Check user data execution:
```bash
ssh -i key.pem ec2-user@INSTANCE_IP 'tail -f /var/log/user-data.log'
```

### Cannot Connect to DSQL
1. Verify security group allows outbound HTTPS (port 443)
2. Check IAM role has DSQL permissions
3. Verify cluster endpoint is correct

### Benchmark Fails During Loading
1. Check CloudWatch logs for DSQL errors
2. Reduce `--loader-threads` if seeing connection issues
3. Increase retries in config XML

## Cost Considerations

Approximate hourly costs (us-east-1):
- 3 x c5.2xlarge: ~$1.02/hour
- Aurora DSQL: Pay per request
- Data transfer: Variable

Remember to delete resources when done:
```bash
./deploy-infrastructure.sh --delete
```
