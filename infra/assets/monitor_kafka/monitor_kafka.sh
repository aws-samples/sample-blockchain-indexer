#!/bin/bash

# © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
# This AWS Content is provided subject to the terms of the AWS Customer Agreement
# available at http://aws.amazon.com/agreement or other written agreement between
# Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

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


# AWS IMDSv2
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
AWS_REGION=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

export KAFKA_CLUSTER_ARN=$(aws kafka list-clusters | jq -r '.ClusterInfoList[] | select(.ClusterName == "blockchain") | .ClusterArn')
export KAFKA_BROKER=$(aws kafka get-bootstrap-brokers --cluster-arn $KAFKA_CLUSTER_ARN | jq -r '.BootstrapBrokerStringSaslIam')

DATASETS="blocks transactions logs"
for DATASET in ${DATASETS}; do

   # Make sure the topics exist
   /opt/kafka/bin/kafka-topics.sh \
      --bootstrap-server ${KAFKA_BROKER} \
      --command-config /opt/kafka/bin/client.properties \
      --create \
      --if-not-exists \
      --topic ${chain}-${DATASET} \
      --partitions 1 \
      --replication-factor 3 \
      --config  max.message.bytes=10485880 \
      --config retention.ms=-1

   # get last message offset
   OFFSET=$(($(/opt/kafka/bin/kafka-get-offsets.sh \
      --bootstrap-server ${KAFKA_BROKER} \
      --command-config /opt/kafka/bin/client.properties \
      --time -1 \
      | grep ${chain}-${DATASET} \
      | cut -d':' -f3) -1))

   lastBlocks[$DATASET]=$(/opt/kafka/bin/kafka-console-consumer.sh \
      --bootstrap-server ${KAFKA_BROKER} \
      --topic ${chain}-${DATASET} \
      --consumer.config /opt/kafka/bin/client.properties \
      --partition 0 \
      --offset ${OFFSET} \
      --max-messages 1 \
      | jq -r '.block_number')

    # echo "Latest block on Kafka ${chain}-${DATASET}: ${lastBlocks[$DATASET]}"

    # Send metric to CloudWatch
    aws cloudwatch put-metric-data \
        --namespace "Indexer" \
        --metric-name "Kafka" \
        --value "${lastBlocks[$DATASET]}" \
        --dimensions \
            "InstanceId=${INSTANCE_ID},Dataset=$DATASET,Chain=$chain" \
        --region ${AWS_REGION} 1>/dev/null
done



