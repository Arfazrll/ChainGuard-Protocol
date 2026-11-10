//! The ingestion driver: quorum source → decode → enrich → reorg tracker.
//!
//! One step at a time: [`Ingestor::next_plan`] works out the next block to
//! adopt (walking back through parents when it does not connect, which is
//! how reorgs are discovered), fetches and verifies its logs, derives
//! records and asks the tracker for a [`Plan`]. The caller publishes the
//! plan's messages and then calls [`Ingestor::commit`]. Nothing is mutated
//! before the publish succeeds.

use crate::decode::decode_log;
use crate::enrich::Enricher;
use crate::record::{Record, StreamMessage, record_id};
use crate::source::{ChainSource, SourceError};
use crate::tracker::{Connection, Plan, ReorgTracker, TrackedBlock, TrackerError};
use crate::types::{Attested, BlockHeader, RawLog};
use std::sync::Arc;

#[derive(Debug, Clone)]
pub struct IngestConfig {
    /// First block to ingest when there is no checkpoint. `None` = current head.
    pub start_block: Option<u64>,
    /// Hard bound on how far back we follow parent hashes to reconnect.
    pub max_walkback: usize,
}

impl Default for IngestConfig {
    fn default() -> Self {
        Self {
            start_block: None,
            max_walkback: 128,
        }
    }
}

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum IngestError {
    #[error(transparent)]
    Source(#[from] SourceError),
    #[error(transparent)]
    Tracker(#[from] TrackerError),
}

pub struct Ingestor<S> {
    source: S,
    tracker: ReorgTracker,
    enricher: Arc<Enricher>,
    cfg: IngestConfig,
    now_ms: fn() -> u64,
}

fn system_now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl<S: ChainSource> Ingestor<S> {
    pub fn new(
        source: S,
        tracker: ReorgTracker,
        enricher: Arc<Enricher>,
        cfg: IngestConfig,
    ) -> Self {
        Self {
            source,
            tracker,
            enricher,
            cfg,
            now_ms: system_now_ms,
        }
    }

    pub fn tracker(&self) -> &ReorgTracker {
        &self.tracker
    }

    pub fn source(&self) -> &S {
        &self.source
    }

    pub async fn head(&self) -> Result<Attested<BlockHeader>, IngestError> {
        Ok(self.source.head().await?)
    }

    /// The next plan towards `head`, or `None` when already caught up.
    pub async fn next_plan(
        &self,
        head: &Attested<BlockHeader>,
    ) -> Result<Option<Plan>, IngestError> {
        let attested_head = head;
        let head = &head.value;
        if let Some(reason) = self.tracker.halted() {
            return Err(TrackerError::Halted(reason.to_owned()).into());
        }
        let candidate = match self.tracker.tip() {
            None => {
                let start = self.cfg.start_block.unwrap_or(head.number).min(head.number);
                self.source.block_by_number(start).await?
            }
            Some(tip) if head.number > tip.number => {
                self.source.block_by_number(tip.number + 1).await?
            }
            Some(_) if self.tracker.knows(head.hash) => return Ok(None),
            Some(_) => match self.tracker.anchor() {
                // At or below finality: either the quorum is lagging (it reports
                // a block we finalized) or it follows a fork below finality.
                Some(anchor) if head.number <= anchor.number => {
                    return match self.tracker.finalized_hash_at(head.number) {
                        Some(ours) if ours == head.hash => Ok(None),
                        Some(ours) => Ok(Some(self.tracker.plan_halt(format!(
                            "reorg below finality: quorum {:?} reports block #{} {} but we finalized {}",
                            attested_head.attested_by, head.number, head.hash, ours
                        )))),
                        None => {
                            tracing::warn!(
                                head = head.number,
                                anchor = anchor.number,
                                "quorum head is older than finalized history; not advancing"
                            );
                            Ok(None)
                        }
                    };
                }
                // A competing fork won at equal or lower height than our tip.
                _ => attested_head.clone(),
            },
        };
        self.plan_for(candidate).await.map(Some)
    }

    async fn plan_for(&self, candidate: Attested<BlockHeader>) -> Result<Plan, IngestError> {
        // Walk back through parents until the chain reconnects to what we track.
        let mut chain = vec![candidate];
        loop {
            let oldest = chain.last().expect("non-empty").value;
            match self.tracker.connection(&oldest) {
                Connection::Bootstrap | Connection::Connects => break,
                // Only the candidate itself can be known (parents are never
                // pushed once one connects); nothing to do.
                Connection::Known => return Ok(self.tracker.plan_noop()),
                Connection::BelowFinality => {
                    return Ok(self.tracker.plan_halt(format!(
                        "reorg below finality: block #{} {} (parent {}) does not descend from finalized #{} {}",
                        oldest.number,
                        oldest.hash,
                        oldest.parent_hash,
                        self.tracker.anchor().map_or(0, |a| a.number),
                        self.tracker.anchor().map_or_else(Default::default, |a| a.hash),
                    )));
                }
                Connection::NeedsParent => {
                    if chain.len() >= self.cfg.max_walkback {
                        return Ok(self.tracker.plan_halt(format!(
                            "could not reconnect block #{} within {} parents",
                            chain[0].value.number, self.cfg.max_walkback
                        )));
                    }
                    let parent = self.source.block_by_hash(oldest.parent_hash).await?;
                    if parent.value.number + 1 != oldest.number {
                        return Ok(self.tracker.plan_halt(format!(
                            "quorum returned parent #{} for block #{}; header chain is inconsistent",
                            parent.value.number, oldest.number
                        )));
                    }
                    chain.push(parent);
                }
            }
        }
        chain.reverse();

        let mut segment = Vec::with_capacity(chain.len());
        for header in chain {
            let logs = self.source.logs(&header.value).await?;
            let attested_by = header.attested_by.clone();
            let records = self.derive(&header.value, logs);
            segment.push(TrackedBlock {
                header: header.value,
                attested_by,
                records,
            });
        }
        Ok(self.tracker.plan(segment)?)
    }

    fn derive(&self, header: &BlockHeader, logs: Attested<Vec<RawLog>>) -> Vec<Record> {
        let chain_id = self.tracker.chain_id();
        let observed_at_ms = (self.now_ms)();
        logs.value
            .into_iter()
            .map(|log| {
                let event = decode_log(&log);
                self.enricher.observe(log.address, header.number, &event);
                let enrichment = self.enricher.enrich(log.address, &event);
                Record {
                    id: record_id(chain_id, header.hash, log.log_index),
                    chain_id,
                    block: *header,
                    tx_hash: log.tx_hash,
                    tx_index: log.tx_index,
                    log_index: log.log_index,
                    contract: log.address,
                    event,
                    enrichment,
                    topics: log.topics,
                    data: log.data,
                    attested_by: logs.attested_by.clone(),
                    observed_at_ms,
                }
            })
            .collect()
    }

    /// Apply a plan after its messages were durably published.
    pub fn commit(&mut self, plan: Plan) -> Result<(), TrackerError> {
        self.tracker.commit(plan)
    }

    /// Drive to the current head, handing each step's messages to `publish`
    /// before committing it. Stops at the first error; a halt is committed
    /// and then reported as [`TrackerError::Halted`].
    pub async fn sync_to_head<F, E>(&mut self, mut publish: F) -> Result<usize, SyncError<E>>
    where
        F: FnMut(&[StreamMessage]) -> Result<(), E>,
    {
        let head = self.head().await.map_err(SyncError::Ingest)?;
        let mut steps = 0;
        while let Some(plan) = self.next_plan(&head).await.map_err(SyncError::Ingest)? {
            if plan.is_noop() {
                break;
            }
            publish(&plan.messages).map_err(SyncError::Publish)?;
            self.commit(plan).map_err(|e| SyncError::Ingest(e.into()))?;
            steps += 1;
            if let Some(reason) = self.tracker.halted() {
                return Err(SyncError::Ingest(
                    TrackerError::Halted(reason.to_owned()).into(),
                ));
            }
        }
        Ok(steps)
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SyncError<E> {
    #[error(transparent)]
    Ingest(IngestError),
    #[error("publish failed")]
    Publish(E),
}
