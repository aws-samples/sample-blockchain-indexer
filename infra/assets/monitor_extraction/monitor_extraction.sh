#!/bin/bash

# © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
# This AWS Content is provided subject to the terms of the AWS Customer Agreement
# available at http://aws.amazon.com/agreement or other written agreement between
# Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

BASE_DIR="/cryo"
DATASETS=("blocks" "transactions" "logs")

# Create array of directories to monitor
MONITOR_DIRS=()
for dataset in "${DATASETS[@]}"; do
    MONITOR_DIRS+=("$BASE_DIR/$dataset")
    # Ensure directory exists
    mkdir -p "$BASE_DIR/$dataset"
done

# AWS IMDSv2
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
AWS_REGION=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

# Monitor multiple directories
inotifywait -m "${MONITOR_DIRS[@]}" -e create -e moved_to |
    while read path action file; do
        # Extract dataset from path
        dataset=$(basename "${path}")

        # Check if file matches the expected pattern
        if [[ $file =~ ^[^_]+__${dataset}__([0-9]{8})_to_([0-9]{8})\.json$ ]]; then
            chain="${file%%__*}"
            to_block="${BASH_REMATCH[2]}"
            to_block_number=$(echo "${to_block}" | sed 's/^0*//')

            echo "New file in ${dataset}, chain: ${chain}, final block: ${to_block_number}"

            # Send metric to CloudWatch
            aws cloudwatch put-metric-data \
                --namespace "Indexer" \
                --metric-name "Extraction" \
                --value "$to_block" \
                --dimensions \
                    "InstanceId=${INSTANCE_ID},Dataset=$dataset,Chain=$chain" \
                --region ${AWS_REGION} 1>/dev/null
        fi
    done
