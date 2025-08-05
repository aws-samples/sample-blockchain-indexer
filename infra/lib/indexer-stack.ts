// © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
// This AWS Content is provided subject to the terms of the AWS Customer Agreement
// available at http://aws.amazon.com/agreement or other written agreement between
// Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

import * as fs from "fs";
import * as path from "path";
import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as iam from "aws-cdk-lib/aws-iam";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as msk_alpha from "@aws-cdk/aws-msk-alpha";
import * as s3tables from "@aws-cdk/aws-s3tables-alpha";
import * as msk from "aws-cdk-lib/aws-msk";
import * as nag from "cdk-nag";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as firehose from "aws-cdk-lib/aws-kinesisfirehose";
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
      // ATTENTION: If you want to change the instance you have to do it in the escape hatch
      // below too that changes the cluster to an express cluster
      instanceType: ec2.InstanceType.of(
        ec2.InstanceClass.M7G,
        ec2.InstanceSize.XLARGE
      ),
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

    // const cfnKafka = kafkaCluster.node.defaultChild as msk.CfnCluster;
    // cfnKafka.addPropertyOverride("BrokerNodeGroupInfo.InstanceType", "express.m7g.xlarge");

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

    // IAM policies and role to write to kafka
    // this policy is built in the L1Node construct so we don't need it here
    // const kafkaProducerPolicy = new iam.Policy(this, "KafkaProducerPolicy", {
    //   statements: [
    //     new iam.PolicyStatement({
    //       actions: [
    //         "kafka-cluster:Connect",
    //         "kafka-cluster:AlterCluster",
    //         "kafka-cluster:DescribeCluster",
    //       ],
    //       resources: [kafkaCluster.clusterArn],
    //     }),
    //     new iam.PolicyStatement({
    //       actions: [
    //         "kafka-cluster:*Topic*",
    //         "kafka-cluster:WriteData",
    //         "kafka-cluster:ReadData",
    //       ],
    //       resources: [topicArn],
    //     }),
    //     new iam.PolicyStatement({
    //       actions: ["kafka-cluster:AlterGroup", "kafka-cluster:DescribeGroup"],
    //       resources: [groupArn],
    //     }),
    //   ],
    // });

    // Blockchain nodes
    const holeskyNode = new Layer1Node(this, "Holesky", {
      vpc,
      mskCluster: kafkaCluster,
      instanceType: new ec2.InstanceType("i8g.2xlarge"),
      extractionVolumeSize: 2048,
    });

    // const sepoliaNode = new Layer1Node(this, "Sepolia", {
    //   vpc,
    //   mskCluster: kafkaCluster,
    //   instanceType: new ec2.InstanceType("i8g.4xlarge"),
    //   extractionVolumeSize: 4096,
    // });

    const mainnetNode = new Layer1Node(this, "Mainnet", {
      vpc,
      mskCluster: kafkaCluster,
    });

    // Create S3 bucket for data delivery
    // const s3TablesErrorBucket = new s3.Bucket(
    //   this,
    //   "blockchain-data-errorbucket",
    //   {
    //     removalPolicy: cdk.RemovalPolicy.DESTROY,
    //     autoDeleteObjects: true,
    //     encryption: s3.BucketEncryption.S3_MANAGED,
    //     enforceSSL: true,
    //     blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
    //     serverAccessLogsPrefix: "access-logs/",
    //   }
    // );

    // const icebergTablesBucket = new s3.Bucket(this, "blockchain-data-icebergtables", {
    //   removalPolicy: cdk.RemovalPolicy.DESTROY,
    //   autoDeleteObjects: true,
    //   encryption: s3.BucketEncryption.S3_MANAGED,
    //   enforceSSL: true,
    //   blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
    //   serverAccessLogsPrefix: "access-logs/",
    // });

    // // Create S3 tables bucket for S3 delivery
    // const s3TablesDeliveryBucket = new s3tables.TableBucket(
    //   this,
    //   "blockchaindata",
    //   {
    //     tableBucketName: "blockchain-data",
    //     unreferencedFileRemoval: {
    //       status: s3tables.UnreferencedFileRemovalStatus.ENABLED,
    //       noncurrentDays: 20,
    //       unreferencedDays: 20,
    //     },
    //   }
    // );

    // // Create role with write permissions to the bucket and all tables within for firehose
    // const firehoseRole = new iam.Role(this, "FirehoseDeliveryRole", {
    //   // assumedBy: new iam.ServicePrincipal("firehose.amazonaws.com"),
    //   assumedBy: new iam.CompositePrincipal(
    //     new iam.ServicePrincipal("firehose.amazonaws.com"),
    //     new iam.ServicePrincipal("glue.amazonaws.com")
    //   )
    // });


    // s3TablesDeliveryBucket.grantReadWrite(firehoseRole, "*");
    // s3TablesErrorBucket.grantReadWrite(firehoseRole, "*");
    // icebergTablesBucket.grantReadWrite(firehoseRole, "*");

    // firehoseRole.attachInlinePolicy(
    //   new iam.Policy(this, "AccessLakeFormation", {
    //     statements: [
    //       new iam.PolicyStatement({
    //         effect: iam.Effect.ALLOW,
    //         actions: [
    //           "lakeformation:GetDataAccess",
    //         ],
    //         resources: ["*"],
    //       }),
    //     ],
    //   })
    // );

    // firehoseRole.attachInlinePolicy(
    //   new iam.Policy(this, "AccessToKafka", {
    //     statements: [
    //       new iam.PolicyStatement({
    //         effect: iam.Effect.ALLOW,
    //         actions: [
    //           "kafka:CreateVpcConnection",
    //           // "kafka:DescribeClusterV2",
    //           // "kafka:DescribeCluster",
    //           "kafka:GetBootstrapBrokers",
    //           // "kafka-cluster:Connect",
    //           "kafka:DescribeCluster",
    //           "kafka:DescribeClusterV2",
    //           // "kafka-cluster:GetBootstrapBrokers",
    //           // "kafka-cluster:ReadData",
    //         ],
    //         resources: [kafkaCluster.clusterArn],
    //       }),
    //       new iam.PolicyStatement({
    //         actions: [
    //           "kafka-cluster:Connect",
    //           "kafka-cluster:DescribeCluster",
    //         ],
    //         resources: [kafkaCluster.clusterArn],
    //       }),
    //       new iam.PolicyStatement({
    //         actions: [
    //           "kafka-cluster:*Topic*",
    //           "kafka-cluster:ReadData",
    //         ],
    //         resources: [topicArn],
    //       }),
    //       new iam.PolicyStatement({
    //         actions: [
    //           "kafka-cluster:DescribeGroup",
    //         ],
    //         resources: [groupArn],
    //       }),
    //     ],
    //   })
    // );


    // firehoseRole.attachInlinePolicy(
    //   new iam.Policy(this, "Glue", {
    //     statements: [
    //       new iam.PolicyStatement({
    //         effect: iam.Effect.ALLOW,
    //         actions: [
    //           "glue:GetTable",
    //           "glue:GetTableVersion",
    //           "glue:GetTableVersions",
    //           "glue:GetDatabase",
    //           "glue:UpdateTable",
    //         ],
    //         resources: [
    //           "arn:aws:glue:" +
    //             `${cdk.Stack.of(this).region}:` +
    //             `${cdk.Stack.of(this).account}:` +
    //             "catalog",
    //           "arn:aws:glue:" +
    //             `${cdk.Stack.of(this).region}:` +
    //             `${cdk.Stack.of(this).account}:` +
    //             "catalog/s3tablescatalog",
    //           "arn:aws:glue:" +
    //             `${cdk.Stack.of(this).region}:` +
    //             `${cdk.Stack.of(this).account}:` +
    //             "catalog/s3tablescatalog/*",
    //           "arn:aws:glue:" +
    //             `${cdk.Stack.of(this).region}:` +
    //             `${cdk.Stack.of(this).account}:` +
    //             "database/*",
    //           "arn:aws:glue:" +
    //             `${cdk.Stack.of(this).region}:` +
    //             `${cdk.Stack.of(this).account}:` +
    //             "table/*/*",
    //         ],
    //       }),
    //     ],
    //   })
    // );

    // firehoseRole.attachInlinePolicy(new iam.Policy(this, "CloudwatchLogging", {
    //   statements: [
    //     new iam.PolicyStatement({
    //       effect: iam.Effect.ALLOW,
    //       actions: [
    //         "logs:PutLogEvents",
    //         "logs:DescribeLogStreams",
    //         "logs:CreateLogStream",
    //       ],
    //       resources: [
    //         "arn:aws:logs:" +
    //           `${cdk.Stack.of(this).region}:` +
    //           `${cdk.Stack.of(this).account}:` +
    //           "log-group:/aws/kinesisfirehose/*",
    //       ],
    //     }),
    //   ],
    // }))

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

    new cdk.CfnOutput(this, "HoleskyNode", {
      value: holeskyNode.instanceId,
    });

    // new cdk.CfnOutput(this, "SepoliaNode", {
    //   value: sepoliaNode.instanceId,
    // });

    new cdk.CfnOutput(this, "MainnetNode", {
      value: mainnetNode.instanceId,
    });

    // CDK Nag suppressions
    nag.NagSuppressions.addResourceSuppressions(
      this,
      [
        {
          id: "AwsSolutions-MSK6",
          reason: "Broker logs not supported for express brokers",
        },
        // {
        //   id: "AwsSolutions-EC29",
        //   reason: "stateless mgmt machine, can be deleted w/o loss",
        // },
        // {
        //   id: "AwsSolutions-IAM4",
        //   reason: "Development machine, ok to use AWS managed policies",
        // },
        {
          id: "AwsSolutions-IAM5",
          reason: "Wildcards needed to allow for all topics",
        },
      ],
      true
    );
  }
}
