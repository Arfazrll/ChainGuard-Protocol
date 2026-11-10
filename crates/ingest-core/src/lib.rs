//! # SvlteChain ingestion core
//!
//! Reorg-safe, multi-node-verified ingestion of on-chain events, with no
//! network I/O of its own. The binary (`chainguard-ingestd`) supplies the
//! RPC transport and the stream-bus sink.
//!
//! Pipeline: [`source::QuorumSource`] (N nodes, majority must agree) →
//! [`decode`] (ABI) → [`enrich`] (labels, tokens, USD) →
//! [`tracker::ReorgTracker`] (provisional window, retract and re-emit on
//! reorg) → [`record::StreamMessage`]s for the bus.
//!
//! SvlteChain is read-only by design: nothing in this crate can sign or send
//! a transaction.

pub mod decode;
pub mod enrich;
pub mod ingestor;
pub mod record;
mod serde_num;
pub mod source;
pub mod tracker;
pub mod types;

#[cfg(any(test, feature = "testkit"))]
pub mod testkit;

pub use ingestor::{IngestConfig, IngestError, Ingestor, SyncError};
pub use record::{Record, StreamMessage};
pub use source::{ChainSource, NodeClient, NodeError, QuorumConfig, QuorumSource, SourceError};
pub use tracker::{ReorgTracker, TrackerError};
pub use types::{Attested, BlockHeader, NodeId, RawLog};
