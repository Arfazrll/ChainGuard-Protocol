//! Chain-level primitives shared by every stage of ingestion.

use alloy_primitives::{Address, B256, Bytes};
use serde::{Deserialize, Serialize};
use std::fmt;

/// Identifier of an RPC node as configured by the operator (e.g. `"publicnode"`).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct NodeId(pub String);

impl fmt::Display for NodeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<&str> for NodeId {
    fn from(s: &str) -> Self {
        NodeId(s.to_owned())
    }
}

/// The minimal header fields needed to keep a reorg-safe view of the chain.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct BlockHeader {
    pub number: u64,
    pub hash: B256,
    pub parent_hash: B256,
    /// Unix seconds.
    pub timestamp: u64,
}

/// A compact reference to a block, carried on every derived record.
pub type BlockRef = BlockHeader;

/// An undecoded log exactly as returned by `eth_getLogs`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct RawLog {
    pub address: Address,
    pub topics: Vec<B256>,
    pub data: Bytes,
    pub block_hash: B256,
    pub block_number: u64,
    pub tx_hash: B256,
    pub tx_index: u64,
    pub log_index: u64,
}

/// A value that a quorum of independent nodes agreed on.
///
/// `attested_by` lists every node whose answer matched. Downstream stages use
/// it to enforce invariant 2: no high-severity alert unless at least two
/// independent sources agree.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Attested<T> {
    pub value: T,
    pub attested_by: Vec<NodeId>,
}

impl<T> Attested<T> {
    pub fn map<U>(self, f: impl FnOnce(T) -> U) -> Attested<U> {
        Attested {
            value: f(self.value),
            attested_by: self.attested_by,
        }
    }
}
