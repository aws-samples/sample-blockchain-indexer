#!/bin/bash

# Install remaining packages w/o config
dnf install -y git docker rust clang

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

if ! blkid /dev/nvme1n1; then
  echo "Formatting nvme1n1 (snapshots volume)"
  mkfs -t xfs /dev/nvme1n1
fi

sleep 10
# Add snapshots volume to /etc/fstab
uuid=$(lsblk -n -o UUID /dev/nvme1n1)
line="UUID=$uuid /snapshots xfs defaults 0 2"
echo $line | sudo tee -a /etc/fstab

mount -a

lsblk -d

chown -R blockchain:blockchain /data
chmod -R 755 /data

# Get BASE and start it
sudo su blockchain

cd /home/blockchain

# get rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y


# get reth
git clone https://github.com/paradigmxyz/reth.git
chown -R blockchain:blockchain reth
cd reth
git checkout v1.3.4
cd ..

# get lighthouse
# LIGHTHOUSE_VERSION=v6.0.1
LIGHTHOUSE_VERSION=v7.0.0-beta.4
wget https://github.com/sigp/lighthouse/releases/download/${LIGHTHOUSE_VERSION}/lighthouse-${LIGHTHOUSE_VERSION}-aarch64-unknown-linux-gnu.tar.gz
tar xzf lighthouse-${LIGHTHOUSE_VERSION}-aarch64-unknown-linux-gnu.tar.gz

# generate engine secret
SECRET_PATH=/data/jwttoken/jwt.hex
mkdir -p /data/jwttoken
openssl rand -hex 32 | tr -d "\n" | tee > ${SECRET_PATH}

# run reth
# reth node --authrpc.jwtsecret ${SECRET_PATH} --chain sepolia --datadir /data/sepolia/reth --http

# run lighthouse
# lighthouse --datadir /data/sepolia/lighthouse bn --network sepolia --checkpoint-sync-url https://beaconstate-sepolia.chainsafe.io --execution-endpoint http://localhost:8551 --execution-jwt ${SECRET_PATH} --disable-deposit-contract-sync

# Holesky
# lighthouse --datadir /data/holesky/lighthouse bn --network holesky --checkpoint-sync-url https://holesky.beaconstate.ethstaker.cc/ --execution-endpoint http://localhost:8551 --execution-jwt ${SECRET_PATH} --disable-deposit-contract-sync

# Enable syncStatus
cp /root/syncStatus/syncStatus.sh /usr/local/bin/
chmod 755 /usr/local/bin/syncStatus.sh

cp /root/syncStatus/syncStatus.service /etc/systemd/system/
cp /root/syncStatus/syncStatus.timer /etc/systemd/system/
chmod 644 /etc/systemd/system/syncStatus*

systemctl daemon-reload
systemctl enable syncStatus.service
systemctl start syncStatus.timer
