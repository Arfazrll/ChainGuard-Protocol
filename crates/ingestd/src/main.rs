//! `chainguard-ingestd`: reorg-safe, multi-node-verified chain ingestion.
//!
//! Read-only by design: this process holds no keys and can only issue the
//! read methods on `chainguard_rpc::ALLOWED_METHODS`.

mod checkpoint;
mod config;
mod sink;

use anyhow::{Context, Result, bail};
use chainguard_ingest_core::enrich::Enricher;
use chainguard_ingest_core::{
    IngestConfig, Ingestor, NodeClient, QuorumConfig, QuorumSource, ReorgTracker, StreamMessage,
};
use chainguard_rpc::HttpNode;
use checkpoint::Checkpoint;
use clap::Parser;
use config::{Config, SinkConfig};
use sink::{JsonlSink, KafkaSink, Sink};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Parser)]
#[command(version, about = "SvlteChain ingestion daemon (read-only)")]
struct Args {
    /// Path to the TOML config.
    #[arg(short, long, default_value = "config/ingestd.toml")]
    config: PathBuf,
    /// Sync to the current head once, then exit.
    #[arg(long)]
    once: bool,
    /// Stop after ingesting this many blocks (useful for smoke tests).
    #[arg(long)]
    max_blocks: Option<usize>,
    /// Operator action: clear an integrity halt recorded in the checkpoint.
    /// Only after investigating why it halted.
    #[arg(long)]
    clear_halt: bool,
}

/// Exit code when ingestion halted on an integrity violation.
const EXIT_HALTED: i32 = 2;

#[tokio::main]
async fn main() {
    init_tracing();
    match run(Args::parse()).await {
        Ok(Outcome::Done) => {}
        Ok(Outcome::Halted(reason)) => {
            tracing::error!(%reason, "integrity halt: ingestion stopped and requires an operator");
            std::process::exit(EXIT_HALTED);
        }
        Err(e) => {
            tracing::error!("{e:#}");
            std::process::exit(1);
        }
    }
}

fn init_tracing() {
    use tracing_subscriber::EnvFilter;
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let builder = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr);
    if std::env::var("CHAINGUARD_LOG_FORMAT").as_deref() == Ok("json") {
        builder.json().init();
    } else {
        builder.init();
    }
}

enum Outcome {
    Done,
    Halted(String),
}

/// Block timestamp → now, signed. Negative means the local clock is behind
/// the chain: latency figures from this host are then meaningless, and we
/// say so instead of clamping to zero.
fn lag_secs(block_timestamp: u64) -> i64 {
    let lag = now_secs() as i64 - block_timestamp as i64;
    if lag < -2 {
        tracing::warn!(
            lag_s = lag,
            "local clock is behind block time; check NTP: latency metrics are unreliable"
        );
    }
    lag
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

async fn build_source(cfg: &Config) -> Result<QuorumSource<HttpNode>> {
    let timeout = Duration::from_millis(cfg.request_timeout_ms);
    let mut nodes = Vec::new();
    for n in &cfg.nodes {
        nodes.push(HttpNode::new(&n.id, n.resolve_url()?, timeout)?);
    }
    // Refuse to start if any reachable node is on the wrong chain: a
    // misconfigured endpoint must never be able to vote.
    for node in &nodes {
        match node.chain_id().await {
            Ok(id) if id == cfg.chain_id => {
                tracing::info!(node = %node.id(), chain_id = id, "node ok")
            }
            Ok(id) => bail!(
                "node {} reports chain id {id}, expected {}",
                node.id(),
                cfg.chain_id
            ),
            Err(e) => tracing::warn!(node = %node.id(), "node unreachable at startup: {e}"),
        }
    }
    let qcfg = QuorumConfig {
        min_agreement: cfg.quorum.min_agreement,
        request_timeout: timeout,
        allow_single_source: cfg.quorum.allow_single_source,
    };
    if qcfg.allow_single_source {
        tracing::warn!("allow_single_source is ON: records are single-attested; development only");
    }
    Ok(QuorumSource::new(nodes, qcfg)?)
}

async fn build_sink(cfg: &Config) -> Result<Sink> {
    Ok(match &cfg.sink {
        SinkConfig::Jsonl { path } => Sink::Jsonl(JsonlSink::open(path).await?),
        SinkConfig::Kafka {
            brokers,
            topic,
            create_topic,
            replication_factor,
        } => Sink::Kafka(
            KafkaSink::connect(
                brokers.clone(),
                topic,
                cfg.chain_id,
                *create_topic,
                *replication_factor,
            )
            .await?,
        ),
    })
}

fn summarize(msgs: &[StreamMessage]) {
    for m in msgs {
        match m {
            StreamMessage::BlockAdopted {
                block,
                record_count,
                attested_by,
                ..
            } => tracing::info!(
                block = block.number,
                hash = %block.hash,
                records = record_count,
                attested_by = attested_by.len(),
                lag_s = lag_secs(block.timestamp),
                "adopted"
            ),
            StreamMessage::Reorg {
                depth,
                common_ancestor,
                old_tip,
                new_tip,
                ..
            } => tracing::warn!(
                depth,
                ancestor = common_ancestor.number,
                old_tip = %old_tip.hash,
                new_tip = %new_tip.hash,
                "reorg: retracting orphaned records and re-emitting canonical ones"
            ),
            StreamMessage::IntegrityHalt { reason, .. } => {
                tracing::error!(%reason, "integrity halt")
            }
            _ => {}
        }
    }
}

async fn run(args: Args) -> Result<Outcome> {
    let cfg = Config::load(&args.config)?;
    tracing::info!(chain = %cfg.chain_name, chain_id = cfg.chain_id, confirmations = cfg.confirmations, "starting (read-only)");
    let checkpoint = Checkpoint::new(&cfg.checkpoint);

    let mut tracker = match checkpoint.load(cfg.chain_id, cfg.confirmations)? {
        Some(t) => {
            tracing::info!(
                tip = t.tip().map(|b| b.number),
                anchor = t.anchor().map(|b| b.number),
                "resuming from checkpoint {}",
                checkpoint.path().display()
            );
            t
        }
        None => ReorgTracker::new(cfg.chain_id, cfg.confirmations)?,
    };
    if args.clear_halt {
        tracker.clear_halt();
        checkpoint.save(&tracker)?;
        tracing::warn!("integrity halt cleared by operator");
    }
    if let Some(reason) = tracker.halted() {
        return Ok(Outcome::Halted(reason.to_owned()));
    }

    let enricher = match &cfg.labels {
        Some(p) => {
            let json =
                std::fs::read_to_string(p).with_context(|| format!("reading {}", p.display()))?;
            Enricher::from_json(&json, cfg.chain_id)?
        }
        None => Enricher::empty(cfg.chain_id),
    }
    .with_oracle_feeds(cfg.oracle_feeds.clone());
    tracing::info!(labels = enricher.label_count(), "enrichment loaded");

    let source = build_source(&cfg).await?;
    let mut sink = build_sink(&cfg).await?;
    let mut ingestor = Ingestor::new(
        source,
        tracker,
        Arc::new(enricher),
        IngestConfig {
            start_block: cfg.start_block,
            max_walkback: cfg.max_walkback,
        },
    );

    let poll = Duration::from_millis(cfg.poll_interval_ms);
    let mut blocks = 0usize;
    let shutdown = tokio::signal::ctrl_c();
    tokio::pin!(shutdown);

    loop {
        match ingestor.head().await {
            Err(e) => tracing::warn!("head unavailable, retrying: {e}"),
            Ok(head) => loop {
                let plan = match ingestor.next_plan(&head).await {
                    Ok(Some(p)) if !p.is_noop() => p,
                    Ok(_) => break,
                    Err(e) => {
                        tracing::warn!("step failed, retrying next poll: {e}");
                        break;
                    }
                };
                // Publish first; commit and checkpoint only once it is durable.
                if let Err(e) = sink.publish(&plan.messages).await {
                    tracing::warn!("publish failed, will retry: {e:#}");
                    break;
                }
                summarize(&plan.messages);
                let adopted = plan
                    .messages
                    .iter()
                    .filter(|m| matches!(m, StreamMessage::BlockAdopted { .. }))
                    .count();
                ingestor.commit(plan)?;
                checkpoint
                    .save(ingestor.tracker())
                    .context("saving checkpoint")?;
                if let Some(reason) = ingestor.tracker().halted() {
                    return Ok(Outcome::Halted(reason.to_owned()));
                }
                blocks += adopted;
                if args.max_blocks.is_some_and(|m| blocks >= m) {
                    tracing::info!(blocks, "reached --max-blocks");
                    return Ok(Outcome::Done);
                }
            },
        }
        if args.once {
            return Ok(Outcome::Done);
        }
        tokio::select! {
            _ = &mut shutdown => {
                tracing::info!("shutting down");
                return Ok(Outcome::Done);
            }
            _ = tokio::time::sleep(poll) => {}
        }
    }
}
