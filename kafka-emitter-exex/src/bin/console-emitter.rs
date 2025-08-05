// © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
// This AWS Content is provided subject to the terms of the AWS Customer Agreement
// available at http://aws.amazon.com/agreement or other written agreement between
// Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.


use std::{ future::Future, pin::Pin, task::{ ready, Context, Poll } };
use clap::Parser;
use futures_util::{ FutureExt, TryStreamExt };

use kafka_exex::transform::
    // get_all_logs,
    process_block_with_receipts
;
use reth::{
    api::FullNodeComponents,
    builder::NodeTypes,
    chainspec::{ EthChainSpec, EthereumChainSpecParser },
    primitives::EthPrimitives,
    providers::BlockHashReader,
    rpc::types::BlockNumHash,
};
use reth_execution_types::Chain;
use reth_exex::{ ExExContext, ExExEvent, ExExNotification };
use reth_node_ethereum::EthereumNode;
use reth_tracing::tracing::info;

struct ConsoleEmitter<Node: FullNodeComponents> {
    ctx: ExExContext<Node>,
}

#[derive(Debug, Parser)]
pub struct ExExArgs {
    // topic prefix for this exex
    #[arg(long)]
    pub exex_topic_prefix: Option<String>,

    // topic prefix for this exex
    #[arg(long)]
    pub exex_start_block: Option<u64>,
}

impl<Node: FullNodeComponents> ConsoleEmitter<Node> {
    fn new(
        mut ctx: ExExContext<Node>,
        topic_prefix: Option<String>,
        start_block: Option<u64>
    ) -> Self {
        match start_block {
            None => {
                // do not reset start block, continue onwards
                info!("Exex start where it left off");
            }
            Some(0) => {
                // reset the exex to start from the genesis block again
                let gen_hash = ctx.config.chain.genesis_hash();
                let genesis_block_num_hash = BlockNumHash { number: 0, hash: gen_hash };
                ctx.set_notifications_with_head(reth_exex::ExExHead {
                    block: genesis_block_num_hash,
                });
                info!(start_block=?genesis_block_num_hash, "Reset exex to");
            }
            Some(start_block) => {
                // set the start block
                // let provider = ctx.provider().clone();
                let start_block_num_hash = BlockNumHash {
                    number: start_block,
                    hash: ctx.provider().block_hash(start_block).unwrap().unwrap(),
                };
                ctx.set_notifications_with_head(reth_exex::ExExHead {
                    block: start_block_num_hash,
                });
                info!(start_block=?start_block_num_hash, "Reset exex to");
            }
        }

        let prefix = match topic_prefix {
            None => {
                // use default value <chain id>-<chain name>
                let chain_id = ctx.config.chain.chain_id();
                let chain_name = ctx.config.chain.chain().named().unwrap().to_string();
                format!("{}-{}", chain_id, &chain_name)
            }
            Some(prefix) => {
                // set the topic prefix
                prefix
            }
        };

        info!(topic_prefix=?prefix, "Using");

        Self {
            ctx,
        }
    }
}

impl<Node: FullNodeComponents<Types: NodeTypes<Primitives = EthPrimitives>>> Future
for ConsoleEmitter<Node> {
    type Output = eyre::Result<()>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.get_mut();

        while let Some(notification) = ready!(this.ctx.notifications.try_next().poll_unpin(cx))? {
            match &notification {
                ExExNotification::ChainCommitted { new } => {
                    info!(blocks = ?new.range(), "Received segment ");
                    let chain_id = this.ctx.config.chain.chain_id();
                    process_committed_chain(new, chain_id);
                }
                ExExNotification::ChainReorged { old, new } => {
                    info!(from_chain = ?old.range(), to_chain = ?new.range(), "Received reorg");
                }
                ExExNotification::ChainReverted { old } => {
                    info!(reverted_chain = ?old.range(), "Received revert");
                }
            }

            if let Some(committed_chain) = notification.committed_chain() {
                this.ctx.events.send(ExExEvent::FinishedHeight(committed_chain.tip().num_hash()))?;
            }
        }
        Poll::Ready(Ok(()))
    }
}

pub fn process_committed_chain(new: &Chain, chain_id: u64) {
    let start_time = std::time::Instant::now();

    let number_of_transactions = u64
        ::try_from(
            new
                .blocks_iter()
                .map(|block| { block.transaction_count() })
                .fold(0, |acc, e| acc + e)
        )
        .unwrap_or_default();

    new.blocks_and_receipts().for_each(|(block, receipts)| {
        if block.transaction_count() > 0 {

            let (emitter_block, emitter_transactions) = process_block_with_receipts(block, receipts, chain_id);

            info!(payload=serde_json::to_string(&emitter_block).unwrap(), "block");
            emitter_transactions.iter().for_each(|(emitter_transaction, emitter_logs)| {
                info!(payload=serde_json::to_string(&emitter_transaction).unwrap(), "transaction");

                emitter_logs.iter().for_each(|emitter_log| {
                    info!(payload=serde_json::to_string(&emitter_log).unwrap(), "Log");
                })
            });
        }
    });

    log_segment_processed(new, start_time, number_of_transactions);
}


fn log_segment_processed(new: &Chain, start_time: std::time::Instant, number_of_transactions: u64) {
    let processed_blocks = new.tip().number - new.first().number + 1;
    let blocks_per_second = (processed_blocks as f64) / start_time.elapsed().as_secs_f64();
    let tx_per_second = (number_of_transactions as f64) / start_time.elapsed().as_secs_f64();
    info!(
        blocks = ?new.range(),
        processed_blocks,
        blocks_per_second,
        transactions=number_of_transactions,
        tx_per_second,
        "Processed segment"
    )
}

fn main() -> eyre::Result<()> {
    reth::cli::Cli::<EthereumChainSpecParser, ExExArgs>
        ::parse()
        .run(async move |builder, extra_args: ExExArgs| {
            let topic_prefix = extra_args.exex_topic_prefix;
            let start_block = extra_args.exex_start_block;
            let handle = builder
                .node(EthereumNode::default())
                .install_exex("kafka-emitter-exex", async move |ctx|
                    Ok(ConsoleEmitter::new(ctx, topic_prefix, start_block))
                )
                .launch().await?;

            handle.wait_for_node_exit().await
        })
}
