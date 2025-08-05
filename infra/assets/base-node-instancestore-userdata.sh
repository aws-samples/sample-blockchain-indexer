#!/bin/bash

# Install remaining packages w/o config
dnf install -y git docker cmake rust clang

export OP_NODE_L1_ETH_RPC=__OP_NODE_L1_ETH_RPC__
export OP_NODE_L1_BEACON=__OP_NODE_L1_BEACON__

# Install yq
YQ_BINARY=yq_linux_arm64
wget https://github.com/mikefarah/yq/releases/download/v4.44.6/${YQ_BINARY}.tar.gz
tar xzf ${YQ_BINARY}.tar.gz
mv yq_linux_arm64 /usr/bin/yq

groupadd -g 1002 blockchain
useradd -u 1002 -g 1002 -m -s /bin/bash blockchain
usermod -a -G docker blockchain
usermod -a -G docker ec2-user

echo "Starting docker"
service docker start
chkconfig docker on

# Install docker-compose
mkdir -p /usr/local/lib/docker/cli-plugins

curl -sL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-"$(uname -m)" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose

# Set ownership to root and make executable
test -f /usr/local/lib/docker/cli-plugins/docker-compose &&
  sudo chown root:root /usr/local/lib/docker/cli-plugins/docker-compose
test -f /usr/local/lib/docker/cli-plugins/docker-compose &&
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Prepare volumes
echo "Preparing data volume"

mkdir -p /data
mkdir -p /snapshots

# Wait for the volumes to become available
echo "Waiting for volumes to be attached..."
while [[ ! -e /dev/nvme1n1 || ! -e /dev/nvme2n1 ]]; do
  sleep 5
done

# Additional check to ensure volume is fully attached
while true; do
  if lsblk /dev/nvme1n1 >/dev/null 2>&1; then
    echo "Snapshots Volume is attached and visible to the system"
    break
  fi
  echo "Waiting for snapshot volume to become fully available..."
  sleep 5
done

while true; do
  if lsblk /dev/nvme2n1 >/dev/null 2>&1; then
    echo "Data Volume is attached and visible to the system"
    break
  fi
  echo "Waiting for data volume to become fully available..."
  sleep 5
done

if ! blkid /dev/nvme1n1; then
  echo "Formatting nvme1n1 (snapshots volume)"
  mkfs -t xfs /dev/nvme1n1
fi

if ! blkid /dev/nvme2n1; then
  echo "Formatting nvme2n1 (data volume)"
  mkfs -t xfs /dev/nvme2n1
fi

sleep 10
# Add snapshots volume to /etc/fstab
uuid=$(lsblk -n -o UUID /dev/nvme1n1)
line="UUID=$uuid /snapshots xfs defaults 0 2"
echo $line | sudo tee -a /etc/fstab

# Add data volume to /etc/fstab
uuid=$(lsblk -n -o UUID /dev/nvme2n1)
line="UUID=$uuid /data xfs defaults 0 2"
echo $line | sudo tee -a /etc/fstab

mount -a

lsblk -d

chown -R blockchain:blockchain /data
chmod -R 755 /data

chown -R blockchain:blockchain /snapshots
chmod -R 755 /snapshots

# Get BASE and start it
sudo su blockchain

cd /home/blockchain
git clone https://github.com/base-org/node.git
chown -R blockchain:blockchain node
cd node

# update the HOST_DATA_DIR in the .env file to use ./data/${CLIENT}-data
sed -i "s/HOST_DATA_DIR=.*/HOST_DATA_DIR=\/data\/\${CLIENT}-data/" .env

# set the L1 node values to the actual node (use # as delimiter because of // in RPC URL)
sed -i "s#OP_NODE_L1_ETH_RPC=.*#OP_NODE_L1_ETH_RPC=${OP_NODE_L1_ETH_RPC}#" .env.mainnet
sed -i "s#OP_NODE_L1_BEACON=.*#OP_NODE_L1_BEACON=${OP_NODE_L1_BEACON}#" .env.mainnet

# trust the L1 node
sed -i "s/# OP_NODE_L1_TRUST_RPC=.*/OP_NODE_L1_TRUST_RPC=true/" .env.sepolia
sed -i "s/# OP_NODE_L1_TRUST_RPC=.*/OP_NODE_L1_TRUST_RPC=true/" .env.mainnet

# update docker compose and set the .env files to use mainnet
yq '.services.execution.env_file = [".env.mainnet"]' -i docker-compose.yml
yq '.services.node.env_file = [".env.mainnet"]' -i docker-compose.yml

# CLIENT=reth docker compose up --build -d

# Enable syncStatus
cp /root/syncStatus/syncStatus.sh /usr/local/bin/
chmod 755 /usr/local/bin/syncStatus.sh

cp /root/syncStatus/syncStatus.service /etc/systemd/system/
cp /root/syncStatus/syncStatus.timer /etc/systemd/system/
chmod 644 /etc/systemd/system/syncStatus*

systemctl daemon-reload
systemctl enable syncStatus.service
systemctl start syncStatus.timer
