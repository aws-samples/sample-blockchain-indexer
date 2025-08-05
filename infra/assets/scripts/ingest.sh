#!/bin/bash

# © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
# This AWS Content is provided subject to the terms of the AWS Customer Agreement
# available at http://aws.amazon.com/agreement or other written agreement between
# Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

# Function to display usage
show_usage() {
    echo "Usage: $0 -d <dataset>"
    echo "Dataset options: blocks, transactions, logs"
    exit 1
}

# Install jaq if not already installed
[ ! -f ~/.cargo/bin/jaq ] && cargo install --locked jaq

# Initialize variables
dataset=""
chain=""

# Parse command line options
while getopts "d:" opt; do
    case $opt in
    d) dataset="$OPTARG" ;;
    ?) show_usage ;;
    esac
done

# Check if both options are provided
if [ -z "$dataset" ]; then
    echo "Error: Dataset (-d) option is required"
    show_usage
fi

# Validate dataset
case $dataset in
blocks | transactions | logs) ;;
*)
    echo "Error: Invalid dataset '$dataset'"
    echo "Valid datasets are: blocks, transactions, logs"
    exit 1
    ;;
esac

# get Chain
chain_id_hex=$(curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' http://localhost:8545 | jq -r '.result')
chain_id=$((16#${chain_id_hex#0x}))

case $chain_id in
1)
    chain="ethereum"
    ;;
10)
    chain="optimism"
    ;;
56)
    chain="bnb"
    ;;
69)
    chain="optimsim_kovan"
    ;;
100)
    chain="gnosis"
    ;;
137)
    chain="polygon"
    ;;
1101)
    chain="polygon_zkevm"
    ;;
1442)
    chain="polygon_zkevm_testnet"
    ;;
8453)
    chain="base"
    ;;
10200)
    chain="gnosis_chidao"
    ;;
17000)
    chain="holesky"
    ;;
42161)
    chain="arbitrum"
    ;;
42170)
    chain="arbitrum_nova"
    ;;
43114)
    chain="avalanche"
    ;;
80001)
    chain="polygon_mumbai"
    ;;
84531)
    chain="base_goerli"
    ;;
7777777)
    chain="zora"
    ;;
11155111)
    chain="sepolia"
    ;;
*)
    chain="network_${chain_id}"
    ;;
esac

# Validation has passed, dataset and chain are set

# Make sure the topic exist
/opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server ${KAFKA_BROKER} \
    --command-config /opt/kafka/bin/client.properties \
    --create \
    --if-not-exists \
    --topic ${chain}-${dataset} \
    --partitions 1 \
    --replication-factor 3 \
    --config max.message.bytes=10485880 \
    --config retention.ms=-1

# AWS IMDSv2
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
AWS_REGION=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

echo "Starting ingest for ${chain}-${dataset}..."

start_time_batch=$(date +%s.%N)

if ls /cryo/${dataset}/${chain}__${dataset}* 1>/dev/null 2>&1; then

    for file in /cryo/${dataset}/${chain}__${dataset}*; do
        echo -n "Processing ${file}"
        start=$(date +%s.%N)
        if jaq -c '.[]' ${file} | \
            /opt/kafka/bin/kafka-console-producer.sh \
            --bootstrap-server ${KAFKA_BROKER} \
            --producer.config /opt/kafka/bin/client.properties \
            --topic ${chain}-${dataset} \
            --producer-property max.request.size=10485880 \
            1>/dev/null; then

            end=$(date +%s.%N)
            runtime=$(echo "${end} - ${start}" | bc)
            echo " -> Success (${runtime}s)."
            last_block=$(echo "$file" | sed 's/.*to_\([0-9]*\).*/\1/')

            # Publish to CW
            aws cloudwatch put-metric-data \
                --namespace "Indexer" \
                --metric-name "Ingest" \
                --value ${last_block} \
                --unit "Count" \
                --dimensions "InstanceId=${INSTANCE_ID},Dataset=${dataset},Chain=${chain}" \
                --region ${AWS_REGION} 1>/dev/null

            # Move file to processed
            mkdir -p /cryo/${dataset}/processed
            mv ${file} /cryo/${dataset}/processed
        else
            echo -e "\e[31m -> Error.\e[0m" >&2
            mkdir -p /cryo/${dataset}/error
            mv ${file} /cryo/${dataset}/error
        fi
    done

    end_time_batch=$(date +%s.%N)
    runtime_batch=$(echo "${end_time_batch} - ${start_time_batch}" | bc)
    echo Final runtime: ${runtime_batch}s.
else
    echo -e "\e[31mError: No files found matching pattern '${chain}__${dataset}*'\e[0m" >&2
    exit 1
fi
