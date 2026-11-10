#![allow(dead_code)]

use chainguard_ingest_core::enrich::Enricher;
use chainguard_ingest_core::testkit::{Ledger, MockChain, MockNode, ReplacingTable};
use chainguard_ingest_core::{
    IngestConfig, Ingestor, QuorumConfig, QuorumSource, ReorgTracker, StreamMessage, SyncError,
};
use std::sync::{Arc, Mutex};

pub const CHAIN_ID: u64 = 1;
pub const SEED_LABELS: &str = include_str!("../../../../data/labels/ethereum-mainnet.json");

pub type MockIngestor = Ingestor<QuorumSource<MockNode>>;

pub struct Harness {
    pub chain: Arc<Mutex<MockChain>>,
    pub nodes: Vec<MockNode>,
    pub ingestor: MockIngestor,
    pub ledger: Ledger,
    pub table: ReplacingTable,
    pub log: Vec<StreamMessage>,
}

pub fn quorum(nodes: &[MockNode]) -> QuorumSource<MockNode> {
    let cfg = QuorumConfig {
        min_agreement: nodes.len() / 2 + 1,
        ..QuorumConfig::default()
    };
    QuorumSource::new(nodes.to_vec(), cfg).expect("valid quorum")
}

pub fn enricher() -> Arc<Enricher> {
    Arc::new(Enricher::from_json(SEED_LABELS, CHAIN_ID).unwrap())
}

impl Harness {
    /// A chain with one block mined, `n` honest nodes, ingestion from block 1.
    pub fn new(n: usize, confirmations: u64) -> Self {
        let chain = MockChain::shared(CHAIN_ID);
        chain.lock().unwrap().mine(1);
        let nodes: Vec<MockNode> = (0..n)
            .map(|i| MockNode::new(&format!("node-{i}"), chain.clone()))
            .collect();
        let tracker = ReorgTracker::new(CHAIN_ID, confirmations).unwrap();
        let ingestor = Ingestor::new(
            quorum(&nodes),
            tracker,
            enricher(),
            IngestConfig {
                start_block: Some(1),
                ..IngestConfig::default()
            },
        );
        Self {
            chain,
            nodes,
            ingestor,
            ledger: Ledger::default(),
            table: ReplacingTable::default(),
            log: vec![],
        }
    }

    pub fn mine(&self, n: usize) {
        self.chain.lock().unwrap().mine(n);
    }

    pub fn reorg(&self, depth: u64, new_len: usize, salt: u64) {
        self.chain.lock().unwrap().reorg(depth, new_len, salt);
    }

    pub async fn sync(&mut self) -> Result<usize, SyncError<String>> {
        let (ledger, table, log) = (&mut self.ledger, &mut self.table, &mut self.log);
        self.ingestor
            .sync_to_head(|msgs| {
                ledger.apply(msgs)?;
                table.apply(msgs);
                log.extend_from_slice(msgs);
                Ok::<_, String>(())
            })
            .await
    }

    /// The core correctness property: what downstream holds equals what a
    /// from-scratch read of the final canonical chain would produce.
    pub fn assert_matches_canonical_chain(&self) {
        let expected = self.chain.lock().unwrap().expected_record_ids(1);
        assert_eq!(
            self.ledger.live_ids(),
            expected,
            "ledger diverged from the canonical chain"
        );
        assert_eq!(
            self.table.live_ids(),
            expected,
            "ReplacingMergeTree view diverged from the canonical chain"
        );
        assert_eq!(
            self.ingestor.tracker().tip().map(|t| t.hash),
            Some(self.chain.lock().unwrap().head().hash),
            "tracker tip is not the chain head"
        );
        let chain = self.chain.lock().unwrap();
        let head = chain.head().hash;
        for b in &self.ledger.finalized_blocks {
            let h = chain.header(*b).unwrap();
            assert_eq!(
                chain.canonical_at(head, h.number).map(|c| c.hash),
                Some(*b),
                "finalized a non-canonical block"
            );
        }
    }
}
