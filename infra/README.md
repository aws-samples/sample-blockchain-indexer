# Infrastructure for Blockchain Indexer

This directory contains the AWS Cloud Development Kit (CDK) code for deploying the infrastructure required by the blockchain indexer. The main stack is the `Indexer` stack, which provisions all the necessary AWS resources.

## Prerequisites

Before deploying the infrastructure, ensure you have:

1. AWS CLI installed and configured with appropriate credentials
2. Node.js (v14 or later) and npm installed
3. AWS CDK v2 installed globally (`npm install -g aws-cdk`)

## What Gets Deployed

The `Indexer` stack deploys the following AWS resources:

1. **Amazon MSK (Managed Streaming for Apache Kafka)** – A Kafka cluster for storing blockchain data
   - Uses `m7g.xlarge` instances with tiered storage
   - Configured with TLS encryption and IAM authentication
   - Restricted to VPC access

2. **Blockchain Nodes** - EC2 instances running reth nodes for different networks:
   - Holesky node on an `i8g.2xlarge` instance with 1875 GB instance storage and 2048 GB EBS storage
   - Mainnet node on an `i8g.4xlarge` instance storage with 3750 GB instance storage and 10 TB EBS storage

3. **S3 Buckets** – For data storage:
   - Error bucket for failed records
   - Iceberg tables bucket for structured data
   - S3 Tables bucket for data delivery

4. **IAM Roles and Policies** – For secure access between components:
   - Firehose delivery role
   - Kafka access policies
   - Glue catalog access

## Deployment Steps

Follow these steps to deploy the infrastructure:

### 1. Install Dependencies

```bash
cd infra/
npm install
```

### 2. Deploy the Stack

```bash
cdk deploy Indexer
```

This will deploy the `Indexer` stack to your default AWS account and region. The deployment process will output important information such as:

- Kafka cluster ARN and name
- VPC ID
- EC2 instance IDs for the blockchain nodes

### 4. (Optional) Destroy the Stack

If you need to tear down the infrastructure:

```bash
cdk destroy Indexer
```

## Configuration

The main configuration for the infrastructure is in `lib/indexer-stack.ts`. You can modify this file to adjust:

- Instance types for the Kafka cluster and blockchain nodes
- Storage sizes
- Network configurations
- IAM policies

## Outputs

After deployment, the CDK will output several important values:

- `KafkaVpc` - The VPC ID where resources are deployed
- `KafkaClusterArn` - The ARN of the MSK cluster
- `KafkaClusterName` - The name of the MSK cluster
- `HoleskyNode` - The instance ID of the Holesky node
- `SepoliaNode` - The instance ID of the Sepolia node
- `MainnetNode` - The instance ID of the Mainnet node

These outputs are useful for configuring the Kafka emitter and Flink application.

## Running a Blockchain Node

After deploying the infrastructure, you need to set up and run the blockchain node on the EC2 instance. Follow these steps:

### 1. Connect to the EC2 Instance

Use AWS Systems Manager Session Manager to connect to the instance:

```bash
aws ssm start-session --target <instance-id>
```

Replace `<instance-id>` with the appropriate instance ID from the CDK outputs (HoleskyNode or MainnetNode).

### 2. Switch to the Blockchain User

```bash
sudo su blockchain
```

This user has the `KAFKA_BROKER` environment variable already set to the correct MSK endpoint and has the necessary software downloaded.

### 3. Install Rust and Required Tools

```bash
# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# Build reth (execution client)
cd /home/blockchain/reth
make install

# Build cryo (data extraction tool)
cd /home/blockchain/cryo
cargo install --path ./crates/cli

# Install jaq (JSON processor)
cd /home/blockchain
cargo install --locked jaq
```

### 4. Run the Blockchain Node

The blockchain node requires two clients: `lighthouse` (consensus client) and `reth` (execution client). Use `screen` to keep them running after logging out:

#### Create Screen Sessions

```bash
# Create a screen session for reth
screen -S reth

# Inside the reth screen session, run:
reth node \
   --authrpc.jwtsecret /data/jwttoken/jwt.hex \
   --datadir /data/mainnet/reth \
   --http
```

Press `Ctrl` + `A`, `D` to detach from the screen session.

```bash
# Create a screen session for lighthouse
screen -S lighthouse

# Inside the lighthouse screen session, run:
lighthouse \
   --datadir /data/mainnet/lighthouse \
   bn \
   --network mainnet \
   --checkpoint-sync-url https://beaconstate-mainnet.chainsafe.io \
   --execution-endpoint http://localhost:8551 \
   --execution-jwt /data/jwttoken/jwt.hex \
   --disable-deposit-contract-sync
```

Press `Ctrl` + `A`, `D` to detach from the screen session.

### 5. Monitoring the Node

To check on the running processes:

```bash
# Reattach to the reth screen
screen -r reth

# Reattach to the lighthouse screen
screen -r lighthouse
```

Check the reth process to see if it has caught up to the chain tip. (Note: If you haven't used a snapshot, this can take several days on mainnet). Once the node is fully synchronized, you can start the backfilling process.

### 6. Publish Last Block Metric to CloudWatch

The EC2 instance also has a service that publishes the node's lastest block as a metric to [Amazon CloudWatch](https://aws.amazon.com/cloudwatch). To enable the service run the following commands on the console once `reth` is running. The command must be run as root user so you'll have to log out from the blockchain user and run them:

```shell
# Change back to your login user (alternatively press Ctrl+D)
exit

# Enable servie and start timer
sudo systemctl enable lastBlock.service
sudo systemctl start lastBlock.timer
```

This will publish the last block every minute to CloudWatch.

## Extract Blockchain Data for Backfilling to Kafka

After your blockchain node is fully synchronized, you can use cryo to extract historical blockchain data and feed it into Kafka. This process involves two main steps: extracting the data with cryo and then ingesting it into Kafka.

### 1. Extract Historical Data with Cryo

Create a new screen session for the extraction process:

```bash
# Create a screen session for extraction
screen -S extract

# Change to the home directory
cd /home/blockchain

# Run the extraction script
./extract.sh -f 0 -t <last-block-number>
```

Replace `<last-block-number>` with the block number you want to extract up to. For example, to extract the first 1 million blocks, use `-t 1000000`. This would then extract block 0-999999.

The extraction script will use cryo to pull blocks, transactions, and logs from the blockchain node and store them in the local filesystem. This process can take several hours to days depending on the range of blocks you're extracting.

You can monitor the progress in the screen session. Press `Ctrl+A`, then `D` to detach from the screen session while keeping it running.

To check on the extraction progress later:

```bash
screen -r extract
```

### 2. Ingest Extracted Data into Kafka

Once the extraction is complete, you can feed the data into Kafka using the provided ingestion scripts. These scripts will process the extracted data and publish it to the appropriate Kafka topics.

Run the following commands to start the ingestion process for blocks, transactions, and logs in parallel:

```bash
# Change to the home directory
cd /home/blockchain

# Start ingestion processes for all datasets in parallel
DATASETS="blocks transactions logs"
for DATASET in ${DATASETS}; do
   nohup ./scripts/ingest.sh -d ${DATASET} > ingest_${DATASET}.log 2>&1 &
done
```

This will start three background processes, one for each data type (blocks, transactions, and logs). The output of each process will be logged to separate files (`ingest_blocks.log`, `ingest_transactions.log`, and `ingest_logs.log`).

> [!NOTE]
> The ingestion script uses [jaq](https://github.com/01mf02/jaq) to pre-process the JSON files. `jaq` is a re-implementation of `jq` in rust. We use it here to transform the regular JSON array that `cryo` writes into [newline delimited JSON (NDJSON)](https://github.com/ndjson/ndjson-spec), which has one JSON object per line.
>
> We feed that into the Kafka producer on the command line. If you don't want to use `jaq` you can replace the jaq command with the same jq command in the `ingest.sh` shell script.

You can monitor the progress of the ingestion by checking these log files:

```bash
# Monitor ingestion logs
tail -f ingest_blocks.log
tail -f ingest_transactions.log
tail -f ingest_logs.log
```

The ingestion process will read the extracted data files and publish them to the corresponding Kafka topics. This process can also take several hours depending on the amount of data.

### 3. Publish Kafka Last Block Metric to CloudWatch

The EC2 instance has a service that can publish the latest block numbers on the Kafka topics to CloudWatch. Once you've started the ingestion process you can set it up. These commands have to run as a root user, so you'll have to log out of the blockchain user first:

```bash
# Change back to your login user (alternatively press Ctrl+D)
exit

# Enable servie and start timer
sudo systemctl enable monitorKafka.service
sudo systemctl start monitorKafka.timer
```
The service will query the three Kafka topics and publish their latest blocks to CloudWatch every minute.

## Setting Up the Kafka Emitter for Real-time Data

Once the node is running and historical data has been backfilled, you can set up the Kafka emitter to extract real-time data from the blockchain. The Kafka emitter is a reth execution extension (ExEx) that captures new blocks as they arrive and publishes them to Kafka.

See the [kafka-emitter-exex README](../kafka-emitter-exex/README.md) for detailed instructions on building and running the Kafka emitter.
