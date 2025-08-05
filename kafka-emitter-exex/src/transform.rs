// © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
// This AWS Content is provided subject to the terms of the AWS Customer Agreement
// available at http://aws.amazon.com/agreement or other written agreement between
// Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

use alloy::{
    consensus::{ BlockHeader, Transaction, TxReceipt },
    primitives::{ Address, Bloom, Bytes, FixedBytes },
};

use reth::primitives::{ TransactionSigned, Receipt };

// structs for serializing
#[derive(Debug, serde::Serialize)]
pub struct EmitterBlock {
    pub block_hash: FixedBytes<32>,
    pub parent_hash: FixedBytes<32>,
    pub author: Address,
    pub state_root: FixedBytes<32>,
    pub transactions_root: FixedBytes<32>,
    pub receipts_root: FixedBytes<32>,
    pub block_number: u64,
    pub gas_used: u64,
    pub gas_limit: u64,
    pub extra_data: Bytes,
    pub logs_bloom: Bloom,
    pub timestamp: u64,
    pub difficulty: u64,
    pub size: usize,
    pub mix_hash: FixedBytes<32>,
    pub nonce: FixedBytes<8>,
    pub base_fee_per_gas: u64,
    pub withdrawals_root: Option<FixedBytes<32>>,
    pub chain_id: u64,
}

#[derive(Debug, serde::Serialize)]
pub struct EmitterTransaction {
    pub block_number: u64,
    pub transaction_index: u64,
    pub transaction_hash: FixedBytes<32>,
    pub nonce: u64,
    pub from_address: Address,
    pub to_address: Address,
    pub value_string: String,
    pub input: Bytes,
    pub gas_limit: u64,
    pub gas_used: u64,
    pub gas_price: Option<u128>,
    pub transaction_type: u32,
    pub max_priority_fee_per_gas: Option<u128>,
    pub max_fee_per_gas: u128,
    pub success: bool,
    pub chain_id: u64,
    pub block_hash: FixedBytes<32>,
    pub timestamp: u64,
}

#[derive(Debug, serde::Serialize)]
pub struct EmitterReceipt {
    pub success: bool,
    pub cumulative_gas_used: u64,
    pub logs: Vec<EmitterLog>,
}

#[derive(Debug, serde::Serialize)]
pub struct EmitterLog {
    pub block_number: u64,
    pub transaction_index: u64,
    pub log_index: u64,
    pub transaction_hash: FixedBytes<32>,
    pub address: Address,
    pub topic0: FixedBytes<32>,
    pub topic1: FixedBytes<32>,
    pub topic2: FixedBytes<32>,
    pub topic3: FixedBytes<32>,
    pub data: Bytes,
    pub chain_id: u64,
    pub block_hash: FixedBytes<32>,
}

pub fn process_committed_block(
    block: &reth::primitives::RecoveredBlock<alloy::consensus::Block<TransactionSigned>>,
    chain_id: u64
) -> EmitterBlock {
    EmitterBlock {
        block_hash: block.hash(),
        parent_hash: block.parent_hash,
        author: block.header().beneficiary,
        state_root: block.transactions_root,
        transactions_root: block.transactions_root,
        receipts_root: block.receipts_root,
        block_number: block.number,
        gas_used: block.gas_used(),
        gas_limit: block.gas_limit(),
        extra_data: block.extra_data.clone(),
        logs_bloom: block.logs_bloom(),
        timestamp: block.timestamp(),
        difficulty: block.difficulty.to::<u64>(),
        size: block.size(),
        mix_hash: block.mix_hash().unwrap(),
        nonce: block.nonce,
        base_fee_per_gas: block.base_fee_per_gas.unwrap_or_default(),
        withdrawals_root: block.withdrawals_root,
        chain_id: chain_id,
    }
}

pub fn process_block_with_receipts(
    block: &reth::primitives::RecoveredBlock<alloy::consensus::Block<reth::primitives::TransactionSigned>>,
    receipts: &Vec<reth::primitives::Receipt>,
    chain_id: u64
) -> (EmitterBlock, Vec<(EmitterTransaction, Vec<EmitterLog>)>) {
    // block
    let emitter_block = process_committed_block(block, chain_id);

    // transactions + logs
    let emitter_transactions = process_transactions_in_block(block, receipts, chain_id);

    (emitter_block, emitter_transactions)
}

pub fn process_transactions_in_block(
    block: &reth::primitives::RecoveredBlock<alloy::consensus::Block<TransactionSigned>>,
    receipts: &Vec<Receipt>,
    chain_id: u64
) -> Vec<(EmitterTransaction, Vec<EmitterLog>)> {
    let transactions = block
        .transactions_with_sender()
        .enumerate()
        .map(|(tx_index, (sender, transaction))| {
            let tx_hash = transaction.hash();

            let logs = receipts[tx_index].logs.clone();

            let emitter_logs: Vec<EmitterLog> = logs
                .iter()
                .enumerate()
                .map(|(log_index, log)| {
                    EmitterLog {
                        block_hash: block.hash(),
                        block_number: block.number,
                        transaction_hash: *tx_hash,
                        transaction_index: tx_index as u64,
                        log_index: log_index as u64,
                        address: log.address,
                        topic0: log.topics().get(0).copied().unwrap_or_default(),
                        topic1: log.topics().get(1).copied().unwrap_or_default(),
                        topic2: log.topics().get(2).copied().unwrap_or_default(),
                        topic3: log.topics().get(3).copied().unwrap_or_default(),
                        data: log.data.data.clone(),
                        chain_id: chain_id,
                    }
                })
                .collect();

            let emitter_transaction = EmitterTransaction {
                transaction_hash: tx_hash.clone(),
                nonce: transaction.nonce(),
                input: transaction.input().clone(),
                block_hash: block.hash(),
                block_number: block.number,
                timestamp: block.timestamp(),
                transaction_index: tx_index as u64,
                from_address: sender.clone(),
                to_address: transaction.to().unwrap_or_default(),
                value_string: transaction.value().to_string(),
                gas_limit: transaction.gas_limit(),
                gas_price: transaction.gas_price(),
                max_fee_per_gas: transaction.max_fee_per_gas(),
                max_priority_fee_per_gas: transaction.max_priority_fee_per_gas(),
                transaction_type: transaction.tx_type() as u32,
                success: receipts[tx_index].status(),
                gas_used: receipts[tx_index].cumulative_gas_used,
                chain_id: chain_id,
            };
            (emitter_transaction, emitter_logs)
        })
        .collect();

    transactions
}
