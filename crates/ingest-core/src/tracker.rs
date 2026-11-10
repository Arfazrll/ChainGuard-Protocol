//! Reorg-safe canonical chain tracking. Pure state machine, no I/O.
//!
//! The tracker keeps the last `confirmations` blocks of the canonical chain
//! in a *provisional window*, each with the records derived from it, plus a
//! finalized *anchor* (the newest block that left the window).
//!
//! ```text
//!   anchor (final)   window (provisional, may be reorged)
//!   ──[ 100 ]──────[ 101 ][ 102 ][ 103 ][ 104 ]  ← tip
//!                          └─[102']─[103']─[104']─[105']   competing fork
//! ```
//!
//! Adopting the fork above produces, in order: a `Reorg` summary, the
//! retraction of every record from 104, 103, 102 (newest first, so
//! consumers unwind in reverse), `BlockOrphaned` for each, then
//! `BlockAdopted` and `Upsert`s for 102'..105', then `BlockFinalized` for any
//! block that is now `confirmations` deep.
//!
//! Changes are two-phase: [`ReorgTracker::plan`] computes the messages and
//! the state transition without mutating; [`ReorgTracker::commit`] applies it
//! only after the messages have been durably published. A failed publish
//! therefore leaves the tracker untouched, and the step can be retried.

use crate::record::{Finality, Record, StreamMessage};
use crate::types::{BlockHeader, NodeId};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

/// How many finalized (number, hash) pairs to remember beyond the anchor.
/// Lets us tell a lagging quorum (reports an old canonical block) from a fork
/// below finality (reports a different block at a finalized height).
pub const FINALIZED_HISTORY: usize = 256;

/// A canonical block in the provisional window, with everything derived from it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TrackedBlock {
    pub header: BlockHeader,
    pub attested_by: Vec<NodeId>,
    pub records: Vec<Record>,
}

/// How a candidate block relates to the tracked chain.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Connection {
    /// Nothing tracked yet; any block can start the chain.
    Bootstrap,
    /// Already part of the tracked canonical chain.
    Known,
    /// Its parent is tracked: it extends the tip or forks off the window.
    Connects,
    /// Parent unknown but still above the anchor: walk back to find it.
    NeedsParent,
    /// At or below the finalized anchor (or the ingestion start) and not on
    /// our chain. Adopting it would rewrite settled history.
    BelowFinality,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum TrackerError {
    #[error("ingestion is halted: {0}")]
    Halted(String),
    #[error("empty segment")]
    Empty,
    #[error("segment is not a contiguous chain at block {at}")]
    NotContiguous { at: u64 },
    #[error(
        "segment starting at block {number} does not connect: parent {parent_hash} is not tracked"
    )]
    Disconnected {
        number: u64,
        parent_hash: alloy_primitives::B256,
    },
    #[error("plan was computed against a different tracker state")]
    StalePlan,
    #[error("confirmations must be at least 1")]
    BadConfig,
}

#[derive(Clone, Debug, PartialEq)]
enum PlanOp {
    Noop,
    Advance {
        keep: usize,
        push: Vec<TrackedBlock>,
        finalize: usize,
    },
    Halt {
        reason: String,
    },
}

/// A computed, not-yet-applied state transition.
#[derive(Clone, Debug, PartialEq)]
#[must_use = "a plan does nothing until it is committed"]
pub struct Plan {
    pub messages: Vec<StreamMessage>,
    base_seq: u64,
    next_seq: u64,
    op: PlanOp,
}

impl Plan {
    pub fn is_noop(&self) -> bool {
        matches!(self.op, PlanOp::Noop)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ReorgTracker {
    chain_id: u64,
    confirmations: u64,
    anchor: Option<BlockHeader>,
    window: VecDeque<TrackedBlock>,
    /// Recently finalized blocks, oldest first; the anchor is the last entry.
    #[serde(default)]
    finalized: VecDeque<(u64, alloy_primitives::B256)>,
    next_seq: u64,
    halted: Option<String>,
}

impl ReorgTracker {
    /// `confirmations`: depth at which a block is finalized and can no longer
    /// be reorged by this ingestor. It is also the maximum reorg depth that
    /// can be handled automatically. Ethereum PoS finalizes in ~2 epochs (64 blocks).
    pub fn new(chain_id: u64, confirmations: u64) -> Result<Self, TrackerError> {
        if confirmations == 0 {
            return Err(TrackerError::BadConfig);
        }
        Ok(Self {
            chain_id,
            confirmations,
            anchor: None,
            window: VecDeque::new(),
            finalized: VecDeque::new(),
            next_seq: 1,
            halted: None,
        })
    }

    pub fn chain_id(&self) -> u64 {
        self.chain_id
    }
    pub fn confirmations(&self) -> u64 {
        self.confirmations
    }
    pub fn anchor(&self) -> Option<&BlockHeader> {
        self.anchor.as_ref()
    }
    pub fn tip(&self) -> Option<&BlockHeader> {
        self.window
            .back()
            .map(|b| &b.header)
            .or(self.anchor.as_ref())
    }
    pub fn window(&self) -> impl Iterator<Item = &TrackedBlock> {
        self.window.iter()
    }
    pub fn halted(&self) -> Option<&str> {
        self.halted.as_deref()
    }
    pub fn next_seq(&self) -> u64 {
        self.next_seq
    }
    pub fn is_empty(&self) -> bool {
        self.anchor.is_none() && self.window.is_empty()
    }

    fn window_index(&self, hash: alloy_primitives::B256) -> Option<usize> {
        self.window.iter().position(|b| b.header.hash == hash)
    }

    /// Height at or below which history is settled: the finalized anchor, or
    /// before any finalization, the parent of the first ingested block.
    fn floor(&self) -> u64 {
        match (&self.anchor, self.window.front()) {
            (Some(a), _) => a.number,
            (None, Some(first)) => first.header.number.saturating_sub(1),
            (None, None) => 0,
        }
    }

    /// Our finalized hash at `number`, if it is within [`FINALIZED_HISTORY`].
    pub fn finalized_hash_at(&self, number: u64) -> Option<alloy_primitives::B256> {
        let &(first, _) = self.finalized.front()?;
        let (n, h) = *self
            .finalized
            .get(usize::try_from(number.checked_sub(first)?).ok()?)?;
        (n == number).then_some(h)
    }

    /// Is `hash` on the tracked canonical chain (window or anchor)?
    pub fn knows(&self, hash: alloy_primitives::B256) -> bool {
        self.anchor.is_some_and(|a| a.hash == hash) || self.window_index(hash).is_some()
    }

    pub fn connection(&self, header: &BlockHeader) -> Connection {
        if self.is_empty() {
            Connection::Bootstrap
        } else if self.knows(header.hash) {
            Connection::Known
        } else if self.knows(header.parent_hash) {
            Connection::Connects
        } else if header.number <= self.floor() + 1 {
            // Its parent would have to be at or below the floor, and it is not
            // a block we track: this fork diverges from history we treat as
            // settled (finalized, or older than where ingestion started).
            Connection::BelowFinality
        } else {
            Connection::NeedsParent
        }
    }

    /// Plan adopting `segment`, a contiguous run of blocks whose first block's
    /// parent is tracked (or anything, when bootstrapping). Leading blocks that
    /// are already canonical are skipped.
    pub fn plan(&self, segment: Vec<TrackedBlock>) -> Result<Plan, TrackerError> {
        if let Some(reason) = &self.halted {
            return Err(TrackerError::Halted(reason.clone()));
        }
        if segment.is_empty() {
            return Err(TrackerError::Empty);
        }
        for pair in segment.windows(2) {
            let (a, b) = (&pair[0].header, &pair[1].header);
            if b.parent_hash != a.hash || b.number != a.number + 1 {
                return Err(TrackerError::NotContiguous { at: b.number });
            }
        }

        let first = segment[0].header;
        let (parent, mut keep) = if self.is_empty() {
            (None, 0)
        } else if let Some(a) = self.anchor.filter(|a| a.hash == first.parent_hash) {
            (Some(a), 0)
        } else if let Some(i) = self.window_index(first.parent_hash) {
            (Some(self.window[i].header), i + 1)
        } else {
            return Err(TrackerError::Disconnected {
                number: first.number,
                parent_hash: first.parent_hash,
            });
        };
        if let Some(p) = parent
            && first.number != p.number + 1
        {
            return Err(TrackerError::NotContiguous { at: first.number });
        }

        // Skip any prefix of the segment that is already canonical.
        let mut segment = VecDeque::from(segment);
        while let (Some(s), Some(w)) = (segment.front(), self.window.get(keep)) {
            if s.header.hash != w.header.hash {
                break;
            }
            segment.pop_front();
            keep += 1;
        }
        let segment: Vec<TrackedBlock> = segment.into();
        let base_seq = self.next_seq;
        if segment.is_empty() {
            return Ok(Plan {
                messages: vec![],
                base_seq,
                next_seq: base_seq,
                op: PlanOp::Noop,
            });
        }

        let chain_id = self.chain_id;
        let mut seq = base_seq;
        let mut next = || {
            let s = seq;
            seq += 1;
            s
        };
        let mut messages = Vec::new();

        // 1. Unwind orphaned blocks, newest first.
        let orphaned: Vec<&TrackedBlock> = self.window.iter().skip(keep).collect();
        if let (Some(old_tip), Some(ancestor)) = (orphaned.last(), parent) {
            messages.push(StreamMessage::Reorg {
                seq: next(),
                chain_id,
                depth: orphaned.len(),
                common_ancestor: ancestor,
                old_tip: old_tip.header,
                new_tip: segment.last().expect("non-empty").header,
            });
        }
        for block in orphaned.iter().rev() {
            for record in block.records.iter().rev() {
                messages.push(StreamMessage::Retract {
                    seq: next(),
                    chain_id,
                    deleted: true,
                    orphaned_block: block.header,
                    record: record.clone(),
                });
            }
            let replaced_by = segment
                .iter()
                .find(|b| b.header.number == block.header.number)
                .map(|b| b.header);
            messages.push(StreamMessage::BlockOrphaned {
                seq: next(),
                chain_id,
                block: block.header,
                replaced_by,
            });
        }

        // 2. Adopt the new blocks, oldest first.
        for block in &segment {
            messages.push(StreamMessage::BlockAdopted {
                seq: next(),
                chain_id,
                block: block.header,
                record_count: block.records.len(),
                attested_by: block.attested_by.clone(),
            });
            for record in &block.records {
                messages.push(StreamMessage::Upsert {
                    seq: next(),
                    chain_id,
                    finality: Finality::Provisional,
                    deleted: false,
                    record: record.clone(),
                });
            }
        }

        // 3. Finalize whatever is now `confirmations` deep.
        let new_tip = segment.last().expect("non-empty").header.number;
        let mut finalize = 0;
        for block in self.window.iter().take(keep).chain(segment.iter()) {
            if new_tip.saturating_sub(block.header.number) < self.confirmations {
                break;
            }
            messages.push(StreamMessage::BlockFinalized {
                seq: next(),
                chain_id,
                block: block.header,
            });
            finalize += 1;
        }

        Ok(Plan {
            messages,
            base_seq,
            next_seq: seq,
            op: PlanOp::Advance {
                keep,
                push: segment,
                finalize,
            },
        })
    }

    /// A plan that changes nothing.
    pub fn plan_noop(&self) -> Plan {
        Plan {
            messages: vec![],
            base_seq: self.next_seq,
            next_seq: self.next_seq,
            op: PlanOp::Noop,
        }
    }

    /// Plan stopping ingestion. Used when continuing would require rewriting
    /// finalized history or trusting data that failed verification.
    pub fn plan_halt(&self, reason: impl Into<String>) -> Plan {
        let reason = reason.into();
        let base_seq = self.next_seq;
        let msg = StreamMessage::IntegrityHalt {
            seq: base_seq,
            chain_id: self.chain_id,
            reason: reason.clone(),
            last_good: self.tip().copied(),
        };
        Plan {
            messages: vec![msg],
            base_seq,
            next_seq: base_seq + 1,
            op: PlanOp::Halt { reason },
        }
    }

    /// Apply a plan produced by [`plan`](Self::plan) or [`plan_halt`](Self::plan_halt)
    /// on this exact state. Call only after its messages are durably published.
    pub fn commit(&mut self, plan: Plan) -> Result<(), TrackerError> {
        if plan.base_seq != self.next_seq {
            return Err(TrackerError::StalePlan);
        }
        match plan.op {
            PlanOp::Noop => {}
            PlanOp::Halt { reason } => self.halted = Some(reason),
            PlanOp::Advance {
                keep,
                push,
                finalize,
            } => {
                self.window.truncate(keep);
                self.window.extend(push);
                for _ in 0..finalize {
                    let b = self
                        .window
                        .pop_front()
                        .expect("finalize count within window");
                    self.finalized.push_back((b.header.number, b.header.hash));
                    if self.finalized.len() > FINALIZED_HISTORY {
                        self.finalized.pop_front();
                    }
                    self.anchor = Some(b.header);
                }
            }
        }
        self.next_seq = plan.next_seq;
        Ok(())
    }

    /// Operator action: clear a halt after investigating it. The tracker keeps
    /// its finalized anchor, so a fork below it will halt again.
    pub fn clear_halt(&mut self) {
        self.halted = None;
    }
}
