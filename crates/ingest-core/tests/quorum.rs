//! Multi-node verification (invariant 2): never trust a single node.
//!
//! Tests named `invariant_*` are required by scripts/check-invariants.sh;
//! CI fails if any of them is removed or renamed.

mod common;

use chainguard_ingest_core::source::{QuorumConfigError, SourceError};
use chainguard_ingest_core::testkit::{MockChain, MockNode};
use chainguard_ingest_core::{
    ChainSource, IngestError, QuorumConfig, QuorumSource, StreamMessage, SyncError,
};
use common::*;

fn cfg(min: usize) -> QuorumConfig {
    QuorumConfig {
        min_agreement: min,
        ..QuorumConfig::default()
    }
}

fn nodes(n: usize) -> Vec<MockNode> {
    let chain = MockChain::shared(CHAIN_ID);
    (0..n)
        .map(|i| MockNode::new(&format!("n{i}"), chain.clone()))
        .collect()
}

#[test]
fn invariant_multi_node_single_source_is_rejected_by_default() {
    assert_eq!(
        QuorumConfig::default().min_agreement,
        2,
        "default must require two independent sources"
    );
    assert!(!QuorumConfig::default().allow_single_source);
    assert_eq!(
        QuorumSource::new(nodes(1), QuorumConfig::default()).err(),
        Some(QuorumConfigError::NotEnoughNodes { min: 2, nodes: 1 })
    );
    assert_eq!(
        QuorumSource::new(nodes(1), cfg(1)).err(),
        Some(QuorumConfigError::SingleSourceForbidden(1))
    );
    assert_eq!(
        QuorumSource::new(nodes(3), cfg(1)).err(),
        Some(QuorumConfigError::SingleSourceForbidden(1))
    );
    assert_eq!(
        QuorumSource::new(nodes(3), cfg(0)).err(),
        Some(QuorumConfigError::SingleSourceForbidden(0))
    );
}

#[test]
fn invariant_multi_node_quorum_must_be_a_strict_majority() {
    assert_eq!(
        QuorumSource::new(nodes(4), cfg(2)).err(),
        Some(QuorumConfigError::NotMajority { min: 2, nodes: 4 })
    );
    assert!(QuorumSource::new(nodes(2), cfg(2)).is_ok());
    assert!(QuorumSource::new(nodes(3), cfg(2)).is_ok());
    assert!(QuorumSource::new(nodes(4), cfg(3)).is_ok());
    let dup = vec![nodes(1).remove(0), nodes(1).remove(0)];
    assert!(matches!(
        QuorumSource::new(dup, cfg(2)),
        Err(QuorumConfigError::DuplicateNode(_))
    ));
}

#[test]
fn single_source_only_with_explicit_dev_opt_in() {
    let dev = QuorumConfig {
        min_agreement: 1,
        allow_single_source: true,
        ..QuorumConfig::default()
    };
    assert!(QuorumSource::new(nodes(1), dev).is_ok());
}

#[tokio::test]
async fn invariant_multi_node_every_record_is_attested_by_at_least_two_nodes() {
    let mut h = Harness::new(3, 6);
    h.nodes[2].set(|b| b.down = true);
    h.mine(10);
    h.sync().await.unwrap();
    h.assert_matches_canonical_chain();
    let mut upserts = 0;
    for m in &h.log {
        if let StreamMessage::Upsert { record, .. } = m {
            upserts += 1;
            assert!(record.attested_by.len() >= 2, "{:?}", record.attested_by);
            assert!(
                !record.attested_by.iter().any(|n| n.0 == "node-2"),
                "a down node cannot attest"
            );
        }
    }
    assert!(upserts > 0);
}

#[tokio::test]
async fn invariant_multi_node_forging_node_is_outvoted() {
    let mut h = Harness::new(3, 6);
    h.nodes[0].set(|b| b.forge_from = Some(3));
    h.mine(10);
    h.sync().await.unwrap();
    h.assert_matches_canonical_chain();
    for m in &h.log {
        if let StreamMessage::BlockAdopted {
            block, attested_by, ..
        } = m
            && block.number >= 3
        {
            assert!(
                !attested_by.iter().any(|n| n.0 == "node-0"),
                "forger attested #{}",
                block.number
            );
        }
    }
}

#[tokio::test]
async fn invariant_multi_node_two_disagreeing_nodes_block_progress() {
    let mut h = Harness::new(2, 6);
    h.mine(2);
    h.sync().await.unwrap();
    let tip = h.ingestor.tracker().tip().copied();

    h.nodes[1].set(|b| b.forge_from = Some(4));
    h.mine(5);
    let err = h.sync().await.unwrap_err();
    assert!(
        matches!(
            err,
            SyncError::Ingest(IngestError::Source(SourceError::NoQuorum { .. }))
        ),
        "{err:?}"
    );
    assert_eq!(
        h.ingestor.tracker().tip().copied(),
        tip,
        "no progress without quorum"
    );
    assert!(
        h.ledger.halts.is_empty(),
        "disagreement is retried, not a halt"
    );

    // The liar recovers: ingestion resumes and catches up exactly.
    h.nodes[1].set(|b| b.forge_from = None);
    h.sync().await.unwrap();
    h.assert_matches_canonical_chain();
}

#[tokio::test]
async fn invariant_multi_node_omitted_logs_are_detected() {
    // Two nodes: one silently drops a log → no quorum on that block's logs.
    let mut h = Harness::new(2, 6);
    h.nodes[0].set(|b| b.drop_last_log = true);
    h.mine(3);
    let err = h.sync().await.unwrap_err();
    assert!(
        matches!(&err, SyncError::Ingest(IngestError::Source(SourceError::NoQuorum { what, .. })) if what.starts_with("logs")),
        "{err:?}"
    );

    // Three nodes: the dropping node is outvoted and the full log set wins.
    let mut h = Harness::new(3, 6);
    h.nodes[0].set(|b| b.drop_last_log = true);
    h.mine(5);
    h.sync().await.unwrap();
    h.assert_matches_canonical_chain();
}

#[tokio::test]
async fn node_stuck_on_a_stale_fork_is_outvoted() {
    let mut h = Harness::new(3, 8);
    h.mine(6);
    let stale = h.chain.lock().unwrap().head().hash;
    h.nodes[1].set(|b| b.view_head = Some(stale));
    h.reorg(2, 4, 5);
    h.sync().await.unwrap();
    h.assert_matches_canonical_chain();
}

#[tokio::test]
async fn head_is_the_highest_block_a_quorum_has_reached() {
    let h = Harness::new(3, 8);
    h.mine(20); // head 21
    h.nodes[0].set(|b| b.lag = 5);
    let q = quorum(&h.nodes);
    assert_eq!(
        q.head().await.unwrap().value.number,
        21,
        "one laggard does not hold the head back"
    );

    h.nodes[1].set(|b| b.lag = 2);
    assert_eq!(
        q.head().await.unwrap().value.number,
        19,
        "two of three have only reached 19"
    );

    h.nodes[2].set(|b| b.down = true);
    assert_eq!(
        q.head().await.unwrap().value.number,
        16,
        "with one down, both survivors must agree"
    );

    h.nodes[1].set(|b| b.down = true);
    assert!(
        matches!(q.head().await, Err(SourceError::NoQuorum { .. })),
        "a single survivor is not a quorum"
    );
}
