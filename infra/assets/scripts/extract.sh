#!/bin/bash

# © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
# This AWS Content is provided subject to the terms of the AWS Customer Agreement
# available at http://aws.amazon.com/agreement or other written agreement between
# Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

# Function to display usage
show_usage() {
    echo "Usage: $0 -f <start block> -t <end block>"
    exit 1
}

# Initialize variables
start_block=""
end_block=""

# Parse command line options
while getopts "f:t:" opt; do
    case $opt in
        f) start_block="$OPTARG" ;;
        t) end_block="$OPTARG" ;;
        ?) show_usage ;;
    esac
done

# Check if both options are provided
if [ -z "$start_block" ] || [ -z "$end_block" ]; then
    echo "Error: Both from (-f) and to (-t) options are required"
    show_usage
fi

# Validation has passed, dataset and chain are set

# AWS IMDSv2
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
AWS_REGION=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

start_time=$(date +%s.%N)

cryo --output-dir /cryo \
     --subdirs datatype \
     --rpc http://localhost:8545 \
     --u256-types string \
     --include-columns block_hash timestamp parent_hash state_root transactions_root receipts_root gas_limit logs_bloom difficulty size mix_hash nonce withdrawals_root \
     --exclude-columns n_input_bytes n_input_zero_bytes n_input_nonzero_bytes n_data_bytes \
     --chunk-size 10000 \
     --blocks ${start_block}:${end_block} \
     --json \
     blocks transactions logs

end_time=$(date +%s.%N)
runtime=$(echo "${end_time} - ${start_time}" | bc)
echo Final runtime: ${runtime}s.
