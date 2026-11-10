//! Reorg on a real test chain (Anvil), through the real read-only RPC client.
//!
//! ```sh
//! anvil --port 8545 &
//! CHAINGUARD_ANVIL_URL=http://127.0.0.1:8545 cargo test -p chainguard-rpc --test anvil_reorg -- --ignored
//! ```
//!
//! CI runs this on every push (see .github/workflows/ci.yml).
//!
//! The *test harness* drives Anvil with `eth_sendTransaction` and
//! `anvil_reorg` through its own HTTP client. ChainGuard's client cannot send
//! those methods, and the test asserts that too.

use alloy_primitives::B256;
use chainguard_ingest_core::enrich::Enricher;
use chainguard_ingest_core::record::record_id;
use chainguard_ingest_core::testkit::{Ledger, ReplacingTable};
use chainguard_ingest_core::{
    IngestConfig, Ingestor, NodeClient, NodeError, QuorumConfig, QuorumSource, ReorgTracker,
    StreamMessage,
};
use chainguard_rpc::HttpNode;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::sync::Arc;
use std::time::Duration;

/// Test-harness JSON-RPC (not ChainGuard's client).
struct Driver {
    url: String,
    http: reqwest::Client,
}

impl Driver {
    async fn rpc(&self, method: &str, params: Value) -> Value {
        let body = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
        let v: Value = self
            .http
            .post(&self.url)
            .json(&body)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert!(v.get("error").is_none(), "{method}: {v}");
        v["result"].clone()
    }

    /// Creation code that emits one log (`LOG1` with `topic`) and deploys nothing:
    /// PUSH32 topic, PUSH1 0, PUSH1 0, LOG1, STOP.
    fn emitter(from: &str, topic: B256) -> Value {
        json!({ "from": from, "data": format!("0x7f{}60006000a100", alloy_primitives::hex::encode(topic)), "gas": "0x186a0" })
    }
}

fn topic(i: u64) -> B256 {
    alloy_primitives::keccak256(format!("chainguard-anvil-{i}"))
}

async fn canonical_record_ids(node: &HttpNode, from: u64) -> BTreeSet<B256> {
    let head = node.block_number().await.unwrap();
    let mut ids = BTreeSet::new();
    for n in from..=head {
        let h = node.block_by_number(n).await.unwrap().unwrap();
        for l in node.logs_by_block_hash(h.hash).await.unwrap() {
            ids.insert(record_id(31337, h.hash, l.log_index));
        }
    }
    ids
}

#[derive(Default)]
struct Collected {
    ledger: Ledger,
    table: ReplacingTable,
    log: Vec<StreamMessage>,
}

impl Collected {
    async fn sync(&mut self, ingestor: &mut Ingestor<QuorumSource<HttpNode>>) {
        let (ledger, table, log) = (&mut self.ledger, &mut self.table, &mut self.log);
        ingestor
            .sync_to_head(|m| {
                ledger.apply(m)?;
                table.apply(m);
                log.extend_from_slice(m);
                Ok::<_, String>(())
            })
            .await
            .unwrap();
    }
}

#[tokio::test]
#[ignore = "needs a running anvil; set CHAINGUARD_ANVIL_URL"]
async fn anvil_reorg_retracts_and_reemits_derived_state() {
    let url = std::env::var("CHAINGUARD_ANVIL_URL")
        .expect("set CHAINGUARD_ANVIL_URL to an anvil endpoint");
    let driver = Driver {
        url: url.clone(),
        http: reqwest::Client::new(),
    };
    let from = driver.rpc("eth_accounts", json!([])).await[0]
        .as_str()
        .unwrap()
        .to_owned();

    // ChainGuard's own client refuses the methods the harness is about to use.
    let guard = HttpNode::new("guard", &url, Duration::from_secs(5)).unwrap();
    for m in ["eth_sendTransaction", "anvil_reorg", "eth_accounts"] {
        assert_eq!(
            guard.call::<Value>(m, json!([])).await,
            Err(NodeError::MethodNotAllowed(m.into()))
        );
    }

    // Six blocks (automine), one log each.
    let start = guard.block_number().await.unwrap() + 1;
    for i in 0..6 {
        driver
            .rpc(
                "eth_sendTransaction",
                json!([Driver::emitter(&from, topic(i))]),
            )
            .await;
    }

    // Two client instances against the same anvil satisfy the quorum
    // mechanics; independence of providers is what production config adds.
    let nodes = vec![
        HttpNode::new("anvil-a", &url, Duration::from_secs(5)).unwrap(),
        HttpNode::new("anvil-b", &url, Duration::from_secs(5)).unwrap(),
    ];
    let source = QuorumSource::new(nodes, QuorumConfig::default()).unwrap();
    let mut ingestor = Ingestor::new(
        source,
        ReorgTracker::new(31337, 10).unwrap(),
        Arc::new(Enricher::empty(31337)),
        IngestConfig {
            start_block: Some(start),
            ..IngestConfig::default()
        },
    );
    let mut out = Collected::default();
    out.sync(&mut ingestor).await;
    let before = canonical_record_ids(&guard, start).await;
    assert_eq!(before.len(), 6);
    assert_eq!(out.ledger.live_ids(), before);

    // Reorg the last 3 blocks; the replacements carry 2 *different* logs.
    driver
        .rpc(
            "anvil_reorg",
            json!([
                3,
                [
                    [Driver::emitter(&from, topic(100)), 0],
                    [Driver::emitter(&from, topic(101)), 2]
                ]
            ]),
        )
        .await;
    out.log.clear();
    out.sync(&mut ingestor).await;

    let after = canonical_record_ids(&guard, start).await;
    assert_eq!(after.len(), 5, "3 untouched + 2 replacement logs");
    assert_eq!(out.ledger.reorgs, vec![3], "one reorg of depth 3");
    assert_eq!(
        out.ledger.live_ids(),
        after,
        "materialized state equals a fresh read of the canonical chain"
    );
    assert_eq!(
        out.table.live_ids(),
        after,
        "ReplacingMergeTree semantics agree"
    );
    let retracts = out
        .log
        .iter()
        .filter(|m| matches!(m, StreamMessage::Retract { .. }))
        .count();
    let upserts = out
        .log
        .iter()
        .filter(|m| matches!(m, StreamMessage::Upsert { .. }))
        .count();
    assert_eq!((retracts, upserts), (3, 2));
}
