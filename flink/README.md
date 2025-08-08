# Apache Flink Applications for Blockchain Data Processing

This directory contains Apache Flink applications that process blockchain data from Kafka and transform it into structured formats for analysis and querying. The applications are designed to run on [Amazon Managed Service for Apache Flink](https://aws.amazon.com/managed-service-apache-flink/).

## Project Structure

The Flink directory contains multiple Flink applications, each designed to process specific blockchain data:

```
├── punktransfers/             # Application for processing CryptoPunks NFT transfers
├── uniswapv2-usdc-eth/        # Application for processing Uniswap V2 USDC-ETH swaps
├── ROTATION_SUMMARY.md        # Documentation for database credential rotation
└── SECRETS_SETUP.md           # Documentation for setting up secrets management
```

## Prerequisites

Before building and deploying the Flink applications, ensure you have:

1. Java Development Kit (JDK) 11 or later
2. Apache Maven
3. AWS account with access to Amazon Managed Service for Apache Flink
4. The infrastructure stack deployed (from the `infra/` directory)
5. The Kafka emitter running and publishing data to MSK (from the `kafka-emitter-exex/` directory)

## Building the Applications

Each Flink application can be built separately using Maven:

### PunkTransfers Application

```bash
cd flink/punktransfers/
mvn clean package
```

This will create a JAR file in the `target/` directory.

### Uniswap V2 USDC-ETH Application

```bash
cd flink/uniswapv2-usdc-eth/
mvn clean package
```

## Deploying to Amazon Managed Service for Apache Flink

To deploy a Flink application:

1. Upload the JAR file to an S3 bucket:

```bash
aws s3 cp target/punktransfers-1.0-SNAPSHOT.jar s3://your-bucket/flink-apps/
```

2. Create a new Flink application in the AWS Management Console or using the AWS CLI:

```bash
aws kinesisanalyticsv2 create-application \
  --application-name punktransfers \
  --runtime-environment FLINK-1.20 \
  --service-execution-role arn:aws:iam::your-account-id:role/flink-execution-role \
  --application-configuration file://app-config.json
```

3. Start the application:

```bash
aws kinesisanalyticsv2 start-application \
  --application-name punktransfers \
  --run-configuration file://run-config.json
```

## Application Details

### PunkTransfers

This application processes [CryptoPunks](https://cryptopunks.app/) transfer events from the blockchain. CryptoPunks are NFTs, but they pre-date the ERC-721 standard. That's why we cannot use ERC-721 events directly.

- **Input**: Event logs from the Kafka topic
- **Processing**: Filters for CryptoPunks transfer events and extracts relevant data
- **Output**: Writes structured transfer data to an Amazon RDS database

For more information on the filtering and transformations refer to the [PunkTransfers README](./punktransfers/README.md).

### Uniswap V2 USDC-ETH

This application processes Uniswap V2 swap events for the USDC-ETH pair:

- **Input**: Event logs and transaction data from Kafka topics
- **Processing**: Filters for swap events and calculates price information
- **Output**: Writes price and volume data to an Amazon RDS database

## Configuration

The Flink applications use the following configuration mechanisms:

1. **Application Properties**: Set via the Flink application configuration
2. **AWS Secrets Manager**: For database credentials and sensitive information
3. **Environment Variables**: For runtime configuration

For more information on the filtering and transformations refer to the [Uniswap V2 USDC/ETH README](./uniswapv2-usdc-eth/README.md).


## Monitoring and Troubleshooting

The Flink applications log to CloudWatch Logs. You can monitor the applications:

1. In the Amazon Managed Service for Apache Flink console
2. Through CloudWatch Logs
3. Using CloudWatch Metrics for performance monitoring

For database credential rotation information, see `ROTATION_SUMMARY.md`.
