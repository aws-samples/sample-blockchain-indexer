# Kafka Emitter Execution Extension (ExEx)

This directory contains a reth execution extension (ExEx) that extracts blockchain data and publishes it to Amazon MSK (Managed Streaming for Apache Kafka). The extension is compiled into the reth node directly. It captures block data in real-time, and sends it to Kafka topics for further processing.

## Prerequisites

Before building and running the Kafka emitter, ensure you have:

1. Rust toolchain installed (rustc, cargo)
2. AWS credentials configured with access to the MSK cluster
3. A running reth node
4. The MSK cluster deployed via the infrastructure stack

## Building the Emitter

To build the Kafka emitter:

```bash
cd kafka-emitter-exex/
cargo build --release
```

This will create the executable in `target/release/kafka-emitter`.

## Configuration

The Kafka emitter can be configured using environment variables and command-line arguments:

1. Environment variables

```
KAFKA_BROKER=<bootstrap-servers>  # From MSK cluster output
```

> [!TIP]
> The `KAFKA_BROKER` environment variable is automatically set for the `blockchain` user. You don't have to set anything here.

2. Command-line arguments:

```
--exex-topic-prefix <prefix>  # (optional) Prefix for Kafka topics, default: name of chain (sepolia, holesky, etc)
--exex-start-block <number>   # (optional) Block number to start processing from, default: not set (start where previously left off).
```

The `--exex-topic-prefix` gets the value from the node. Only on mainnet it needs to be specified, because cryo's and reth's naming differ: cryo stores them as 'ethereum', reth resolves the chain as `mainnet`.

> [!IMPORTANT]
> For mainnet use `--exex-topic-prefix ethereum` to match cryo's naming scheme.

## Running the Emitter

To run the Kafka emitter as a reth execution extension, you have to stop the running reth node, stop it and run the new kafka-emitter exex instead:

```bash
# Reattach to the reth screen
screen -r reth
```

Press `Ctrl` + `D` to stop the reth node

```bash
# Run the exex instead
cargo run --bin kafka-emitter \
    -- node \
    --authrpc.jwtsecret /data/jwttoken/jwt.hex \
    --chain mainnet \
    --datadir /data/mainnet/reth \
    --http \
    --exex-start-block <MAX BLOCK FROM EXTRACTION>
```

This will start a Kafka node with the exex. The extension will start from the given block number. Use the same number that you specified for block extraction.

Press `Ctrl` + `A`, `D` to detach the screen session.

> [!Note]
> If you started cryo to extract up to block `n`, its last extracted block is `n-1`. Starting the extension with `--exex-start-block n` does the right thing then--it starts extracting at block `n`, which is the first block that cryo didn't process.

The emitter will connect to the MSK cluster using IAM authentication and start publishing blockchain data to the following topics:

   - `{prefix}-blocks` - Block headers and metadata
   - `{prefix}-transactions` - Transaction data
   - `{prefix}-logs` - Event logs from transactions

## Data Format

The emitter transforms blockchain data into JSON format to match the format that the cryo extraction generated before publishing to Kafka:

- **Blocks**: Contains block header information, timestamp, gas used, etc.
- **Transactions**: Contains transaction details, sender, receiver, value, etc.
- **Logs**: Contains event logs emitted during transaction execution

## Troubleshooting

If you encounter issues:

1. Check AWS credentials and permissions
2. Verify the MSK cluster is accessible from your network
3. Ensure the reth node is running and synced
4. Check the logs for any error messages

## Development

The main components of the Kafka emitter are:

- `src/bin/kafka-emitter.rs` - Main entry point and Kafka producer logic
- `src/transform.rs` - Transforms blockchain data into serializable formats
- `src/lib.rs` - Common utilities and types

## Setting Up Apache Flink for Transformations

The exex published all block, transaction and log data to the three topics and doesn't filter or transform the data. For transformations we can use Apache Flink.

See the [Apache Flink README](../flink/README.md) for detailed instructions on setting up consumers of the blockchain data.
