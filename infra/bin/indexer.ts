#!/usr/bin/env node

// © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
// This AWS Content is provided subject to the terms of the AWS Customer Agreement
// available at http://aws.amazon.com/agreement or other written agreement between
// Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

import * as cdk from 'aws-cdk-lib';
import * as nag from "cdk-nag";

import { IndexerStack } from '../lib/indexer-stack';

const app = new cdk.App();

const indexerStack = new IndexerStack(app, 'Indexer', {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },
})

// Security Check
cdk.Aspects.of(app).add(
  new nag.AwsSolutionsChecks({
      verbose: false,
      reports: true,
      logIgnores: false,
  })
);