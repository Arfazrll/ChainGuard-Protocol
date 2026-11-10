//! Read-only Ethereum JSON-RPC client (invariant 1).
//!
//! ChainGuard never holds keys and never sends transactions. This client
//! enforces that in code rather than by convention: every call goes through
//! [`HttpNode::call`], which refuses any method not on [`ALLOWED_METHODS`]
//! *before* a byte reaches the network. There is no signer, wallet or
//! transaction-building code in this crate or its dependencies, and
//! `scripts/check-invariants.sh` fails CI if any appears.

use alloy_primitives::{Address, B256, Bytes, U64};
use chainguard_ingest_core::{BlockHeader, NodeClient, NodeError, NodeId, RawLog};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

/// The only JSON-RPC methods this client will ever send. All are reads.
pub const ALLOWED_METHODS: &[&str] = &[
    "eth_chainId",
    "eth_blockNumber",
    "eth_getBlockByNumber",
    "eth_getBlockByHash",
    "eth_getLogs",
    "eth_getTransactionByHash",
    "eth_getTransactionReceipt",
    "eth_getCode",
    "eth_getBalance",
    "eth_getStorageAt",
    "eth_call",
    "net_version",
    "web3_clientVersion",
];

/// Method-name prefixes that can mutate state, move funds, touch keys or
/// administer a node. Refused even if someone adds them to the allowlist.
pub const FORBIDDEN_PREFIXES: &[&str] = &[
    "eth_send",
    "eth_sign",
    "eth_submit",
    "eth_accounts",
    "eth_coinbase",
    "personal_",
    "wallet_",
    "admin_",
    "miner_",
    "debug_set",
    "engine_",
    "clique_",
    "txpool_",
    "anvil_",
    "hardhat_",
    "evm_",
];

pub fn is_allowed(method: &str) -> bool {
    ALLOWED_METHODS.contains(&method) && !FORBIDDEN_PREFIXES.iter().any(|p| method.starts_with(p))
}

pub struct HttpNode {
    id: NodeId,
    url: String,
    http: reqwest::Client,
    next_id: AtomicU64,
}

impl HttpNode {
    pub fn new(
        id: impl Into<String>,
        url: impl Into<String>,
        timeout: Duration,
    ) -> Result<Self, NodeError> {
        let http = reqwest::Client::builder()
            .timeout(timeout)
            .user_agent(concat!("chainguard-ingestd/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| NodeError::Transport(e.to_string()))?;
        Ok(Self {
            id: NodeId(id.into()),
            url: url.into(),
            http,
            next_id: AtomicU64::new(1),
        })
    }

    /// The single choke point for every request this process makes to a node.
    pub async fn call<T: DeserializeOwned>(
        &self,
        method: &str,
        params: Value,
    ) -> Result<T, NodeError> {
        if !is_allowed(method) {
            tracing::error!(node = %self.id, method, "refusing non-read-only RPC method");
            return Err(NodeError::MethodNotAllowed(method.to_owned()));
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let body = json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params });
        let resp = self
            .http
            .post(&self.url)
            .json(&body)
            .send()
            .await
            .map_err(|e| {
                if e.is_timeout() {
                    NodeError::Timeout
                } else {
                    NodeError::Transport(redact(e))
                }
            })?;
        let status = resp.status();
        if !status.is_success() {
            return Err(NodeError::Transport(format!("HTTP {status}")));
        }
        let envelope: Envelope = resp
            .json()
            .await
            .map_err(|e| NodeError::BadResponse(e.to_string()))?;
        if let Some(err) = envelope.error {
            return Err(NodeError::Rpc {
                code: err.code,
                message: err.message,
            });
        }
        let result = envelope.result.unwrap_or(Value::Null);
        serde_json::from_value(result).map_err(|e| NodeError::BadResponse(format!("{method}: {e}")))
    }
}

/// Never leak provider API keys embedded in RPC URLs into logs or errors.
fn redact(e: reqwest::Error) -> String {
    e.without_url().to_string()
}

#[derive(Deserialize)]
struct Envelope {
    result: Option<Value>,
    error: Option<RpcError>,
}

#[derive(Deserialize)]
struct RpcError {
    code: i64,
    message: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RpcBlock {
    number: U64,
    hash: B256,
    parent_hash: B256,
    timestamp: U64,
}

impl From<RpcBlock> for BlockHeader {
    fn from(b: RpcBlock) -> Self {
        BlockHeader {
            number: b.number.to(),
            hash: b.hash,
            parent_hash: b.parent_hash,
            timestamp: b.timestamp.to(),
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RpcLog {
    address: Address,
    topics: Vec<B256>,
    data: Bytes,
    block_hash: Option<B256>,
    block_number: Option<U64>,
    transaction_hash: Option<B256>,
    transaction_index: Option<U64>,
    log_index: Option<U64>,
    #[serde(default)]
    removed: bool,
}

impl TryFrom<RpcLog> for RawLog {
    type Error = NodeError;
    fn try_from(l: RpcLog) -> Result<Self, NodeError> {
        let missing =
            |f: &str| NodeError::BadResponse(format!("log is missing {f} (pending log?)"));
        if l.removed {
            return Err(NodeError::BadResponse(
                "node returned a removed log for a block-hash query".into(),
            ));
        }
        Ok(RawLog {
            address: l.address,
            topics: l.topics,
            data: l.data,
            block_hash: l.block_hash.ok_or_else(|| missing("blockHash"))?,
            block_number: l.block_number.ok_or_else(|| missing("blockNumber"))?.to(),
            tx_hash: l
                .transaction_hash
                .ok_or_else(|| missing("transactionHash"))?,
            tx_index: l
                .transaction_index
                .ok_or_else(|| missing("transactionIndex"))?
                .to(),
            log_index: l.log_index.ok_or_else(|| missing("logIndex"))?.to(),
        })
    }
}

impl NodeClient for HttpNode {
    fn id(&self) -> &NodeId {
        &self.id
    }

    async fn chain_id(&self) -> Result<u64, NodeError> {
        Ok(self.call::<U64>("eth_chainId", json!([])).await?.to())
    }

    async fn block_number(&self) -> Result<u64, NodeError> {
        Ok(self.call::<U64>("eth_blockNumber", json!([])).await?.to())
    }

    async fn block_by_number(&self, number: u64) -> Result<Option<BlockHeader>, NodeError> {
        let b: Option<RpcBlock> = self
            .call(
                "eth_getBlockByNumber",
                json!([format!("{number:#x}"), false]),
            )
            .await?;
        Ok(b.map(Into::into))
    }

    async fn block_by_hash(&self, hash: B256) -> Result<Option<BlockHeader>, NodeError> {
        let b: Option<RpcBlock> = self
            .call("eth_getBlockByHash", json!([hash, false]))
            .await?;
        Ok(b.map(Into::into))
    }

    async fn logs_by_block_hash(&self, hash: B256) -> Result<Vec<RawLog>, NodeError> {
        let logs: Vec<RpcLog> = self
            .call("eth_getLogs", json!([{ "blockHash": hash }]))
            .await?;
        logs.into_iter().map(RawLog::try_from).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    /// Methods that would let a compromised or buggy ChainGuard move funds,
    /// sign, or administer a node.
    const MUST_NEVER_BE_ALLOWED: &[&str] = &[
        "eth_sendRawTransaction",
        "eth_sendTransaction",
        "eth_sign",
        "eth_signTransaction",
        "eth_signTypedData_v4",
        "eth_accounts",
        "personal_sign",
        "personal_unlockAccount",
        "wallet_sendCalls",
        "admin_addPeer",
        "miner_start",
        "debug_setHead",
        "anvil_setBalance",
    ];

    #[test]
    fn invariant_read_only_allowlist_contains_no_write_methods() {
        for m in ALLOWED_METHODS {
            assert!(
                !FORBIDDEN_PREFIXES.iter().any(|p| m.starts_with(p)),
                "{m} is on the allowlist but matches a forbidden prefix"
            );
        }
        for m in MUST_NEVER_BE_ALLOWED {
            assert!(!is_allowed(m), "{m} must never be allowed");
        }
    }

    #[tokio::test]
    async fn invariant_read_only_client_refuses_write_methods_without_touching_the_network() {
        // An unroutable URL: if the guard failed open we would see a transport
        // error instead of MethodNotAllowed.
        let node = HttpNode::new("guard", "http://192.0.2.1:9", Duration::from_millis(50)).unwrap();
        for m in MUST_NEVER_BE_ALLOWED {
            let r = node.call::<Value>(m, json!([])).await;
            assert_eq!(r, Err(NodeError::MethodNotAllowed((*m).to_owned())), "{m}");
        }
    }

    /// A one-shot HTTP server answering with a canned JSON-RPC result.
    async fn serve_once(result: Value) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.unwrap();
            let mut buf = vec![0u8; 16 * 1024];
            let _ = sock.read(&mut buf).await.unwrap();
            let body = json!({ "jsonrpc": "2.0", "id": 1, "result": result }).to_string();
            let resp = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            );
            sock.write_all(resp.as_bytes()).await.unwrap();
        });
        format!("http://{addr}")
    }

    #[tokio::test]
    async fn parses_a_mainnet_shaped_block_and_logs() {
        let url = serve_once(json!({
            "number": "0x1312d00",
            "hash": "0x6f3a3e3b54d1ba3f8c2a3b83fd0f8a8b9e8e55a0a3c2b6d4f1e7a9c0b2d4e6f8",
            "parentHash": "0x1f3a3e3b54d1ba3f8c2a3b83fd0f8a8b9e8e55a0a3c2b6d4f1e7a9c0b2d4e6f8",
            "timestamp": "0x6553f100",
            "transactions": []
        }))
        .await;
        let node = HttpNode::new("t", url, Duration::from_secs(5)).unwrap();
        let h = node.block_by_number(20_000_000).await.unwrap().unwrap();
        assert_eq!(h.number, 20_000_000);
        assert_eq!(h.timestamp, 0x6553f100);

        let url = serve_once(json!([{
            "address": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            "topics": ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"],
            "data": "0x",
            "blockHash": "0x6f3a3e3b54d1ba3f8c2a3b83fd0f8a8b9e8e55a0a3c2b6d4f1e7a9c0b2d4e6f8",
            "blockNumber": "0x1312d00",
            "transactionHash": "0x0000000000000000000000000000000000000000000000000000000000000001",
            "transactionIndex": "0x0",
            "logIndex": "0x5",
            "removed": false
        }]))
        .await;
        let node = HttpNode::new("t", url, Duration::from_secs(5)).unwrap();
        let logs = node.logs_by_block_hash(h.hash).await.unwrap();
        assert_eq!(logs.len(), 1);
        assert_eq!(logs[0].log_index, 5);
    }

    #[tokio::test]
    async fn removed_logs_are_rejected() {
        let url = serve_once(json!([{
            "address": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            "topics": [], "data": "0x",
            "blockHash": "0x6f3a3e3b54d1ba3f8c2a3b83fd0f8a8b9e8e55a0a3c2b6d4f1e7a9c0b2d4e6f8",
            "blockNumber": "0x1", "transactionHash": "0x0000000000000000000000000000000000000000000000000000000000000001",
            "transactionIndex": "0x0", "logIndex": "0x0", "removed": true
        }]))
        .await;
        let node = HttpNode::new("t", url, Duration::from_secs(5)).unwrap();
        assert!(matches!(
            node.logs_by_block_hash(B256::ZERO).await,
            Err(NodeError::BadResponse(_))
        ));
    }
}
