//! Reorg safety (invariant 3). Milestone-1 "done when": a reorg on a test
//! chain correctly retracts and re-emits derived state.

mod common;

use chainguard_ingest_core::testkit::{Ledger, ReplacingTable};
use chainguard_ingest_core::{
    IngestConfig, IngestError, Ingestor, ReorgTracker, StreamMessage, SyncError, TrackerError,
};
use common::*;
use proptest::prelude::*;
use std::collections::BTreeSet;

fn kinds(msgs: &[StreamMessage]) -> Vec<&'static str> {
    msgs.iter().map(StreamMessage::kind).collect()
}

#[tokio::test]
async fn linear_chain_emits_every_record_once_and_finalizes_at_depth() {
    let mut h = Harness::new(3, 5);
    h.mine(19); // blocks 1..=20
    h.sync().await.unwrap();
    h.assert_matches_canonical_chain();
    assert!(h.ledger.reorgs.is_empty());
    // Depth ≥ 5 below tip 20 → blocks 1..=15 are final.
    assert_eq!(h.ledger.finalized_blocks.len(), 15);
    assert_eq!(h.ingestor.tracker().anchor().unwrap().number, 15);
    assert_eq!(h.ingestor.tracker().window().count(), 5);
}

#[tokio::test]
async fn reorg_retracts_orphaned_records_and_reemits_canonical_ones() {
    let mut h = Harness::new(3, 8);
    h.mine(9); // 1..=10
    h.sync().await.unwrap();
    let before = h.ledger.live_ids();

    // Replace blocks 8, 9, 10 with a longer fork 8', 9', 10', 11'.
    h.reorg(3, 4, 7);
    h.log.clear();
    h.sync().await.unwrap();

    h.assert_matches_canonical_chain();
    assert_eq!(h.ledger.reorgs, vec![3], "exactly one reorg of depth 3");

    let retracted: BTreeSet<_> = h
        .log
        .iter()
        .filter_map(|m| match m {
            StreamMessage::Retract { record, .. } => Some(record.id),
            _ => None,
        })
        .collect();
    let orphaned_numbers: BTreeSet<u64> = h
        .log
        .iter()
        .filter_map(|m| match m {
            StreamMessage::BlockOrphaned { block, .. } => Some(block.number),
            _ => None,
        })
        .collect();
    assert_eq!(orphaned_numbers, BTreeSet::from([8, 9, 10]));
    // Every retracted record was live before, and nothing else was touched.
    assert!(retracted.is_subset(&before));
    let survived: BTreeSet<_> = before.difference(&retracted).copied().collect();
    assert!(
        survived.is_subset(&h.ledger.live_ids()),
        "records from blocks 1..=7 must survive"
    );

    // Ordering contract: summary, then unwind newest-first, then adopt oldest-first.
    let k = kinds(&h.log);
    assert_eq!(k[0], "reorg");
    let first_adopt = k.iter().position(|&x| x == "block_adopted").unwrap();
    assert!(
        k[..first_adopt]
            .iter()
            .all(|&x| matches!(x, "reorg" | "retract" | "block_orphaned"))
    );
    let orphan_order: Vec<u64> = h
        .log
        .iter()
        .filter_map(|m| match m {
            StreamMessage::BlockOrphaned { block, .. } => Some(block.number),
            _ => None,
        })
        .collect();
    assert_eq!(orphan_order, vec![10, 9, 8], "unwind newest block first");
}

#[tokio::test]
async fn same_height_reorg_replaces_the_tip() {
    let mut h = Harness::new(3, 8);
    h.mine(5);
    h.sync().await.unwrap();
    h.reorg(1, 1, 99); // a sibling of the tip wins
    h.sync().await.unwrap();
    h.assert_matches_canonical_chain();
    assert_eq!(h.ledger.reorgs, vec![1]);
}

#[tokio::test]
async fn reorg_to_a_shorter_chain() {
    let mut h = Harness::new(3, 8);
    h.mine(9);
    h.sync().await.unwrap();
    h.reorg(4, 1, 5); // tip goes from 10 down to 7
    h.sync().await.unwrap();
    h.assert_matches_canonical_chain();
    assert_eq!(h.ledger.reorgs, vec![4]);
    assert_eq!(h.ingestor.tracker().tip().unwrap().number, 7);
}

#[tokio::test]
async fn flip_flop_back_to_the_original_fork_reemits_its_records() {
    let mut h = Harness::new(3, 8);
    h.mine(9);
    h.sync().await.unwrap();
    let original_head = h.chain.lock().unwrap().head().hash;
    let original = h.ledger.live_ids();

    h.reorg(2, 2, 1);
    h.sync().await.unwrap();
    h.assert_matches_canonical_chain();

    h.chain.lock().unwrap().set_head(original_head);
    h.sync().await.unwrap();
    h.assert_matches_canonical_chain();
    assert_eq!(h.ledger.live_ids(), original);
    assert_eq!(h.ledger.reorgs, vec![2, 2]);
}

#[tokio::test]
async fn catches_up_across_a_gap_that_contains_a_reorg() {
    let mut h = Harness::new(3, 10);
    h.mine(5);
    h.sync().await.unwrap();
    // While we were away: the last 3 blocks we saw were replaced, and 12 more were mined.
    h.reorg(3, 3, 42);
    h.mine(12);
    h.sync().await.unwrap();
    h.assert_matches_canonical_chain();
    assert_eq!(h.ledger.reorgs, vec![3]);
}

#[tokio::test]
async fn reorg_below_finality_halts_and_never_rewrites_finalized_history() {
    let mut h = Harness::new(3, 3);
    h.mine(9); // 1..=10; final through 7
    h.sync().await.unwrap();
    let before = h.ledger.live_ids();

    h.reorg(6, 7, 13); // fork from block 4: below the anchor
    let err = h.sync().await.unwrap_err();
    assert!(
        matches!(
            err,
            SyncError::Ingest(IngestError::Tracker(TrackerError::Halted(_)))
        ),
        "{err:?}"
    );
    assert_eq!(
        h.ledger.halts.len(),
        1,
        "halt must be published, never silent"
    );
    assert!(
        h.ledger.halts[0].contains("below finality"),
        "{}",
        h.ledger.halts[0]
    );
    assert_eq!(
        h.ledger.live_ids(),
        before,
        "nothing may change after a refused reorg"
    );

    // Stays halted until an operator intervenes.
    let again = h.sync().await.unwrap_err();
    assert!(matches!(
        again,
        SyncError::Ingest(IngestError::Tracker(TrackerError::Halted(_)))
    ));
    assert_eq!(
        h.ledger.halts.len(),
        1,
        "a halt is published once, not on every poll"
    );
}

/// Regression (found by the property test): a reorg to a shorter chain
/// followed by a second reorg below finality leaves the quorum head *at or
/// below* the anchor height. It used to be ignored silently.
#[tokio::test]
async fn fork_head_below_finality_height_halts_instead_of_being_ignored() {
    let mut h = Harness::new(3, 4);
    h.mine(5); // 1..=6; final through 2
    h.sync().await.unwrap();
    h.reorg(3, 1, 1); // tip 6 → 4'
    h.sync().await.unwrap();
    h.reorg(3, 1, 2); // forks from block 1; new head 2'' sits at the anchor height
    let err = h.sync().await.unwrap_err();
    assert!(
        matches!(
            err,
            SyncError::Ingest(IngestError::Tracker(TrackerError::Halted(_)))
        ),
        "{err:?}"
    );
    assert!(h.ledger.halts[0].contains("below finality"));
}

#[tokio::test]
async fn lagging_quorum_below_finality_is_recognized_and_ignored() {
    let mut h = Harness::new(3, 4);
    h.mine(19);
    h.sync().await.unwrap();
    // Two of three nodes fall far behind (e.g. restarted and resyncing).
    h.nodes[0].set(|b| b.lag = 10);
    h.nodes[1].set(|b| b.lag = 10);
    assert_eq!(
        h.sync().await.unwrap(),
        0,
        "no progress, but no halt either"
    );
    assert!(h.ledger.halts.is_empty());
    h.assert_matches_canonical_chain();
}

#[tokio::test]
async fn reorg_replacing_the_start_block_halts_before_any_finality() {
    let mut h = Harness::new(3, 50);
    h.mine(4); // ingest 1..=5, nothing final yet
    h.sync().await.unwrap();
    h.reorg(5, 6, 21); // fork from genesis, replacing block 1 where ingestion began
    let err = h.sync().await.unwrap_err();
    assert!(
        matches!(
            err,
            SyncError::Ingest(IngestError::Tracker(TrackerError::Halted(_)))
        ),
        "{err:?}"
    );
    assert_eq!(h.ledger.halts.len(), 1);
}

#[tokio::test]
async fn failed_publish_leaves_state_untouched_and_retry_is_exact() {
    let mut h = Harness::new(3, 8);
    h.mine(9);
    h.sync().await.unwrap();
    h.reorg(3, 3, 3);

    let seq_before = h.ingestor.tracker().next_seq();
    let tip_before = *h.ingestor.tracker().tip().unwrap();
    let err = h
        .ingestor
        .sync_to_head(|_| Err::<(), _>("bus unavailable"))
        .await
        .unwrap_err();
    assert!(matches!(err, SyncError::Publish("bus unavailable")));
    assert_eq!(
        h.ingestor.tracker().next_seq(),
        seq_before,
        "nothing committed"
    );
    assert_eq!(*h.ingestor.tracker().tip().unwrap(), tip_before);

    h.sync().await.unwrap();
    h.assert_matches_canonical_chain();
}

#[tokio::test]
async fn at_least_once_redelivery_is_idempotent_downstream() {
    let mut h = Harness::new(3, 6);
    h.mine(12);
    h.sync().await.unwrap();
    h.reorg(4, 5, 8);
    h.sync().await.unwrap();
    h.reorg(2, 1, 9);
    h.sync().await.unwrap();

    // Redeliver the whole stream, then a reversed copy (worst-case reordering).
    let mut table = ReplacingTable::default();
    table.apply(&h.log);
    table.apply(&h.log);
    let mut reversed = h.log.clone();
    reversed.reverse();
    table.apply(&reversed);
    assert_eq!(
        table.live_ids(),
        h.chain.lock().unwrap().expected_record_ids(1)
    );
}

#[tokio::test]
async fn resumes_from_checkpoint_and_still_detects_reorgs() {
    let mut h = Harness::new(3, 8);
    h.mine(9);
    h.sync().await.unwrap();

    // Persist, "crash", restore into a fresh ingestor.
    let checkpoint = serde_json::to_string(h.ingestor.tracker()).unwrap();
    let restored: ReorgTracker = serde_json::from_str(&checkpoint).unwrap();
    assert_eq!(&restored, h.ingestor.tracker());
    h.ingestor = Ingestor::new(
        quorum(&h.nodes),
        restored,
        enricher(),
        IngestConfig::default(),
    );

    h.reorg(2, 3, 77); // a reorg that happened while we were down
    h.sync().await.unwrap();
    h.assert_matches_canonical_chain();
    assert_eq!(h.ledger.reorgs, vec![2]);
}

#[tokio::test]
async fn every_record_is_provisional_and_carries_full_evidence() {
    let mut h = Harness::new(3, 8);
    h.mine(3);
    h.sync().await.unwrap();
    for m in &h.log {
        if let StreamMessage::Upsert {
            finality, record, ..
        } = m
        {
            assert_eq!(format!("{finality:?}"), "Provisional");
            assert!(!record.topics.is_empty(), "raw topics kept for evidence");
            assert!(record.attested_by.len() >= 2, "invariant 2: ≥ 2 attesters");
            assert_eq!(
                record.enrichment.token.as_ref().map(|t| t.symbol.as_str()),
                Some("USDC")
            );
            assert!(record.enrichment.value_usd.is_some());
        }
    }
}

#[derive(Clone, Debug)]
enum Op {
    /// Mine blocks without syncing (ingestor falls behind).
    Mine(usize),
    /// Mine and sync.
    MineSync(usize),
    /// Reorg of any depth (possibly below finality), then sync.
    ReorgSync { depth: u64, new_len: usize },
}

fn op(max_depth: u64) -> impl Strategy<Value = Op> {
    prop_oneof![
        2 => (1usize..4).prop_map(Op::Mine),
        2 => (1usize..4).prop_map(Op::MineSync),
        3 => (1..max_depth, 1usize..6).prop_map(|(depth, new_len)| Op::ReorgSync { depth, new_len }),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 256, .. ProptestConfig::default() })]

    /// For any sequence of mining and reorgs:
    /// * a reorg that forks at or above the finalized anchor is absorbed, and
    ///   the materialized stream equals a fresh read of the canonical chain;
    /// * a reorg that forks below the anchor halts ingestion, is published,
    ///   and leaves everything already emitted untouched.
    /// The stream is well-formed (strict seq, no double upserts, no
    /// retraction of finalized data) in every case.
    #[test]
    fn any_sequence_of_reorgs_converges_or_halts_safely(
        confirmations in 2u64..8,
        ops in proptest::collection::vec(op(12), 1..30),
    ) {
        let rt = tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap();
        rt.block_on(async {
            let mut h = Harness::new(3, confirmations);
            // Start with a finalized anchor so reorgs never reach genesis.
            h.mine(confirmations as usize + 1);
            h.sync().await.unwrap();
            for (salt, op) in ops.into_iter().enumerate() {
                match op {
                    Op::Mine(n) => h.mine(n),
                    Op::MineSync(n) => {
                        h.mine(n);
                        h.sync().await.unwrap();
                    }
                    Op::ReorgSync { depth, new_len } => {
                        let head = h.chain.lock().unwrap().head().number;
                        let anchor = h.ingestor.tracker().anchor().unwrap().number;
                        let fork_point = head.saturating_sub(depth);
                        let before = h.ledger.live_ids();
                        h.reorg(depth, new_len, salt as u64 + 1);
                        let res = h.sync().await;
                        if fork_point < anchor {
                            let halted = matches!(
                                res,
                                Err(SyncError::Ingest(IngestError::Tracker(TrackerError::Halted(_))))
                            );
                            assert!(halted, "fork at #{fork_point} below anchor #{anchor} must halt: {res:?}");
                            assert_eq!(h.ledger.halts.len(), 1);
                            assert_eq!(h.ledger.live_ids(), before, "halt must not change emitted state");
                            return;
                        }
                        res.unwrap();
                    }
                }
            }
            h.sync().await.unwrap();
            h.assert_matches_canonical_chain();

            let mut replay = Ledger::default();
            replay.apply(&h.log).expect("stream is well-formed");
        });
    }
}
