// © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
// This AWS Content is provided subject to the terms of the AWS Customer Agreement
// available at http://aws.amazon.com/agreement or other written agreement between
// Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.
package com.amazonaws.indexer;

import java.util.HashMap;
import java.util.Map;
import java.util.Properties;

import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.shaded.jackson2.com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.kafka.common.TopicPartition;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import com.amazonaws.services.kinesisanalytics.runtime.KinesisAnalyticsRuntime;

public class PunkTransferProcessor {

    private static final Logger LOG = LoggerFactory.getLogger(PunkTransferProcessor.class);

    // Signatures for:  event PunkTransfer(address indexed from, address indexed to, uint256 punkIndex)
    private static final String PUNK_TRANSFER_EVENT
            = "0x05af636b70da6819000c49f85b21fa82081c632069bb626f30932034099107d8";

    // event Assign(address indexed to, uint256 punkIndex)
    private static final String PUNK_ASSIGN_EVENT
            = "0x8a0e37b73a0d9c82e205d4d1a3ff3d0b57ce5f4d7bccf6bac03336dc101cb7ba";
    private static final String PUNKS_CONTRACT_ADDRESS = "0xb47e3cd837ddf8e4c57f05d70ab865de6e193bbb";
    private static final long PUNKS_DEPLOYMENT_BLOCK = 3914495;
    private static final String ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

    public static void main(String[] args) throws Exception {
        LOG.info("Program running");

        Map<String, Properties> applicationProperties = KinesisAnalyticsRuntime.getApplicationProperties();

        final StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

        final String MSK_BOOTSTRAP_SERVERS = applicationProperties.get("config").getProperty("MSK_BOOTSTRAP_SERVERS", "msk");
        final String KAFKA_TOPIC = applicationProperties.get("config").getProperty("KAFKA_TOPIC", "ethereum-logs");
        final String KAFKA_GROUP_ID = applicationProperties.get("config").getProperty("KAFKA_GROUP_ID", "punk-transfer-processor");
        LOG.info(" MSK_BOOTSTRAP_SERVERS: {}, KAFKA_TOPIC: {}, KAFKA_GROUP_ID: {}",
                MSK_BOOTSTRAP_SERVERS, KAFKA_TOPIC, KAFKA_GROUP_ID);

        // Create Kafka source with specific offset for partition 0
        Map<TopicPartition, Long> specificOffsets = new HashMap<>();
        specificOffsets.put(new TopicPartition(KAFKA_TOPIC, 0), 0L);

        // Create Kafka source
        KafkaSource<String> kafkaSource
                = KafkaSource.<String>builder()
                        .setBootstrapServers(MSK_BOOTSTRAP_SERVERS)
                        .setTopics(KAFKA_TOPIC)
                        .setGroupId(KAFKA_GROUP_ID)
                        .setProperty("security.protocol", "SASL_SSL")
                        .setProperty("sasl.mechanism", "AWS_MSK_IAM")
                        .setProperty(
                                "sasl.jaas.config", "software.amazon.msk.auth.iam.IAMLoginModule required;")
                        .setProperty(
                                "sasl.client.callback.handler.class",
                                "software.amazon.msk.auth.iam.IAMClientCallbackHandler")
                        .setStartingOffsets(OffsetsInitializer.offsets(specificOffsets))
                        .setProperty("commit.offsets.on.checkpoint", "true")
                        .setValueOnlyDeserializer(new SimpleStringSchema())
                        .build();

        LOG.info("Kafka Source setup");

        ObjectMapper mapper = new ObjectMapper();

        LOG.info("Object Mapper setup");

        // Create the processing pipeline
        DataStream<PunkTransfer> transfers
                = env.fromSource(kafkaSource, WatermarkStrategy.noWatermarks(), "Kafka Source")
                        .map(jsonString -> mapper.readValue(jsonString, EmitterLog.class))
                        .filter(
                                log
                                -> (log.block_number > PUNKS_DEPLOYMENT_BLOCK
                                && log.address != null
                                && log.address.equals(PUNKS_CONTRACT_ADDRESS)
                                && log.topic0 != null
                                && (log.topic0.equals(PUNK_TRANSFER_EVENT)
                                || log.topic0.equals(PUNK_ASSIGN_EVENT))))
                        .map(
                                (EmitterLog log) -> {
                                    PunkTransfer transfer = new PunkTransfer();
                                    transfer.punkIndex = Integer.parseInt(log.data.substring(2), 16);
                                    transfer.logIndex = (int) log.log_index;
                                    transfer.txIndex = (int) log.transaction_index;
                                    transfer.blockNumber = log.block_number;
                                    transfer.transactionHash = log.transaction_hash;

                                    if (log.topic0.equals(PUNK_ASSIGN_EVENT)) {
                                        transfer.from = ZERO_ADDRESS;
                                        transfer.to = "0x" + log.topic1.substring(26);
                                    } else {
                                        transfer.from = "0x" + log.topic1.substring(26);
                                        transfer.to = "0x" + log.topic2.substring(26);
                                    }
                                    return transfer;
                                });

        transfers.addSink(new CloudWatchLogSink<>());

        // TODO Here could be other sinks like RDS

        // Add shutdown hook to clean up resources
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            LOG.info("Shutting down application, cleaning up resources");
            //     connectionProvider.close();
        }));
        env.execute("Punk Transfer Processor");
    }
}
