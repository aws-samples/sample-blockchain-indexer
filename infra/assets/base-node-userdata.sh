#!/bin/bash

# Install remaining packages w/o config amazon-cloudwatch-agent collectd
dnf install -y git docker

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
test -f /usr/local/lib/docker/cli-plugins/docker-compose \
  && sudo chown root:root /usr/local/lib/docker/cli-plugins/docker-compose
test -f /usr/local/lib/docker/cli-plugins/docker-compose \
  && sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Prepare data volume
echo "Preparing data volume"

mkdir -p /data

# Wait for the EBS volume to become available
echo "Waiting for EBS volume to be attached..."
while [ ! -e /dev/nvme1n1 ]; do
    sleep 5
done

# Additional check to ensure volume is fully attached
while true; do
    if lsblk /dev/nvme1n1 > /dev/null 2>&1; then
        echo "Volume is attached and visible to the system"
        break
    fi
    echo "Waiting for volume to become fully available..."
    sleep 5
done

# Update throughput as CDK doesn't work for that
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/instance-id)
VOLUME_ID=$(aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=${INSTANCE_ID} Name=attachment.device,Values=/dev/sdf --query "Volumes[0].VolumeId" --output text)
THROUGHPUT=$(aws ec2 describe-volumes --volume-ids ${VOLUME_ID} --query "Volumes[0].Throughput" --output text)

# Only modify if throughput isn't already 300
if [ "$THROUGHPUT" != "300" ]; then
  aws ec2 modify-volume --volume-id ${VOLUME_ID} --throughput 300
  echo "Updated volume throughput to 300 MB/s"
else
  echo "Volume throughput is already 300 MB/s"
fi

if ! blkid /dev/nvme1n1; then
  echo "Formatting nvme1n1"
  mkfs -t ext4 /dev/nvme1n1
fi

  sleep 10
  # Define the line to add to fstab
  uuid=$(lsblk -n -o UUID /dev/nvme1n1)
  line="UUID=$uuid /data ext4 defaults 0 2"

  # Write the line to fstab
  echo $line | sudo tee -a /etc/fstab

  mount -a


lsblk -d

chown -R blockchain:blockchain /data
chmod -R 755 /data

# Configure cloudwatch agent
echo 'Configuring CloudWatch Agent'
cat <<EOF > /opt/aws/amazon-cloudwatch-agent/etc/custom-amazon-cloudwatch-agent.json
{
  "agent": {
      "metrics_collection_interval": 60,
      "run_as_user": "cwagent"
  },
  "metrics": {
    "aggregation_dimensions": [
      [
        "InstanceId"
      ]
    ],
		"append_dimensions": {
			"AutoScalingGroupName": "\${aws:AutoScalingGroupName}",
			"ImageId": "\${aws:ImageId}",
			"InstanceId": "\${aws:InstanceId}",
			"InstanceType": "\${aws:InstanceType}"
		},
    "metrics_collected": {
      "collectd": {
        "metrics_aggregation_interval": 60
      },
      "disk": {
        "measurement": [
          "used_percent"
        ],
        "metrics_collection_interval": 60,
        "ignore_file_system_types": [
          "sysfs",
          "devtmpfs"
        ],
        "resources": [
          "/",
          "/data",
          "/snapshots"
        ]
      },
      "mem": {
        "measurement": [
          "mem_used_percent"
        ],
        "metrics_collection_interval": 60
      },
      "statsd": {
        "metrics_aggregation_interval": 60,
        "metrics_collection_interval": 10,
        "service_address": ":8125"
      }
    }
  }
}
EOF

echo "Starting CloudWatch Agent"
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
-a fetch-config -c file:/opt/aws/amazon-cloudwatch-agent/etc/custom-amazon-cloudwatch-agent.json -m ec2 -s
systemctl restart amazon-cloudwatch-agent

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
