#!/bin/bash

# Install remaining packages w/o config
dnf install -y java-23

echo Adding kafka user
groupadd -g 1002 kafka
useradd -u 1002 -g 1002 -m -s /bin/bash kafka

su kafka
cd /home/kafka

# Install Kafka tools
wget https://dlcdn.apache.org/kafka/4.0.0/kafka_2.13-4.0.0.tgz
tar -xzf kafka_2.13-4.0.0.tgz
cd kafka_2.13-4.0.0/libs
wget https://github.com/aws/aws-msk-iam-auth/releases/download/v2.3.2/aws-msk-iam-auth-2.3.2-all.jar
cd ../bin

echo Configuring Kafka
echo 'Configuring CloudWatch Agent'
cat <<EOF > client.properties
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
EOF

