// © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
// This AWS Content is provided subject to the terms of the AWS Customer Agreement
// available at http://aws.amazon.com/agreement or other written agreement between
// Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.
package com.amazonaws.indexer;

public class PunkTransfer {
    public int punkIndex;
    public int logIndex;
    public int txIndex;
    public String from;
    public String to;
    public long blockNumber;
    public String transactionHash;

    // toString function for the class
    @Override
    public String toString() {
        return String.format("PunkTransfer[punkIndex=%s, from=%s, to=%s, blockNumber=%d, transactionHash=%s, logIdx=%s, txIdx=%s]",
                punkIndex, from, to, blockNumber, transactionHash, logIndex, txIndex);
    }
}
