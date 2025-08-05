#!/bin/bash

# Install remaining packages w/o config
dnf install -y git docker amazon-cloudwatch-agent collectd

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

mkdir -p /data/grafana
mkdir -p /data/prometheus
mkdir -p /data/lighthouse
mkdir -p /data/reth/logs
mkdir -p /data/reth/holesky
mkdir -p /data/reth/sepolia
mkdir -p /data/reth/mainnet

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
  "logs": {
      "logs_collected": {
          "files": {
              "collect_list": [
                  {
                      "file_path": "/var/log/cloud-init-output.log",
                      "log_group_name": "cloud-init-output.log",
                      "log_stream_name": "{instance_id}"
                  },
                  {
                      "file_path": "/var/log/cloud-init.log",
                      "log_group_name": "cloud-init.log",
                      "log_stream_name": "{instance_id}"
                  },
                  {
                    "file_path": "/data/reth/logs/mainnet/reth.log",
                    "log_group_class": "STANDARD",
                    "log_group_name": "reth.log",
                    "log_stream_name": "{instance_id}",
                    "retention_in_days": 30
                  },
                  {
                    "file_path": "/data/lighthouse/mainnet/beacon/logs/beacon.log",
                    "log_group_class": "STANDARD",
                    "log_group_name": "lighthouse.log",
                    "log_stream_name": "{instance_id}",
                    "retention_in_days": 30
                  }
              ]
          }
      }
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
          "/data"
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

# Get Reth and start it
sudo su blockchain

cd /home/blockchain
git clone https://github.com/paradigmxyz/reth.git
chown -R blockchain:blockchain reth
cd reth

# Update docker compose to use the /data dir
yq '.services.reth.volumes = [
  "/data/reth/mainnet:/root/.local/share/reth/mainnet",
  "/data/reth/sepolia:/root/.local/share/reth/sepolia",
  "/data/reth/holesky:/root/.local/share/reth/holesky",
  "/data/reth/logs:/root/logs",
  "./jwttoken:/root/jwt:ro"
]' -i etc/docker-compose.yml

yq '.services.prometheus.volumes = [
  "./prometheus/:/etc/prometheus/",
  "/data/prometheus:/prometheus"
]' -i etc/docker-compose.yml

yq '.services.grafana.volumes = [
  "/data/grafana:/var/lib/grafana",
  "./grafana/datasources:/etc/grafana/provisioning/datasources",
  "./grafana/dashboards:/etc/grafana/provisioning_temp/dashboards"
]' -i etc/docker-compose.yml

yq 'del(.volumes)' -i etc/docker-compose.yml

# Update lighthouse.yml to use the /data dir
yq e '.services.lighthouse.volumes = [
  "/data/lighthouse:/root/.lighthouse",
  "./jwttoken:/root/jwt:ro"
]' -i etc/lighthouse.yml

# Update lighthouse version
yq e '.services.lighthouse.image = "sigp/lighthouse:v6.0.1"' -i etc/lighthouse.yml

# Remove the volumes section at the bottom
yq e 'del(.volumes)' -i etc/lighthouse.yml

./etc/generate-jwt.sh
# docker compose -f etc/docker-compose.yml -f etc/lighthouse.yml up -d
