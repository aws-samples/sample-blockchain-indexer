// © 2025 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
// This AWS Content is provided subject to the terms of the AWS Customer Agreement
// available at http://aws.amazon.com/agreement or other written agreement between
// Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

use std::{ env, future::Future, pin::Pin, task::{ ready, Context, Poll }, thread, time::Duration };

use aws_config::Region;
use aws_msk_iam_sasl_signer::generate_auth_token;
use clap::Parser;
use futures_util::{ FutureExt, TryStreamExt };

use kafka_exex::transform::{
    process_block_with_receipts, EmitterBlock, EmitterLog, EmitterTransaction
};
use rdkafka::{
    client::OAuthToken,
    producer::{ FutureProducer, Producer, ProducerContext },
    ClientConfig,
    ClientContext,
};
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

use dotenv::dotenv;
use tokio::{ runtime::Handle, time::timeout };

#[derive(Debug, Parser)]
pub struct ExExArgs {
    // topic prefix for this exex
    #[arg(long)]
    pub exex_topic_prefix: Option<String>,

    // topic prefix for this exex
    #[arg(long)]
    pub exex_start_block: Option<u64>,
}

struct IamProducerContext {
    region: Region,
    rt: Handle,
}

impl IamProducerContext {
    fn new(region: Region, rt: Handle) -> Self {
        Self { region, rt }
    }
}

impl ProducerContext for IamProducerContext {
    type DeliveryOpaque = ();
    fn delivery(
        &self,
        _delivery_result: &rdkafka::message::DeliveryResult<'_>,
        _delivery_opaque: Self::DeliveryOpaque
    ) {}

    fn get_custom_partitioner(&self) -> Option<&rdkafka::producer::NoCustomPartitioner> {
        None
    }
}

impl ClientContext for IamProducerContext {
    const ENABLE_REFRESH_OAUTH_TOKEN: bool = true;

    fn generate_oauth_token(
        &self,
        _oauthbearer_config: Option<&str>
    ) -> Result<OAuthToken, Box<dyn std::error::Error>> {
        let region = self.region.clone();
        let rt = self.rt.clone();

        let (token, expiration_time_ms) = {
            let handle = thread::spawn(move || {
                rt.block_on(async {
                    timeout(Duration::from_secs(10), generate_auth_token(region.clone())).await
                })
            });
            handle.join().unwrap()??
        };

        info!(token=format!("{}...{}", &token[..6], &token[token.len()-6..]), expiration_time_ms=?expiration_time_ms, "✅ Generated token");

        Ok(OAuthToken {
            token,
            principal_name: "".to_string(),
            lifetime_ms: expiration_time_ms,
        })
    }
}

struct KafkaEmitter<Node: FullNodeComponents> {
    ctx: ExExContext<Node>,

    // Kafka producer
    producer: FutureProducer<IamProducerContext>,
    topic_prefix: String,
}

impl<Node: FullNodeComponents> KafkaEmitter<Node> {
    fn new(
        mut ctx: ExExContext<Node>,
        producer: FutureProducer<IamProducerContext>,
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
                // FIXME: This would start from block 1, can't define a blocknumhash before genesis.
                let gen_hash = ctx.config.chain.genesis_hash();
                let genesis_block_num_hash = BlockNumHash { number: 0, hash: gen_hash };
                ctx.set_notifications_with_head(reth_exex::ExExHead {
                    block: genesis_block_num_hash,
                });
                info!(start_block=?genesis_block_num_hash, "Reset exex to start after");
            }
            Some(start_block) => {
                // set the start block
                let block_prior_to_start_block = start_block - 1;
                let start_block_num_hash = BlockNumHash {
                    number: block_prior_to_start_block,
                    hash: ctx.provider().block_hash(block_prior_to_start_block).unwrap().unwrap(),
                };
                ctx.set_notifications_with_head(reth_exex::ExExHead {
                    block: start_block_num_hash,
                });
                info!(start_block=?start_block_num_hash, "Reset exex to start after");
            }
        }

        let prefix = match topic_prefix {
            None => {
                // use default value <chain id>-<chain name>
                let chain_id = ctx.config.chain.chain_id();
                let chain_name = match ctx.config.chain.chain().named() {
                    Some(chain_name) => chain_name.to_string(),
                    None => chain_id.to_string(),
                };
                chain_name
            }
            Some(prefix) => {
                // set the topic prefix
                prefix
            }
        };

        info!(topic_prefix=?prefix, "Using");

        Self {
            ctx,
            producer,
            topic_prefix: prefix,
        }
    }
}

impl<Node: FullNodeComponents<Types: NodeTypes<Primitives = EthPrimitives>>> Future
for KafkaEmitter<Node> {
    type Output = eyre::Result<()>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.get_mut();

        while let Some(notification) = ready!(this.ctx.notifications.try_next().poll_unpin(cx))? {
            match &notification {
                ExExNotification::ChainCommitted { new } => {
                    info!(blocks = ?new.range(), "Received segment ");

                    // call process_committed_chain(new)
                    let producer = this.producer.clone();
                    let topic: &str = this.topic_prefix.as_ref();
                    let chain_id = this.ctx.config.chain.chain_id();
                    process_committed_chain(new, &producer, topic, chain_id);
                }
                ExExNotification::ChainReorged { old, new } => {
                    info!(from_chain = ?old.range(), to_chain = ?new.range(), "Received reorg");
                }
                ExExNotification::ChainReverted { old } => {
                    info!(reverted_chain = ?old.range(), "Received revert");
                }
            }

            if let Some(committed_chain) = notification.committed_chain() {
                // update exex to new height
                this.ctx.events.send(ExExEvent::FinishedHeight(committed_chain.tip().num_hash()))?;
            }
        }
        Poll::Ready(Ok(()))
    }
}

// read env vars from .env file
fn read_env_vars() -> (String, String) {
    dotenv().ok();
    let aws_region = env::var("AWS_REGION").unwrap_or_else(|_| "us-east-1".to_string());
    let kafka_broker = env::var("KAFKA_BROKER").unwrap_or_else(|_| "localhost:9092".to_string());
    (aws_region, kafka_broker)
}

fn create_producer(aws_region: String, kafka_broker: String) -> FutureProducer<IamProducerContext> {
    let region = Region::new(aws_region);

    info!(broker=kafka_broker.clone(), region=&region.to_string(), "Creating producer");
    let context = IamProducerContext::new(region, Handle::current());


    let producer: FutureProducer<IamProducerContext> = ClientConfig::new()
        .set("bootstrap.servers", &kafka_broker)
        .set("security.protocol", "SASL_SSL")
        .set("sasl.mechanism", "OAUTHBEARER")
        .create_with_context(context)
        .expect("❌ Producer creation error");

    let metadata = producer
        .client()
        .fetch_metadata(Option::None, Duration::from_millis(2500))
        .expect("❌ Should have fetched metadata");

    let topics = metadata.topics();
    topics.iter().for_each(|topic| {
        info!(topic=?topic.name(), "Topic");
    });

    producer
}

fn process_committed_chain(
    new: &Chain,
    producer: &FutureProducer<IamProducerContext>,
    topic_prefix: &str,
    chain_id: u64,
) {
    let start_time = std::time::Instant::now();

    let number_of_transactions = u64
        ::try_from(
            new
                .blocks_iter()
                .map(|block| { block.transaction_count() })
                .fold(0, |acc, e| acc + e)
        )
        .unwrap_or_default();

    // Clone the producer and topic to move into the future
    let producer_clone = producer.clone();


    // process blocks
    new.blocks_and_receipts().for_each(|(block, receipts)| {
        let (emitter_block, emitter_transactions) =  process_block_with_receipts(block, receipts, chain_id);

        send_block_to_kafka(&producer_clone, topic_prefix, emitter_block);

        emitter_transactions.iter().for_each(|(emitter_transaction, emitter_logs)| {
            send_transaction_to_kafka(&producer_clone, topic_prefix, emitter_transaction);

            emitter_logs.iter().for_each(|emitter_log| {
                send_log_to_kafka(&producer_clone, topic_prefix, emitter_log);
            })
        });

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

fn send_transaction_to_kafka(
    producer_clone: &FutureProducer<IamProducerContext>,
    topic_prefix: &str,
    emitter_transaction: &EmitterTransaction
) {
    let topic = format!("{}-transactions", topic_prefix);
    let key = format!(
        "{}-{}",
        emitter_transaction.block_number,
        emitter_transaction.transaction_index
    );
    let payload = serde_json::to_string(emitter_transaction).unwrap();
    let record = rdkafka::producer::future_producer::FutureRecord
        ::to(&topic)
        .key(&key)
        .payload(&payload);
    let _ = producer_clone.send_result(record);
}

fn send_log_to_kafka(
    producer_clone: &FutureProducer<IamProducerContext>,
    topic_prefix: &str,
    emitter_log: &EmitterLog
) {
    let topic = format!("{}-logs", topic_prefix);
    let key = format!(
        "{}-{}-{}",
        emitter_log.block_number,
        emitter_log.transaction_index,
        emitter_log.log_index
    );
    let payload = serde_json::to_string(emitter_log).unwrap();
    let record = rdkafka::producer::future_producer::FutureRecord
        ::to(&topic)
        .key(&key)
        .payload(&payload);
    let _ = producer_clone.send_result(record);
}

fn send_block_to_kafka(
    producer_clone: &FutureProducer<IamProducerContext>,
    topic_prefix: &str,
    emitter_block: EmitterBlock
) {
    let topic = format!("{}-blocks", topic_prefix);
    // let key = emitter_block.block_number.to_string();
    let payload = serde_json::to_string(&emitter_block).unwrap();
    let record = rdkafka::producer::future_producer::FutureRecord
        ::to(&topic)
        // .key(&key)
        .key("")
        .payload(&payload);
    let _ = producer_clone.send_result(record);
}

fn main() -> eyre::Result<()> {
    reth::cli::Cli::<EthereumChainSpecParser, ExExArgs>
        ::parse()
        .run(async move |builder, extra_args: ExExArgs| {
            let topic_prefix = extra_args.exex_topic_prefix;
            let start_block = extra_args.exex_start_block;

            // setup MSK env vars
            let (aws_region, kafka_broker) = read_env_vars();
            info!(aws_region, kafka_broker, "MSK env vars");

            let producer = create_producer(aws_region, kafka_broker);

            info!("✅ Created producer");

            let handle = builder
                .node(EthereumNode::default())
                .install_exex("kafka-emitter-exex", async move |ctx|
                    Ok(KafkaEmitter::new(ctx, producer, topic_prefix, start_block))
                )
                .launch().await?;

            handle.wait_for_node_exit().await
        })
}
