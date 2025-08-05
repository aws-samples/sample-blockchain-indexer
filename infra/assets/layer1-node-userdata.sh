#!/bin/bash

# © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
# This AWS Content is provided subject to the terms of the AWS Customer Agreement
# available at http://aws.amazon.com/agreement or other written agreement between
# Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

# Install remaining packages w/o config
dnf install -y git clang lz4 openssl-devel clang-devel gcc-c++ cmake java-23 inotify-tools

groupadd -g 1002 blockchain
useradd -u 1002 -g 1002 -m -s /bin/bash blockchain

# Installing s5cmd
S5CMD_VERSION=2.3.0
wget --no-verbose -P /tmp/ https://github.com/peak/s5cmd/releases/download/v${S5CMD_VERSION}/s5cmd_${S5CMD_VERSION}_Linux-arm64.tar.gz
tar -xzf /tmp/s5cmd_${S5CMD_VERSION}_Linux-arm64.tar.gz -C /usr/local/bin
echo Installed s5cmd version $(/usr/local/bin/s5cmd version).

# Prepare volumes
echo "Preparing data volume"

mkdir -p /data

# Wait for the volumes to become available
echo "Waiting for volumes to be attached..."
while true; do
  if [[ -e /dev/nvme1n1 ]] && [[ -e /dev/nvme2n1 ]] && \
     lsblk /dev/nvme1n1 >/dev/null 2>&1 && \
     lsblk /dev/nvme2n1 >/dev/null 2>&1; then
    echo "All devices are fully attached and operational"
    break
  fi
  echo "Waiting for volumes to become fully available..."
  sleep 5
done

# Additional check to ensure volume is fully attached
# while true; do
#   if lsblk /dev/nvme1n1 >/dev/null 2>&1; then
#     echo "/dev/nvme1  is attached and visible to the system"
#     break
#   fi
#   echo "Waiting for data volume to become fully available..."
#   sleep 5
# done

# Determine which volume is NVME and which is EBS
if [[ $(lsblk -n -o SERIAL /dev/nvme1n1) == AWS* ]]; then
  nvme_volume="/dev/nvme1n1"
  ebs_volume="/dev/nvme2n1"
else
  nvme_volume="/dev/nvme2n1"
  ebs_volume="/dev/nvme1n1"
fi

# Format the NVME volume if it's not already formatted
if ! blkid $nvme_volume; then
  echo "Formatting $nvme_volume (data volume)"
  mkfs -t xfs $nvme_volume
fi

sleep 10
# Add data volume to /etc/fstab
uuid=$(lsblk -n -o UUID $nvme_volume)
line="UUID=$uuid /data xfs defaults 0 2"
echo "$line" | tee -a /etc/fstab

echo "Preparing extraction volume"
mkdir -p /cryo

if ! blkid $ebs_volume; then
  echo "Formatting $ebs_volume (extraction volume)"
  mkfs -t xfs $ebs_volume
fi

sleep 10
# Add data volume to /etc/fstab
uuid=$(lsblk -n -o UUID $ebs_volume)
line="UUID=$uuid /cryo xfs defaults 0 2"
echo "$line" | tee -a /etc/fstab



# Wait for the volumes to become available
# echo "Waiting for volumes to be attached..."
# while [[ ! -e /dev/nvme2n1  ]]; do
#   sleep 5
# done

# Additional check to ensure volume is fully attached
# while true; do
#   if lsblk /dev/nvme2n1 >/dev/null 2>&1; then
#     echo "Cryo volume is attached and visible to the system"
#     break
#   fi
#   echo "Waiting for cryo volume to become fully available..."
#   sleep 5
# done

# if ! blkid /dev/nvme2n1; then
#   echo "Formatting nvme2n1 (cryo volume)"
#   mkfs -t xfs /dev/nvme2n1
# fi

# sleep 10
# # Add data volume to /etc/fstab
# uuid=$(lsblk -n -o UUID /dev/nvme2n1)
# line="UUID=$uuid /cryo xfs defaults 0 2"
# echo "$line" | tee -a /etc/fstab


# Mounting new volumes
mount -a
lsblk -d

chown -R blockchain:blockchain /data
chmod -R 755 /data

chown -R blockchain:blockchain /cryo
chmod -R 755 /cryo

# Enable monitoring services for Cloudwatch

# latest block from node
unzip /tmp/lastBlock.zip -d /tmp/lastBlock
cp /tmp/lastBlock/lastBlock.sh /usr/local/bin/
chmod 755 /usr/local/bin/lastBlock.sh
cp /tmp/lastBlock/lastBlock.service /etc/systemd/system/
cp /tmp/lastBlock/lastBlock.timer /etc/systemd/system/
chmod 644 /etc/systemd/system/lastBlock*

# latest block on kafka
unzip /tmp/monitor_kafka.zip -d /tmp/monitor_kafka
cp /tmp/monitor_kafka/monitor_kafka.sh /usr/local/bin/
chmod 755 /usr/local/bin/monitor_kafka.sh
cp /tmp/monitor_kafka/monitor_kafka.service /etc/systemd/system/
cp /tmp/monitor_kafka/monitor_kafka.timer /etc/systemd/system/
chmod 644 /etc/systemd/system/monitor_kafka*

# latest block during extraction
unzip /tmp/monitor_extraction.zip -d /tmp/monitor_extraction
cp /tmp/monitor_extraction/monitor_extraction.sh /usr/local/bin/
chmod 755 /usr/local/bin/monitor_extraction.sh
cp /tmp/monitor_extraction/monitor_extraction.service /etc/systemd/system/
chmod 644 /etc/systemd/system/monitor_extraction*

systemctl daemon-reload

# systemctl enable lastBlock.service
# systemctl start lastBlock.timer

# systemctl enable monitor_kafka.service
# systemctl start monitor_kafka.timer

# systemctl enable monitor_extraction.service

# cd into blockchain user's home dir
cd /home/blockchain

# get scripts
unzip /tmp/scripts.zip -d /home/blockchain/scripts
chown -R blockchain:blockchain /home/blockchain/scripts
chmod -R 755 /home/blockchain/scripts

# get reth
RETH_VERSION=v1.4.1
git clone https://github.com/paradigmxyz/reth.git
cd reth
git checkout ${RETH_VERSION}
cd ..

# get lighthouse
LIGHTHOUSE_VERSION=v7.0.1
wget --no-verbose -P /tmp https://github.com/sigp/lighthouse/releases/download/${LIGHTHOUSE_VERSION}/lighthouse-${LIGHTHOUSE_VERSION}-aarch64-unknown-linux-gnu.tar.gz
tar xzf /tmp/lighthouse-${LIGHTHOUSE_VERSION}-aarch64-unknown-linux-gnu.tar.gz -C /usr/local/bin

# generate engine secret
SECRET_PATH=/data/jwttoken/jwt.hex
mkdir -p /data/jwttoken
openssl rand -hex 32 | tr -d "\n" | tee > ${SECRET_PATH}

# Install Kafka tools
KAFKA_VERSION=4.0.0
wget --no-verbose -P /tmp https://dlcdn.apache.org/kafka/${KAFKA_VERSION}/kafka_2.13-${KAFKA_VERSION}.tgz
tar -xzf /tmp/kafka_2.13-${KAFKA_VERSION}.tgz -C /opt
sudo ln -s /opt/kafka_2.13-${KAFKA_VERSION} /opt/kafka

MSK_IAM_AUTH_VERSION=2.3.2
wget --no-verbose -P /opt/kafka/libs https://github.com/aws/aws-msk-iam-auth/releases/download/v${MSK_IAM_AUTH_VERSION}/aws-msk-iam-auth-${MSK_IAM_AUTH_VERSION}-all.jar

echo Configuring Kafka
cat <<EOF > /opt/kafka/bin/client.properties
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
EOF

# Get Cryo
cd /home/blockchain
git clone https://github.com/paradigmxyz/cryo

chown -R blockchain:blockchain /home/blockchain

# export Kafka broker
echo 'KAFKA_CLUSTER_ARN=__KAFKA_CLUSTER_ARN__' >> /etc/environment
echo 'export KAFKA_BROKER=$(aws kafka get-bootstrap-brokers --cluster-arn $KAFKA_CLUSTER_ARN | jq -r '"'"'.BootstrapBrokerStringSaslIam'"'"')' >> /home/blockchain/.bashrc


# get rust
# curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# Get snapshot (get URL from https://publicnode.com/snapshots)
# mkdir -p /data/snapshots/extracted
# cd /data/snapshots
# wget --no-verbose <URL>

# uncompress
# cd extracted
# tar -I lz4 -xzf ../<SNAPSHOT_FILE>

# build reth
# cd /home/blockchain/reth
# make install

# build cryo
# cd /home/blockchain/cryo
# cargo install --path ./crates/cli

# install jaq for JSON processing
# cargo install --locked jaq

# run reth
# reth node --authrpc.jwtsecret /data/jwttoken/jwt.hex --chain sepolia --datadir /data/sepolia/reth --http
# reth node --authrpc.jwtsecret /data/jwttoken/jwt.hex --chain holesky --datadir /data/holesky/reth --http
# reth node --authrpc.jwtsecret /data/jwttoken/jwt.hex --datadir /data/mainnet/reth --http

# run lighthouse
# lighthouse --datadir /data/sepolia/lighthouse bn --network sepolia --checkpoint-sync-url https://beaconstate-sepolia.chainsafe.io --execution-endpoint http://localhost:8551 --execution-jwt /data/jwttoken/jwt.hex --disable-deposit-contract-sync
# lighthouse --datadir /data/holesky/lighthouse bn --network holesky --checkpoint-sync-url https://beaconstate-holesky.chainsafe.io --execution-endpoint http://localhost:8551 --execution-jwt /data/jwttoken/jwt.hex --disable-deposit-contract-sync
# lighthouse --datadir /data/mainnet/lighthouse bn --network mainnet --checkpoint-sync-url https://beaconstate-mainnet.chainsafe.io --execution-endpoint http://localhost:8551 --execution-jwt /data/jwttoken/jwt.hex --disable-deposit-contract-sync

# run exex
# cd exex/kafka-emitter-exex
# cargo run --bin kafka-emitter -- node --authrpc.jwtsecret /data/jwttoken/jwt.hex --chain holesky --datadir /data/holesky/reth --http --exex-start-block 3877000
# cargo run --bin kafka-emitter -- node --authrpc.jwtsecret /data/jwttoken/jwt.hex --chain sepolia --datadir /data/sepolia/reth --http --exex-start-block 8438000
# cargo run --bin kafka-emitter -- node --authrpc.jwtsecret /data/jwttoken/jwt.hex --chain mainnet --datadir /data/mainnet/reth --http --exex-start-block 22597000




