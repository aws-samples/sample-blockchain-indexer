#!/bin/bash

# Install remaining packages w/o config
dnf install -y git docker rust clang cargo lz4 openssl-devel clang-devel gcc-c++ cmake

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
  chown root:root /usr/local/lib/docker/cli-plugins/docker-compose
test -f /usr/local/lib/docker/cli-plugins/docker-compose &&
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Prepare volumes
echo "Preparing data volume"

mkdir /data
mount -t tmpfs -o size=1300g tmpfs /data

chown -R blockchain:blockchain /data
chmod -R 755 /data

# switch to blockchain user and download node clients
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
LIGHTHOUSE_VERSION=v7.0.0-beta.4
wget https://github.com/sigp/lighthouse/releases/download/${LIGHTHOUSE_VERSION}/lighthouse-${LIGHTHOUSE_VERSION}-aarch64-unknown-linux-gnu.tar.gz
tar xzf lighthouse-${LIGHTHOUSE_VERSION}-aarch64-unknown-linux-gnu.tar.gz

# generate engine secret
SECRET_PATH=/data/jwttoken/jwt.hex
mkdir -p /data/jwttoken
openssl rand -hex 32 | tr -d "\n" | tee > ${SECRET_PATH}

# run reth
# reth node --authrpc.jwtsecret ${SECRET_PATH} --chain sepolia --datadir /data/sepolia/reth --http

# below with SECRET_PATH expanded for easier copying to cmd line
# reth node --authrpc.jwtsecret /data/jwttoken/jwt.hex --chain sepolia --datadir /data/sepolia/reth --http

# run lighthouse
# lighthouse --datadir /data/sepolia/lighthouse bn --network sepolia --checkpoint-sync-url https://beaconstate-sepolia.chainsafe.io --execution-endpoint http://localhost:8551 --execution-jwt ${SECRET_PATH} --disable-deposit-contract-sync

# below with SECRET_PATH expanded for easier copying to cmd line
# lighthouse --datadir /data/sepolia/lighthouse bn --network sepolia --checkpoint-sync-url https://beaconstate-sepolia.chainsafe.io --execution-endpoint http://localhost:8551 --execution-jwt /data/jwttoken/jwt.hex --disable-deposit-contract-sync

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
