// © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
// This AWS Content is provided subject to the terms of the AWS Customer Agreement
// available at http://aws.amazon.com/agreement or other written agreement between
// Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.
package com.amazonaws.indexer;

import org.apache.flink.streaming.api.functions.sink.SinkFunction;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class CloudWatchLogSink<T> implements SinkFunction<T> {
    private static final Logger LOG = LoggerFactory.getLogger(CloudWatchLogSink.class);

    @Override
    public void invoke(T value, Context context) {
        LOG.info("Received value: {}", value);
    }
}