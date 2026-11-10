//! Multi-node chain access. Never trust a single node (invariant 2).
//!
//! [`NodeClient`] is one RPC endpoint. [`QuorumSource`] fans every question
//! out to all configured nodes and only accepts an answer that at least
//! `min_agreement` of them return *identically*. That covers the head, block
//! headers and the full log set of every block. A node that lags, forks,
//! omits logs or lies is simply outvoted; if no answer reaches quorum,
//! ingestion does not advance.

use crate::types::{Attested, BlockHeader, NodeId, RawLog};
use alloy_primitives::B256;
use futures::future::join_all;
use std::collections::{BTreeSet, HashMap};
use std::future::Future;
use std::hash::Hash;
use std::time::Duration;

#[derive(Debug, Clone, thiserror::Error, PartialEq, Eq)]
pub enum NodeError {
    #[error("transport error: {0}")]
    Transport(String),
    #[error("rpc error {code}: {message}")]
    Rpc { code: i64, message: String },
    #[error("malformed response: {0}")]
    BadResponse(String),
    #[error("timed out")]
    Timeout,
    #[error("method {0:?} is not on the read-only allowlist")]
    MethodNotAllowed(String),
}

/// A single read-only RPC endpoint.
///
/// There is intentionally no method here that can submit or sign anything.
pub trait NodeClient: Send + Sync {
    fn id(&self) -> &NodeId;
    fn chain_id(&self) -> impl Future<Output = Result<u64, NodeError>> + Send;
    fn block_number(&self) -> impl Future<Output = Result<u64, NodeError>> + Send;
    fn block_by_number(
        &self,
        number: u64,
    ) -> impl Future<Output = Result<Option<BlockHeader>, NodeError>> + Send;
    fn block_by_hash(
        &self,
        hash: B256,
    ) -> impl Future<Output = Result<Option<BlockHeader>, NodeError>> + Send;
    /// All logs of one block (`eth_getLogs` with an EIP-234 `blockHash` filter).
    fn logs_by_block_hash(
        &self,
        hash: B256,
    ) -> impl Future<Output = Result<Vec<RawLog>, NodeError>> + Send;
}

#[derive(Debug, Clone, thiserror::Error, PartialEq)]
pub enum SourceError {
    #[error(
        "no quorum on {what}: needed {needed} matching answers; got {answers:?}; errors {errors:?}"
    )]
    NoQuorum {
        what: String,
        needed: usize,
        /// Distinct answers and how many nodes gave each.
        answers: Vec<usize>,
        errors: Vec<(NodeId, String)>,
    },
    #[error("quorum agrees {what} does not exist")]
    NotFound { what: String },
}

/// The quorum-verified view of a chain that ingestion consumes.
pub trait ChainSource: Send + Sync {
    /// The highest block at least `min_agreement` nodes have reached, with a
    /// header those nodes agree on.
    fn head(&self) -> impl Future<Output = Result<Attested<BlockHeader>, SourceError>> + Send;
    fn block_by_number(
        &self,
        number: u64,
    ) -> impl Future<Output = Result<Attested<BlockHeader>, SourceError>> + Send;
    fn block_by_hash(
        &self,
        hash: B256,
    ) -> impl Future<Output = Result<Attested<BlockHeader>, SourceError>> + Send;
    /// The complete log set of `header`, sorted by log index.
    fn logs(
        &self,
        header: &BlockHeader,
    ) -> impl Future<Output = Result<Attested<Vec<RawLog>>, SourceError>> + Send;
}

#[derive(Debug, Clone)]
pub struct QuorumConfig {
    /// Identical answers required. Must be ≥ 2 unless `allow_single_source`.
    pub min_agreement: usize,
    pub request_timeout: Duration,
    /// Development only. Records produced this way carry a single attester,
    /// and downstream detection must never raise high severity on them.
    pub allow_single_source: bool,
}

impl Default for QuorumConfig {
    fn default() -> Self {
        Self {
            min_agreement: 2,
            request_timeout: Duration::from_secs(10),
            allow_single_source: false,
        }
    }
}

#[derive(Debug, Clone, thiserror::Error, PartialEq, Eq)]
pub enum QuorumConfigError {
    #[error("no nodes configured")]
    NoNodes,
    #[error("duplicate node id {0}")]
    DuplicateNode(NodeId),
    #[error(
        "min_agreement = {0} trusts a single node; ChainGuard requires ≥ 2 independent sources \
         (set allow_single_source only for local development)"
    )]
    SingleSourceForbidden(usize),
    #[error("min_agreement = {min} but only {nodes} nodes configured")]
    NotEnoughNodes { min: usize, nodes: usize },
    #[error(
        "min_agreement = {min} is not a strict majority of {nodes} nodes; two conflicting answers could both reach quorum"
    )]
    NotMajority { min: usize, nodes: usize },
}

pub struct QuorumSource<N> {
    nodes: Vec<N>,
    cfg: QuorumConfig,
}

impl<N: NodeClient> QuorumSource<N> {
    pub fn new(nodes: Vec<N>, cfg: QuorumConfig) -> Result<Self, QuorumConfigError> {
        if nodes.is_empty() {
            return Err(QuorumConfigError::NoNodes);
        }
        let mut seen = BTreeSet::new();
        for n in &nodes {
            if !seen.insert(n.id().clone()) {
                return Err(QuorumConfigError::DuplicateNode(n.id().clone()));
            }
        }
        let (min, count) = (cfg.min_agreement, nodes.len());
        if min < 2 && !(cfg.allow_single_source && min == 1) {
            return Err(QuorumConfigError::SingleSourceForbidden(min));
        }
        if min > count {
            return Err(QuorumConfigError::NotEnoughNodes { min, nodes: count });
        }
        if 2 * min <= count {
            return Err(QuorumConfigError::NotMajority { min, nodes: count });
        }
        Ok(Self { nodes, cfg })
    }

    pub fn nodes(&self) -> &[N] {
        &self.nodes
    }

    pub fn config(&self) -> &QuorumConfig {
        &self.cfg
    }

    async fn ask_all<'a, T, F, Fut>(&'a self, f: F) -> Vec<(NodeId, Result<T, NodeError>)>
    where
        F: Fn(&'a N) -> Fut,
        Fut: Future<Output = Result<T, NodeError>> + 'a,
    {
        let timeout = self.cfg.request_timeout;
        join_all(self.nodes.iter().map(|n| {
            let fut = f(n);
            async move {
                let res = match tokio::time::timeout(timeout, fut).await {
                    Ok(r) => r,
                    Err(_) => Err(NodeError::Timeout),
                };
                (n.id().clone(), res)
            }
        }))
        .await
    }

    /// Group identical answers; accept the one with ≥ `min_agreement` votes.
    /// Majority configuration guarantees at most one answer can qualify.
    fn tally<T: Eq + Hash + Clone>(
        &self,
        what: impl Into<String>,
        answers: Vec<(NodeId, Result<T, NodeError>)>,
    ) -> Result<Attested<T>, SourceError> {
        let mut groups: HashMap<T, Vec<NodeId>> = HashMap::new();
        let mut errors = Vec::new();
        for (id, r) in answers {
            match r {
                Ok(v) => groups.entry(v).or_default().push(id),
                Err(e) => errors.push((id, e.to_string())),
            }
        }
        if let Some((value, mut ids)) = groups
            .iter()
            .find(|(_, ids)| ids.len() >= self.cfg.min_agreement)
            .map(|(v, ids)| (v.clone(), ids.clone()))
        {
            ids.sort();
            return Ok(Attested {
                value,
                attested_by: ids,
            });
        }
        let mut sizes: Vec<usize> = groups.values().map(Vec::len).collect();
        sizes.sort_unstable_by(|a, b| b.cmp(a));
        Err(SourceError::NoQuorum {
            what: what.into(),
            needed: self.cfg.min_agreement,
            answers: sizes,
            errors,
        })
    }

    fn found(
        what: String,
        a: Attested<Option<BlockHeader>>,
    ) -> Result<Attested<BlockHeader>, SourceError> {
        match a.value {
            Some(h) => Ok(Attested {
                value: h,
                attested_by: a.attested_by,
            }),
            None => Err(SourceError::NotFound { what }),
        }
    }
}

impl<N: NodeClient> ChainSource for QuorumSource<N> {
    async fn head(&self) -> Result<Attested<BlockHeader>, SourceError> {
        let answers = self.ask_all(|n| n.block_number()).await;
        let mut heights: Vec<u64> = answers
            .iter()
            .filter_map(|(_, r)| r.as_ref().ok().copied())
            .collect();
        heights.sort_unstable_by(|a, b| b.cmp(a));
        let Some(&target) = heights.get(self.cfg.min_agreement - 1) else {
            let errors = answers
                .into_iter()
                .filter_map(|(id, r)| r.err().map(|e| (id, e.to_string())))
                .collect();
            return Err(SourceError::NoQuorum {
                what: "head height".into(),
                needed: self.cfg.min_agreement,
                answers: vec![heights.len()],
                errors,
            });
        };
        // `target` is the highest height at least `min_agreement` nodes have
        // reached; now require them to agree on *which* block is there.
        self.block_by_number(target).await
    }

    async fn block_by_number(&self, number: u64) -> Result<Attested<BlockHeader>, SourceError> {
        let answers = self
            .ask_all(|n| async move {
                let h = n.block_by_number(number).await?;
                match h {
                    Some(h) if h.number != number => Err(NodeError::BadResponse(format!(
                        "asked for block {number}, got {}",
                        h.number
                    ))),
                    other => Ok(other),
                }
            })
            .await;
        let what = format!("block #{number}");
        Self::found(what.clone(), self.tally(what, answers)?)
    }

    async fn block_by_hash(&self, hash: B256) -> Result<Attested<BlockHeader>, SourceError> {
        let answers = self
            .ask_all(|n| async move {
                let h = n.block_by_hash(hash).await?;
                match h {
                    Some(h) if h.hash != hash => Err(NodeError::BadResponse(format!(
                        "asked for block {hash}, got {}",
                        h.hash
                    ))),
                    other => Ok(other),
                }
            })
            .await;
        let what = format!("block {hash}");
        Self::found(what.clone(), self.tally(what, answers)?)
    }

    async fn logs(&self, header: &BlockHeader) -> Result<Attested<Vec<RawLog>>, SourceError> {
        let (hash, number) = (header.hash, header.number);
        let answers = self
            .ask_all(|n| async move {
                let mut logs = n.logs_by_block_hash(hash).await?;
                if let Some(bad) = logs
                    .iter()
                    .find(|l| l.block_hash != hash || l.block_number != number)
                {
                    return Err(NodeError::BadResponse(format!(
                        "log {} belongs to block #{} {}, not #{number} {hash}",
                        bad.log_index, bad.block_number, bad.block_hash
                    )));
                }
                logs.sort_by_key(|l| l.log_index);
                if logs.windows(2).any(|w| w[0].log_index == w[1].log_index) {
                    return Err(NodeError::BadResponse("duplicate log index".into()));
                }
                Ok(logs)
            })
            .await;
        self.tally(format!("logs of block #{number} {hash}"), answers)
    }
}
