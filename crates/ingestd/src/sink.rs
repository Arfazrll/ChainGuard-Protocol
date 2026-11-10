//! Where ingestion publishes [`StreamMessage`]s. `publish` must return only
//! once the messages are durable; the caller commits tracker state after it.

use anyhow::{Context, Result};
use chainguard_ingest_core::StreamMessage;
use rskafka::chrono::{DateTime, Utc};
use rskafka::client::partition::{Compression, PartitionClient, UnknownTopicHandling};
use rskafka::client::{Client, ClientBuilder};
use rskafka::record::Record;
use std::collections::BTreeMap;
use tokio::io::AsyncWriteExt;

/// Records per produce request; keeps requests well under broker limits even
/// for log-heavy blocks.
const KAFKA_BATCH: usize = 256;

pub enum Sink {
    Jsonl(JsonlSink),
    Kafka(KafkaSink),
}

impl Sink {
    pub async fn publish(&mut self, msgs: &[StreamMessage]) -> Result<()> {
        match self {
            Sink::Jsonl(s) => s.publish(msgs).await,
            Sink::Kafka(s) => s.publish(msgs).await,
        }
    }
}

pub struct JsonlSink {
    out: Box<dyn tokio::io::AsyncWrite + Unpin + Send>,
}

impl JsonlSink {
    pub async fn open(path: &str) -> Result<Self> {
        let out: Box<dyn tokio::io::AsyncWrite + Unpin + Send> = if path == "-" {
            Box::new(tokio::io::stdout())
        } else {
            let f = tokio::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .await
                .with_context(|| format!("opening {path}"))?;
            Box::new(f)
        };
        Ok(Self { out })
    }

    async fn publish(&mut self, msgs: &[StreamMessage]) -> Result<()> {
        let mut buf = Vec::with_capacity(msgs.len() * 512);
        for m in msgs {
            serde_json::to_writer(&mut buf, m)?;
            buf.push(b'\n');
        }
        self.out.write_all(&buf).await?;
        self.out.flush().await?;
        Ok(())
    }
}

pub struct KafkaSink {
    _client: Client,
    partition: PartitionClient,
    chain_key: Vec<u8>,
}

impl KafkaSink {
    pub async fn connect(
        brokers: Vec<String>,
        topic: &str,
        chain_id: u64,
        create_topic: bool,
        replication_factor: i16,
    ) -> Result<Self> {
        let client = ClientBuilder::new(brokers.clone())
            .client_id("chainguard-ingestd")
            .build()
            .await
            .with_context(|| format!("connecting to {brokers:?}"))?;
        if create_topic {
            let exists = client.list_topics().await?.iter().any(|t| t.name == topic);
            if !exists {
                client
                    .controller_client()?
                    .create_topic(topic, 1, replication_factor, 5_000)
                    .await
                    .with_context(|| format!("creating topic {topic}"))?;
                tracing::info!(topic, "created topic (1 partition: total order per chain)");
            }
        }
        let partition = client
            .partition_client(topic.to_owned(), 0, UnknownTopicHandling::Retry)
            .await
            .with_context(|| format!("opening {topic}/0"))?;
        Ok(Self {
            _client: client,
            partition,
            chain_key: chain_id.to_string().into_bytes(),
        })
    }

    async fn publish(&mut self, msgs: &[StreamMessage]) -> Result<()> {
        // rskafka's chrono is built without the `clock` feature.
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_millis();
        let timestamp = DateTime::<Utc>::from_timestamp_millis(now_ms as i64).unwrap_or_default();
        for chunk in msgs.chunks(KAFKA_BATCH) {
            let records = chunk
                .iter()
                .map(|m| {
                    let headers = BTreeMap::from([
                        ("type".to_owned(), m.kind().as_bytes().to_vec()),
                        ("seq".to_owned(), m.seq().to_string().into_bytes()),
                    ]);
                    Ok(Record {
                        key: Some(self.chain_key.clone()),
                        value: Some(serde_json::to_vec(m)?),
                        headers,
                        timestamp,
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            self.partition
                .produce(records, Compression::NoCompression)
                .await
                .context("produce")?;
        }
        Ok(())
    }
}
