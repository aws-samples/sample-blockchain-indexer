// © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
// This AWS Content is provided subject to the terms of the AWS Customer Agreement
// available at http://aws.amazon.com/agreement or other written agreement between
// Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

import * as fs from "fs";
import * as path from "path";
import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as msk_alpha from "@aws-cdk/aws-msk-alpha";
import * as nag from "cdk-nag";
import { Asset } from "aws-cdk-lib/aws-s3-assets";

export interface Layer1NodeProps extends cdk.StackProps {
  readonly instanceType?: ec2.InstanceType;
  readonly extractionVolumeSize?: number;
  readonly vpc?: ec2.IVpc;
  readonly mskCluster: msk_alpha.ICluster;
}

export class Layer1Node extends Construct {
  readonly instanceType: ec2.InstanceType;
  readonly extractionVolumeSize: number;
  readonly vpc: ec2.IVpc;
  readonly mskCluster: msk_alpha.ICluster;

  public instanceId: string;
  public instance: ec2.Instance;

  constructor(scope: Construct, id: string, props?: Layer1NodeProps) {
    super(scope, id);

    this.vpc = props?.vpc || ec2.Vpc.fromLookup(this, "DefaultVPC", { isDefault: true });

    // this.mskClusterArn = props?.mskClusterArn as string;
    this.mskCluster = props?.mskCluster || new msk_alpha.Cluster(this, "MskCluster", {
      clusterName: "Layer1NodeCluster",
      kafkaVersion: msk_alpha.KafkaVersion.V3_6_0,
      encryptionInTransit: {
        clientBroker: msk_alpha.ClientBrokerEncryption.TLS,
      },
      vpc: this.vpc,
    });

    this.instanceType =
      props?.instanceType ||
      ec2.InstanceType.of(ec2.InstanceClass.I8G, ec2.InstanceSize.XLARGE4);
    this.extractionVolumeSize = props?.extractionVolumeSize || 10000;

    // get msk cluster
    // const kafkaCluster = msk_alpha.Cluster.fromClusterArn(
    //   this,
    //   "KafkaCluster",
    //   this.mskClusterArn
    // );

    const instanceRole = new iam.Role(this, "NodeRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName(
          "AmazonSSMManagedInstanceCore"
        ),
        iam.ManagedPolicy.fromAwsManagedPolicyName(
          "CloudWatchAgentServerPolicy"
        ),
        iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonS3FullAccess"),
      ],
    });

    // allow to modify throughput in userdata
    instanceRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: [
          "ec2:DescribeVolumes",
          "ec2:AttachVolume",
          "ec2:ModifyVolume",
        ],
        resources: ["*"],
      })
    );

    // allow EC2 to write to Kafka
    const topicArn = `arn:aws:kafka:${cdk.Stack.of(this).region}:${
      cdk.Stack.of(this).account
    }:topic/${this.mskCluster.clusterName}/*`;
    const groupArn = `arn:aws:kafka:${cdk.Stack.of(this).region}:${
      cdk.Stack.of(this).account
    }:group/${this.mskCluster.clusterName}/*`;

    // IAM policies and role to write to kafka
    const kafkaProducerPolicy = new iam.Policy(this, "KafkaProducerPolicy", {
      statements: [
        new iam.PolicyStatement({
          actions: [
            "kafka:ListClusters",
            "kafka:ListClustersV2",
            "kafka:GetBootstrapBrokers",
          ],
          resources: ["*"],
        }),
        new iam.PolicyStatement({
          actions: [
            "kafka-cluster:Connect",
            "kafka-cluster:AlterCluster",
            "kafka-cluster:DescribeCluster",
          ],
          resources: [this.mskCluster.clusterArn],
        }),
        new iam.PolicyStatement({
          actions: [
            "kafka-cluster:*Topic*",
            "kafka-cluster:WriteData",
            "kafka-cluster:ReadData",
          ],
          resources: [topicArn],
        }),
        new iam.PolicyStatement({
          actions: ["kafka-cluster:AlterGroup", "kafka-cluster:DescribeGroup"],
          resources: [groupArn],
        }),
      ],
    });

    instanceRole.attachInlinePolicy(kafkaProducerPolicy);

    // Sepolia Node
    const userData = ec2.UserData.forLinux();

    // create asset with monitor_extraction files
    const monitorExtractionAsset = new Asset(this, "MonitorExtractionAsset", {
      path: path.join(__dirname, "../assets/monitor_extraction"),
    });

    // copy monitor_extraction files to instance
    userData.addCommands(
      `aws s3 cp ${monitorExtractionAsset.s3ObjectUrl} /tmp/monitor_extraction.zip`
    );

    // last Block script asset
    const lastBlockAsset = new Asset(this, "LastBlockAsset", {
      path: path.join(__dirname, "../assets/lastBlock"),
    });

    userData.addCommands(
      `aws s3 cp ${lastBlockAsset.s3ObjectUrl} /tmp/lastBlock.zip`
    );

    // last Block script asset
    const monitorKafkaAsset = new Asset(this, "MonitorKafkaAsset", {
      path: path.join(__dirname, "../assets/monitor_kafka"),
    });

    userData.addCommands(
      `aws s3 cp ${monitorKafkaAsset.s3ObjectUrl} /tmp/monitor_kafka.zip`
    );

    // scripts
    const scriptsAsset = new Asset(this, "ScriptsAsset", {
      path: path.join(__dirname, "../assets/scripts"),
    });

    userData.addCommands(
      `aws s3 cp ${scriptsAsset.s3ObjectUrl} /tmp/scripts.zip`
    );

    // ../assets/sepolia-node-instancestore-userdata.sh is the template for the userdata script
    const commands = fs.readFileSync(
      path.join(__dirname, "../assets/layer1-node-userdata.sh"),
      "utf8"
    ).replace("__KAFKA_CLUSTER_ARN__", this.mskCluster.clusterArn);

    userData.addCommands(commands);

    // volumes
    // Define block devices array
    const blockDevices: ec2.BlockDevice[] = [
      // Root volume
      {
        deviceName: "/dev/xvda",
        volume: ec2.BlockDeviceVolume.ebs(64, {
          encrypted: true,
        }),
      },
      // Cryo extraction volume
      {
        deviceName: "/dev/sdf",
        volume: ec2.BlockDeviceVolume.ebs(this.extractionVolumeSize, {
          encrypted: true,
        }),
      },
    ];

    const node = new ec2.Instance(this, "node", {
      instanceType: this.instanceType,
      machineImage: new ec2.AmazonLinuxImage({
        generation: ec2.AmazonLinuxGeneration.AMAZON_LINUX_2023,
        cpuType: ec2.AmazonLinuxCpuType.ARM_64,
      }),
      blockDevices: blockDevices,
      vpc: this.vpc,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PUBLIC,
      },
      detailedMonitoring: true,
      userData: userData,
      role: instanceRole,
    });

    // ingress rules
    node.connections.allowFromAnyIpv4(ec2.Port.tcp(9000), "P2P traffic, Lighthouse");
    node.connections.allowFromAnyIpv4(ec2.Port.udp(9000), "P2P traffic, Lighthouse");
    node.connections.allowFromAnyIpv4(ec2.Port.udp(9001), "P2P traffic, Lighthouse");

    node.connections.allowFromAnyIpv4(ec2.Port.tcp(30303), "P2P traffic, reth");
    node.connections.allowFromAnyIpv4(ec2.Port.udp(30303), "P2P traffic, reth");
    node.connections.allowFrom( ec2.Peer.ipv4(this.vpc.vpcCidrBlock), ec2.Port.tcp(8545), "RPC queries, reth" );
    node.connections.allowFrom( ec2.Peer.ipv4(this.vpc.vpcCidrBlock), ec2.Port.tcp(8546), "WS queries, reth" );
    node.connections.allowFrom( ec2.Peer.ipv4(this.vpc.vpcCidrBlock), ec2.Port.tcp(9001), "metrics, reth" );

    monitorExtractionAsset.grantRead(node);
    lastBlockAsset.grantRead(node);
    monitorKafkaAsset.grantRead(node);
    scriptsAsset.grantRead(node);

    this.instance = node;
    this.instanceId = node.instanceId;

    // // Cfn outputs
    // new cdk.CfnOutput(this, "InstanceId", {
    //   value: node.instanceId,
    // });

    // new cdk.CfnOutput(this, "InstancePrivateIp", {
    //   value: node.instancePrivateIp,
    // });

    // new cdk.CfnOutput(this, "RpcUrl", {
    //   value: `http://${node.instancePrivateIp}:8545`,
    // });

    // CDK Nag suppressions
    nag.NagSuppressions.addResourceSuppressions(
      this,
      [
        {
          id: "AwsSolutions-EC23",
          reason: "Blockchian syncs on port 30303 with nodes on the internet",
        },
        {
          id: "AwsSolutions-EC26",
          reason: "false positive - ephemeral drive is encrypted by default",
        },
        {
          id: "AwsSolutions-EC29",
          reason: "Deletion protection disables intentionally for DEV purposes",
        },
        {
          id: "AwsSolutions-IAM4",
          reason: "Standards apply",
        },
        {
          id: "AwsSolutions-IAM5",
          reason: "Standards apply",
        },
      ],
      true
    );
  }
}
