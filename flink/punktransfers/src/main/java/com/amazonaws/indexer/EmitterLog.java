// © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
// This AWS Content is provided subject to the terms of the AWS Customer Agreement
// available at http://aws.amazon.com/agreement or other written agreement between
// Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.
package com.amazonaws.indexer;

public class EmitterLog {
    public long block_number;
    public long transaction_index;
    public long log_index;
    public String transaction_hash;
    public String address;
    public String topic0;
    public String topic1;
    public String topic2;
    public String topic3;
    public String data;
    public long chain_id;
    public String block_hash;

@Override
public String toString() {
    return String.format("EmitterLog[block=%d, txIdx=%d, logIdx=%d, txHash=%s, addr=%s, " +
            "topics=[%s,%s,%s,%s], data=%s, chainId=%d, blockHash=%s]",
        block_number, transaction_index, log_index, transaction_hash, address,
        topic0, topic1, topic2, topic3, data, chain_id, block_hash);
}
}