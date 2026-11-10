//! In-memory fork-tree chain, mock nodes and stream ledgers for testing
//! reorg handling and multi-node verification without a real network.

use crate::decode::encode;
use crate::record::{Record, StreamMessage, record_id};
use crate::source::{NodeClient, NodeError};
use crate::types::{BlockHeader, NodeId, RawLog};
use alloy_primitives::{Address, B256, U256, address, keccak256};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::{Arc, Mutex};

pub const USDC: Address = address!("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");

#[derive(Clone, Debug)]
struct MockBlock {
    header: BlockHeader,
    logs: Vec<RawLog>,
}

/// A tree of blocks with a movable canonical head. Old forks stay
/// retrievable by hash, as on a real node shortly after a reorg.
#[derive(Clone, Debug)]
pub struct MockChain {
    pub chain_id: u64,
    blocks: HashMap<B256, MockBlock>,
    head: B256,
}

impl MockChain {
    pub fn new(chain_id: u64) -> Self {
        let genesis = BlockHeader {
            number: 0,
            hash: keccak256(b"chainguard-mock-genesis"),
            parent_hash: B256::ZERO,
            timestamp: 1_700_000_000,
        };
        let mut blocks = HashMap::new();
        blocks.insert(
            genesis.hash,
            MockBlock {
                header: genesis,
                logs: vec![],
            },
        );
        Self {
            chain_id,
            blocks,
            head: genesis.hash,
        }
    }

    pub fn shared(chain_id: u64) -> Arc<Mutex<Self>> {
        Arc::new(Mutex::new(Self::new(chain_id)))
    }

    pub fn head(&self) -> BlockHeader {
        self.blocks[&self.head].header
    }

    pub fn header(&self, hash: B256) -> Option<BlockHeader> {
        self.blocks.get(&hash).map(|b| b.header)
    }

    pub fn logs(&self, hash: B256) -> Vec<RawLog> {
        self.blocks
            .get(&hash)
            .map(|b| b.logs.clone())
            .unwrap_or_default()
    }

    /// Build `n` blocks on top of `from` without moving the head.
    /// `salt` distinguishes competing forks at the same heights.
    pub fn extend(&mut self, from: B256, n: usize, salt: u64) -> B256 {
        let mut parent = self.blocks[&from].header;
        for _ in 0..n {
            let number = parent.number + 1;
            let mut pre = Vec::with_capacity(48);
            pre.extend_from_slice(parent.hash.as_slice());
            pre.extend_from_slice(&number.to_be_bytes());
            pre.extend_from_slice(&salt.to_be_bytes());
            let hash = keccak256(&pre);
            let header = BlockHeader {
                number,
                hash,
                parent_hash: parent.hash,
                timestamp: parent.timestamp + 12,
            };
            let logs = Self::synth_logs(&header);
            self.blocks.insert(hash, MockBlock { header, logs });
            parent = header;
        }
        parent.hash
    }

    /// 1–3 USDC transfers per block, amounts derived from the block hash, so
    /// competing forks produce different records.
    fn synth_logs(h: &BlockHeader) -> Vec<RawLog> {
        let count = 1 + (h.hash[0] % 3) as u64;
        (0..count)
            .map(|i| {
                let from =
                    Address::from_word(keccak256([h.hash.as_slice(), &[i as u8, 0]].concat()));
                let to = Address::from_word(keccak256([h.hash.as_slice(), &[i as u8, 1]].concat()));
                let amount = U256::from(
                    1 + u64::from_be_bytes(h.hash[8..16].try_into().unwrap()) % 1_000_000_000_000,
                );
                let (topics, data) = encode::erc20_transfer(from, to, amount);
                RawLog {
                    address: USDC,
                    topics,
                    data,
                    block_hash: h.hash,
                    block_number: h.number,
                    tx_hash: keccak256([h.hash.as_slice(), &[i as u8, 2]].concat()),
                    tx_index: i,
                    log_index: i,
                }
            })
            .collect()
    }

    pub fn mine(&mut self, n: usize) -> B256 {
        self.head = self.extend(self.head, n, 0);
        self.head
    }

    /// Replace the top `depth` blocks with a new fork of `new_len` blocks.
    pub fn reorg(&mut self, depth: u64, new_len: usize, salt: u64) -> B256 {
        let ancestor = self.ancestor(self.head, depth);
        self.head = self.extend(ancestor, new_len, salt);
        self.head
    }

    pub fn set_head(&mut self, hash: B256) {
        assert!(self.blocks.contains_key(&hash));
        self.head = hash;
    }

    pub fn ancestor(&self, mut hash: B256, depth: u64) -> B256 {
        for _ in 0..depth {
            let h = self.blocks[&hash].header;
            if h.number == 0 {
                break;
            }
            hash = h.parent_hash;
        }
        hash
    }

    /// The canonical block at `number` as seen from `head`.
    pub fn canonical_at(&self, head: B256, number: u64) -> Option<BlockHeader> {
        let h = self.blocks[&head].header;
        if number > h.number {
            return None;
        }
        self.header(self.ancestor(head, h.number - number))
    }

    /// Canonical headers from `from` to the head, inclusive.
    pub fn canonical_range(&self, from: u64) -> Vec<BlockHeader> {
        let tip = self.head().number;
        (from..=tip)
            .filter_map(|n| self.canonical_at(self.head, n))
            .collect()
    }

    /// The record ids a correct ingestor must hold for blocks `from..=head`.
    pub fn expected_record_ids(&self, from: u64) -> BTreeSet<B256> {
        self.canonical_range(from)
            .iter()
            .flat_map(|h| {
                self.logs(h.hash)
                    .into_iter()
                    .map(|l| record_id(self.chain_id, h.hash, l.log_index))
            })
            .collect()
    }
}

/// How a mock node misbehaves.
#[derive(Clone, Debug, Default)]
pub struct Behavior {
    /// Unreachable: every call fails.
    pub down: bool,
    /// Sees the chain this many blocks behind the true head.
    pub lag: u64,
    /// Follows this head instead of the true one (a node stuck on a fork).
    pub view_head: Option<B256>,
    /// Returns fabricated hashes for blocks at or above this height.
    pub forge_from: Option<u64>,
    /// Omits the last log of every block.
    pub drop_last_log: bool,
}

#[derive(Clone)]
pub struct MockNode {
    id: NodeId,
    chain: Arc<Mutex<MockChain>>,
    pub behavior: Arc<Mutex<Behavior>>,
}

impl MockNode {
    pub fn new(id: &str, chain: Arc<Mutex<MockChain>>) -> Self {
        Self {
            id: NodeId::from(id),
            chain,
            behavior: Arc::default(),
        }
    }

    pub fn set(&self, f: impl FnOnce(&mut Behavior)) {
        f(&mut self.behavior.lock().unwrap());
    }

    fn view(&self) -> Result<(MockChain, Behavior), NodeError> {
        let b = self.behavior.lock().unwrap().clone();
        if b.down {
            return Err(NodeError::Transport("connection refused".into()));
        }
        Ok((self.chain.lock().unwrap().clone(), b))
    }

    fn effective_head(chain: &MockChain, b: &Behavior) -> B256 {
        let head = b.view_head.unwrap_or(chain.head);
        chain.ancestor(head, b.lag)
    }

    fn forge(b: &Behavior, mut h: BlockHeader) -> BlockHeader {
        if b.forge_from.is_some_and(|from| h.number >= from) {
            h.hash = keccak256([h.hash.as_slice(), b"forged"].concat());
        }
        h
    }
}

impl NodeClient for MockNode {
    fn id(&self) -> &NodeId {
        &self.id
    }

    async fn chain_id(&self) -> Result<u64, NodeError> {
        Ok(self.view()?.0.chain_id)
    }

    async fn block_number(&self) -> Result<u64, NodeError> {
        let (c, b) = self.view()?;
        Ok(c.header(Self::effective_head(&c, &b)).unwrap().number)
    }

    async fn block_by_number(&self, number: u64) -> Result<Option<BlockHeader>, NodeError> {
        let (c, b) = self.view()?;
        Ok(c.canonical_at(Self::effective_head(&c, &b), number)
            .map(|h| Self::forge(&b, h)))
    }

    async fn block_by_hash(&self, hash: B256) -> Result<Option<BlockHeader>, NodeError> {
        let (c, b) = self.view()?;
        Ok(c.header(hash).map(|h| Self::forge(&b, h)))
    }

    async fn logs_by_block_hash(&self, hash: B256) -> Result<Vec<RawLog>, NodeError> {
        let (c, b) = self.view()?;
        let mut logs = c.logs(hash);
        if b.drop_last_log {
            logs.pop();
        }
        Ok(logs)
    }
}

/// Applies a message stream and checks it is well-formed: strictly
/// increasing `seq`, no double upserts, retractions only of live records,
/// and never a retraction from a finalized block.
#[derive(Default, Debug)]
pub struct Ledger {
    pub live: BTreeMap<B256, Record>,
    pub finalized_blocks: BTreeSet<B256>,
    pub reorgs: Vec<usize>,
    pub halts: Vec<String>,
    pub messages: usize,
    last_seq: u64,
}

impl Ledger {
    pub fn apply(&mut self, msgs: &[StreamMessage]) -> Result<(), String> {
        for m in msgs {
            if m.seq() <= self.last_seq {
                return Err(format!(
                    "seq went from {} to {} ({})",
                    self.last_seq,
                    m.seq(),
                    m.kind()
                ));
            }
            self.last_seq = m.seq();
            self.messages += 1;
            match m {
                StreamMessage::Upsert {
                    record,
                    deleted: false,
                    ..
                } => {
                    if self.live.insert(record.id, record.clone()).is_some() {
                        return Err(format!("double upsert of {}", record.id));
                    }
                }
                StreamMessage::Retract {
                    record,
                    orphaned_block,
                    deleted: true,
                    ..
                } => {
                    if self.finalized_blocks.contains(&orphaned_block.hash) {
                        return Err(format!(
                            "retracted a record from finalized block #{}",
                            orphaned_block.number
                        ));
                    }
                    match self.live.remove(&record.id) {
                        Some(r) if r == *record => {}
                        Some(_) => {
                            return Err(format!(
                                "retraction of {} does not match emitted record",
                                record.id
                            ));
                        }
                        None => {
                            return Err(format!("retraction of {} which is not live", record.id));
                        }
                    }
                }
                StreamMessage::Upsert { .. } | StreamMessage::Retract { .. } => {
                    return Err("upsert/retract with wrong deleted flag".into());
                }
                StreamMessage::BlockFinalized { block, .. } => {
                    self.finalized_blocks.insert(block.hash);
                }
                StreamMessage::Reorg { depth, .. } => self.reorgs.push(*depth),
                StreamMessage::IntegrityHalt { reason, .. } => self.halts.push(reason.clone()),
                StreamMessage::BlockAdopted { .. } | StreamMessage::BlockOrphaned { .. } => {}
            }
        }
        Ok(())
    }

    pub fn live_ids(&self) -> BTreeSet<B256> {
        self.live.keys().copied().collect()
    }
}

/// Materializes records exactly like ClickHouse `ReplacingMergeTree(seq, is_deleted)`:
/// per record id, the row with the highest `seq` wins. Order-insensitive and
/// idempotent, so it models at-least-once redelivery.
#[derive(Default, Debug)]
pub struct ReplacingTable {
    rows: BTreeMap<B256, (u64, bool)>,
}

impl ReplacingTable {
    pub fn apply(&mut self, msgs: &[StreamMessage]) {
        for m in msgs {
            let (seq, id, deleted) = match m {
                StreamMessage::Upsert {
                    seq,
                    record,
                    deleted,
                    ..
                }
                | StreamMessage::Retract {
                    seq,
                    record,
                    deleted,
                    ..
                } => (*seq, record.id, *deleted),
                _ => continue,
            };
            let row = self.rows.entry(id).or_insert((0, true));
            if seq > row.0 {
                *row = (seq, deleted);
            }
        }
    }

    /// Equivalent of `SELECT id FROM records FINAL`.
    pub fn live_ids(&self) -> BTreeSet<B256> {
        self.rows
            .iter()
            .filter(|(_, (_, deleted))| !deleted)
            .map(|(id, _)| *id)
            .collect()
    }
}
