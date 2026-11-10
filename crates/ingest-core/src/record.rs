//! Derived records and the messages ingestion publishes to the stream bus.
//!
//! # Bus semantics
//!
//! Every message carries a per-chain, strictly increasing `seq`. Consumers
//! materialize state with "highest `seq` wins" per key:
//!
//! * [`StreamMessage::Upsert`] makes a record live (`deleted = false`).
//! * [`StreamMessage::Retract`] tombstones it (`deleted = true`) with a higher
//!   `seq` after a reorg orphaned its block.
//!
//! This maps 1:1 onto ClickHouse `ReplacingMergeTree(seq, is_deleted)`. It is
//! idempotent under at-least-once delivery: replaying a message with the same
//! `seq` changes nothing. That matters because the ingestor publishes
//! *before* it checkpoints.

use crate::decode::DecodedEvent;
use crate::enrich::Enrichment;
use crate::types::{BlockRef, NodeId};
use alloy_primitives::{Address, B256, Bytes, keccak256};
use serde::{Deserialize, Serialize};

/// Deterministic record identity: `keccak256(chain_id ‖ block_hash ‖ log_index)`.
///
/// The block *hash* (not number) is part of the identity, so the "same" log
/// on a competing fork is a different record. That is what makes retraction
/// exact.
pub fn record_id(chain_id: u64, block_hash: B256, log_index: u64) -> B256 {
    let mut buf = [0u8; 8 + 32 + 8];
    buf[..8].copy_from_slice(&chain_id.to_be_bytes());
    buf[8..40].copy_from_slice(block_hash.as_slice());
    buf[40..].copy_from_slice(&log_index.to_be_bytes());
    keccak256(buf)
}

/// One decoded, enriched on-chain event, with full provenance.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub id: B256,
    pub chain_id: u64,
    pub block: BlockRef,
    pub tx_hash: B256,
    pub tx_index: u64,
    pub log_index: u64,
    pub contract: Address,
    pub event: DecodedEvent,
    pub enrichment: Enrichment,
    /// Raw log kept for evidence and the audit trail: any decision made on
    /// this record can be reproduced from exactly these bytes.
    pub topics: Vec<B256>,
    pub data: Bytes,
    /// Nodes that independently returned this block's logs byte-for-byte.
    pub attested_by: Vec<NodeId>,
    /// Wall-clock time ingestion derived the record (ms since epoch). Used to
    /// measure on-chain-event to alert latency end to end.
    pub observed_at_ms: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Finality {
    /// Within the reorg window: may still be retracted.
    Provisional,
}

/// Messages ingestion publishes, in order, for one chain.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum StreamMessage {
    /// A block joined the canonical chain (provisionally).
    BlockAdopted {
        seq: u64,
        chain_id: u64,
        block: BlockRef,
        record_count: usize,
        attested_by: Vec<NodeId>,
    },
    /// A derived record became live. Always provisional until its block is
    /// finalized; detection must treat it as such (invariant 3).
    Upsert {
        seq: u64,
        chain_id: u64,
        finality: Finality,
        deleted: bool,
        record: Record,
    },
    /// A reorg orphaned the block this record came from.
    Retract {
        seq: u64,
        chain_id: u64,
        deleted: bool,
        orphaned_block: BlockRef,
        record: Record,
    },
    /// A block left the canonical chain.
    BlockOrphaned {
        seq: u64,
        chain_id: u64,
        block: BlockRef,
        replaced_by: Option<BlockRef>,
    },
    /// Summary of a reorg, emitted before its retractions.
    Reorg {
        seq: u64,
        chain_id: u64,
        depth: usize,
        common_ancestor: BlockRef,
        old_tip: BlockRef,
        new_tip: BlockRef,
    },
    /// A block is now deeper than the confirmation threshold. Its records
    /// will never be retracted by this ingestor.
    BlockFinalized {
        seq: u64,
        chain_id: u64,
        block: BlockRef,
    },
    /// Ingestion detected something it cannot safely reconcile on its own
    /// (e.g. a reorg below finality) and stopped advancing. Requires an
    /// operator. Never silent.
    IntegrityHalt {
        seq: u64,
        chain_id: u64,
        reason: String,
        last_good: Option<BlockRef>,
    },
}

impl StreamMessage {
    pub fn seq(&self) -> u64 {
        match self {
            Self::BlockAdopted { seq, .. }
            | Self::Upsert { seq, .. }
            | Self::Retract { seq, .. }
            | Self::BlockOrphaned { seq, .. }
            | Self::Reorg { seq, .. }
            | Self::BlockFinalized { seq, .. }
            | Self::IntegrityHalt { seq, .. } => *seq,
        }
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Self::BlockAdopted { .. } => "block_adopted",
            Self::Upsert { .. } => "upsert",
            Self::Retract { .. } => "retract",
            Self::BlockOrphaned { .. } => "block_orphaned",
            Self::Reorg { .. } => "reorg",
            Self::BlockFinalized { .. } => "block_finalized",
            Self::IntegrityHalt { .. } => "integrity_halt",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_id_depends_on_block_hash_not_just_position() {
        let a = record_id(1, B256::repeat_byte(1), 0);
        let b = record_id(1, B256::repeat_byte(2), 0);
        assert_ne!(
            a, b,
            "same log index on competing forks must be distinct records"
        );
        assert_eq!(a, record_id(1, B256::repeat_byte(1), 0));
        assert_ne!(
            a,
            record_id(5, B256::repeat_byte(1), 0),
            "chain id is part of identity"
        );
    }
}
