// © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
// This AWS Content is provided subject to the terms of the AWS Customer Agreement
// available at http://aws.amazon.com/agreement or other written agreement between
// Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as iam from "aws-cdk-lib/aws-iam";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as msk_alpha from "@aws-cdk/aws-msk-alpha";
import * as msk from "aws-cdk-lib/aws-msk";
import * as nag from "cdk-nag";
import * as s3 from "aws-cdk-lib/aws-s3";
import { Layer1Node } from "../constructs/layer1-node";

export class IndexerStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // get default VPC
    const vpc = ec2.Vpc.fromLookup(this, "DefaultVPC", { isDefault: true });

    // create an msk provisioned cluster
    const kafkaCluster = new msk_alpha.Cluster(this, "KafkaCluster", {
      clusterName: "blockchain",
      kafkaVersion: msk_alpha.KafkaVersion.V3_9_X_KRAFT,
      // kafkaVersion: msk_alpha.KafkaVersion.V3_6_0,
      vpc,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PUBLIC,
        onePerAz: true,
        availabilityZones: vpc.availabilityZones.slice(0, 3), // Limit to first 3 AZs
      },
      instanceType: ec2.InstanceType.of(
        ec2.InstanceClass.M7G,
        ec2.InstanceSize.XLARGE
      ),
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      ebsStorageInfo: {
        volumeSize: 16384,
      },
      encryptionInTransit: {
        clientBroker: msk_alpha.ClientBrokerEncryption.TLS,
      },
      clientAuthentication: msk_alpha.ClientAuthentication.sasl({
        iam: true,
      }),
      storageMode: msk_alpha.StorageMode.TIERED,
      logging: {
        cloudwatchLogGroup: new cdk.aws_logs.LogGroup(this, "KafkaLogGroup", {
          removalPolicy: cdk.RemovalPolicy.DESTROY,
        }),
      },
    });

    // restrict connections to VPC
    kafkaCluster.connections.allowFrom(
      ec2.Peer.ipv4(vpc.vpcCidrBlock),
      ec2.Port.tcp(2181)
    );
    kafkaCluster.connections.allowFrom(
      ec2.Peer.ipv4(vpc.vpcCidrBlock),
      ec2.Port.tcp(9094)
    );

    // Cluster policy to allow firehose to access the cluster
    const clusterPolicy = new msk.CfnClusterPolicy(this, "ClusterPolicy", {
      clusterArn: kafkaCluster.clusterArn,
      policy: new iam.PolicyDocument({
        statements: [
          new iam.PolicyStatement({
            effect: iam.Effect.ALLOW,
            principals: [new iam.ServicePrincipal("firehose.amazonaws.com")],
            actions: [
              "kafka:CreateVpcConnection",
              "kafka:DescribeCluster",
              "kafka:DescribeClusterV2",
              "kafka:GetBootstrapBrokers",
            ],
            resources: [kafkaCluster.clusterArn],
          }),
        ],
      }),
    });

    // allow all traffic from within the vpc to the cluster
    kafkaCluster.connections.allowFrom(
      ec2.Peer.ipv4(vpc.vpcCidrBlock),
      ec2.Port.allTraffic(),
      "Allow hosts from within the VPC"
    );

    // IAM policy to write to the cluster
    const topicArn = `arn:aws:kafka:${cdk.Stack.of(this).region}:${
      cdk.Stack.of(this).account
    }:topic/${kafkaCluster.clusterName}/*`;
    const groupArn = `arn:aws:kafka:${cdk.Stack.of(this).region}:${
      cdk.Stack.of(this).account
    }:group/${kafkaCluster.clusterName}/*`;

    // Create S3 bucket for file transfers between local machine and EC2 instances
    const fileTransferBucket = new s3.Bucket(this, "FileTransferBucket", {
      bucketName: `blockchain-indexer-file-transfer-${
        cdk.Stack.of(this).account
      }-${cdk.Stack.of(this).region}`,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      versioned: false,
      lifecycleRules: [
        {
          id: "DeleteIncompleteMultipartUploads",
          enabled: true,
          abortIncompleteMultipartUploadAfter: cdk.Duration.days(7),
        },
      ],
    });

    const mainnetNode = new Layer1Node(this, "Mainnet", {
      vpc,
      mskCluster: kafkaCluster,
    });

    // Grant read/write access to the file transfer bucket for all EC2 instances
    fileTransferBucket.grantReadWrite(mainnetNode.instance);

    // Cfn outputs
    new cdk.CfnOutput(this, "KafkaVpc", {
      value: vpc.vpcId,
    });

    new cdk.CfnOutput(this, "KafkaClusterArn", {
      value: kafkaCluster.clusterArn,
    });

    new cdk.CfnOutput(this, "KafkaClusterName", {
      value: kafkaCluster.clusterName,
    });

    new cdk.CfnOutput(this, "MainnetNode", {
      value: mainnetNode.instanceId,
    });

    new cdk.CfnOutput(this, "FileTransferBucketName", {
      value: fileTransferBucket.bucketName,
      description:
        "S3 bucket for file transfers between local machine and EC2 instances",
    });

    new cdk.CfnOutput(this, "FileTransferBucketArn", {
      value: fileTransferBucket.bucketArn,
      description: "ARN of the S3 bucket for file transfers",
    });


    new cdk.CfnOutput(this, "PostgreSQLDatabaseName", {
      value: "blockchain_indexer",
      description: "PostgreSQL database name",
    });

    // CDK Nag suppressions
    nag.NagSuppressions.addResourceSuppressions(
      this,
      [
        {
          id: "AwsSolutions-MSK6",
          reason: "Broker logs not supported for express brokers",
        },
        {
          id: "AwsSolutions-S1",
          reason: "Access logs not needed for file transfers of public files",
        },
        {
          id: "AwsSolutions-IAM4",
          reason:
            "CDK created role for monitoring, ok to use AWS managed policies",
        },
        {
          id: "AwsSolutions-IAM5",
          reason: "Wildcards needed to allow for all topics",
        },
        {
          id: "AwsSolutions-RDS2",
          reason: "Storage encryption is enabled",
        },
        {
          id: "AwsSolutions-RDS3",
          reason: "Multi-AZ not needed for development environment",
        },
        {
          id: "AwsSolutions-RDS10",
          reason: "Deletion protection disabled for development environment",
        },
        {
          id: "AwsSolutions-RDS11",
          reason: "Default port is acceptable for development environment",
        },
        {
          id: "AwsSolutions-SMG4",
          reason: "Automatic rotation not needed for development environment",
        },
        {
          id: "AwsSolutions-IAM5",
          reason:
            "Wildcards needed for CloudWatch metrics and Kafka topic operations",
        },
      ],
      true
    );
  }
}
