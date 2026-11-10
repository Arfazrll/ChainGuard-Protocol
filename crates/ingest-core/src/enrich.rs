//! Enrichment: public address labels, token metadata and USD pricing.
//!
//! Only *public* labels live here (protocols, bridges, mixers, exchanges).
//! Customer-confidential labels and watchlists are tenant-scoped and are
//! applied downstream in the detection layer, never in shared ingestion
//! (invariant 6).

use crate::decode::DecodedEvent;
use alloy_primitives::{Address, U256};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::RwLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntityCategory {
    Token,
    Stablecoin,
    Dex,
    Lending,
    Bridge,
    Mixer,
    Exchange,
    Oracle,
    Protocol,
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenMeta {
    pub symbol: String,
    pub decimals: u8,
}

/// One entry of a label file.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LabelEntry {
    /// EIP-55 checksummed. Loading rejects bad checksums, which catches typos.
    pub address: String,
    pub name: String,
    pub category: EntityCategory,
    #[serde(default)]
    pub protocol: Option<String>,
    #[serde(default)]
    pub token: Option<TokenMeta>,
    /// Stablecoins only: the asset is assumed to trade at this USD peg.
    #[serde(default)]
    pub usd_peg: Option<f64>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LabelFile {
    pub chain_id: u64,
    #[serde(default)]
    pub notes: Option<String>,
    pub entries: Vec<LabelEntry>,
}

#[derive(Debug, thiserror::Error)]
pub enum LabelError {
    #[error("label file is for chain {file} but ingestion is configured for chain {expected}")]
    WrongChain { file: u64, expected: u64 },
    #[error("invalid or non-checksummed address {address:?} ({name}): {reason}")]
    BadAddress {
        address: String,
        name: String,
        reason: String,
    },
    #[error("duplicate label for {0}")]
    Duplicate(Address),
    #[error("parse error: {0}")]
    Parse(#[from] serde_json::Error),
}

/// An address label as attached to a record, with the role the address plays.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoleLabel {
    pub role: String,
    pub address: Address,
    pub name: String,
    pub category: EntityCategory,
    pub protocol: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenRef {
    pub address: Address,
    pub symbol: String,
    pub decimals: u8,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PriceQuote {
    pub usd: f64,
    /// Where the price came from, e.g. `"peg_assumption"` or `"oracle:<feed>"`.
    pub source: String,
    /// Block number the quote was observed at (oracle prices), if known.
    pub as_of_block: Option<u64>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Enrichment {
    pub labels: Vec<RoleLabel>,
    pub token: Option<TokenRef>,
    pub price: Option<PriceQuote>,
    /// `amount / 10^decimals * price`. `None` if any input is unknown; never guessed.
    pub value_usd: Option<f64>,
    /// The labeled protocol this event most directly touches, if any.
    pub protocol: Option<String>,
}

#[derive(Clone, Debug)]
struct Known {
    name: String,
    category: EntityCategory,
    protocol: Option<String>,
    token: Option<TokenMeta>,
    usd_peg: Option<f64>,
}

/// A configured price feed: an on-chain oracle aggregator whose
/// `AnswerUpdated` events price `token`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OracleFeed {
    pub aggregator: Address,
    pub token: Address,
    pub answer_decimals: u8,
}

/// Prices learned from oracle events seen in the stream.
///
/// This is "price at block time" in the honest sense: the latest oracle
/// answer observed at or before the block being enriched. The quote carries
/// the block it was observed at so consumers can judge staleness.
#[derive(Default)]
struct OracleBook {
    feeds: HashMap<Address, OracleFeed>,
    latest: RwLock<HashMap<Address, PriceQuote>>,
}

/// Enriches decoded events with labels, token metadata and USD value.
pub struct Enricher {
    chain_id: u64,
    known: HashMap<Address, Known>,
    oracle: OracleBook,
}

impl Enricher {
    pub fn empty(chain_id: u64) -> Self {
        Self {
            chain_id,
            known: HashMap::new(),
            oracle: OracleBook::default(),
        }
    }

    pub fn from_json(json: &str, expected_chain: u64) -> Result<Self, LabelError> {
        let file: LabelFile = serde_json::from_str(json)?;
        Self::from_file(file, expected_chain)
    }

    pub fn from_file(file: LabelFile, expected_chain: u64) -> Result<Self, LabelError> {
        if file.chain_id != expected_chain {
            return Err(LabelError::WrongChain {
                file: file.chain_id,
                expected: expected_chain,
            });
        }
        let mut me = Self::empty(expected_chain);
        for e in file.entries {
            let addr = Address::parse_checksummed(&e.address, None).map_err(|err| {
                LabelError::BadAddress {
                    address: e.address.clone(),
                    name: e.name.clone(),
                    reason: err.to_string(),
                }
            })?;
            let k = Known {
                name: e.name,
                category: e.category,
                protocol: e.protocol,
                token: e.token,
                usd_peg: e.usd_peg,
            };
            if me.known.insert(addr, k).is_some() {
                return Err(LabelError::Duplicate(addr));
            }
        }
        Ok(me)
    }

    pub fn with_oracle_feeds(mut self, feeds: impl IntoIterator<Item = OracleFeed>) -> Self {
        for f in feeds {
            self.oracle.feeds.insert(f.aggregator, f);
        }
        self
    }

    pub fn chain_id(&self) -> u64 {
        self.chain_id
    }

    pub fn label_count(&self) -> usize {
        self.known.len()
    }

    fn label(&self, role: &str, address: Address) -> Option<RoleLabel> {
        self.known.get(&address).map(|k| RoleLabel {
            role: role.to_owned(),
            address,
            name: k.name.clone(),
            category: k.category,
            protocol: k.protocol.clone(),
        })
    }

    fn token(&self, address: Address) -> Option<TokenRef> {
        let k = self.known.get(&address)?;
        let t = k.token.as_ref()?;
        Some(TokenRef {
            address,
            symbol: t.symbol.clone(),
            decimals: t.decimals,
        })
    }

    fn price(&self, token: Address) -> Option<PriceQuote> {
        if let Some(q) = self.oracle.latest.read().ok()?.get(&token) {
            return Some(q.clone());
        }
        let peg = self.known.get(&token)?.usd_peg?;
        Some(PriceQuote {
            usd: peg,
            source: "peg_assumption".into(),
            as_of_block: None,
        })
    }

    /// Feed an event through the oracle book. Must be called in block order.
    pub fn observe(&self, contract: Address, block_number: u64, event: &DecodedEvent) {
        let DecodedEvent::OracleAnswerUpdated { answer, .. } = event else {
            return;
        };
        let Some(feed) = self.oracle.feeds.get(&contract) else {
            return;
        };
        if answer.is_negative() {
            return;
        }
        let Some(usd) = scaled(answer.into_raw(), feed.answer_decimals) else {
            return;
        };
        if let Ok(mut latest) = self.oracle.latest.write() {
            latest.insert(
                feed.token,
                PriceQuote {
                    usd,
                    source: format!("oracle:{contract}"),
                    as_of_block: Some(block_number),
                },
            );
        }
    }

    pub fn enrich(&self, contract: Address, event: &DecodedEvent) -> Enrichment {
        let mut out = Enrichment::default();
        let mut labels = Vec::new();
        let mut push = |role: &str, a: Address| {
            if let Some(l) = self.label(role, a) {
                labels.push(l);
            }
        };
        push("contract", contract);

        // (token, raw amount) whose USD value we can compute.
        let mut valued: Option<(Address, U256)> = None;
        match event {
            DecodedEvent::Erc20Transfer { from, to, amount } => {
                push("from", *from);
                push("to", *to);
                valued = Some((contract, *amount));
            }
            DecodedEvent::Erc721Transfer { from, to, .. } => {
                push("from", *from);
                push("to", *to);
            }
            DecodedEvent::Approval { owner, spender, .. } => {
                push("owner", *owner);
                push("spender", *spender);
                // An approval moves nothing; we label the token but never value it.
                out.token = self.token(contract);
            }
            DecodedEvent::FlashLoan {
                receiver,
                initiator,
                asset,
                amount,
                ..
            } => {
                push("receiver", *receiver);
                if let Some(i) = initiator {
                    push("initiator", *i);
                }
                valued = Some((*asset, *amount));
            }
            DecodedEvent::Swap {
                sender, recipient, ..
            } => {
                push("sender", *sender);
                push("recipient", *recipient);
            }
            DecodedEvent::OwnershipTransferred {
                previous_owner,
                new_owner,
            } => {
                push("previous_owner", *previous_owner);
                push("new_owner", *new_owner);
            }
            DecodedEvent::ProxyUpgraded { implementation } => {
                push("implementation", *implementation)
            }
            DecodedEvent::ProxyAdminChanged {
                previous_admin,
                new_admin,
            } => {
                push("previous_admin", *previous_admin);
                push("new_admin", *new_admin);
            }
            DecodedEvent::RoleGranted {
                account, sender, ..
            } => {
                push("account", *account);
                push("sender", *sender);
            }
            DecodedEvent::Paused { account } | DecodedEvent::Unpaused { account } => {
                push("account", *account)
            }
            DecodedEvent::OracleAnswerUpdated { .. }
            | DecodedEvent::Undecodable { .. }
            | DecodedEvent::Unknown { .. } => {}
        }

        out.labels = labels;
        if let Some((token, amount)) = valued {
            out.token = self.token(token);
            out.price = self.price(token);
            if let (Some(t), Some(p)) = (&out.token, &out.price) {
                out.value_usd = scaled(amount, t.decimals).map(|units| units * p.usd);
            }
        }
        out.protocol = out.labels.iter().find_map(|l| l.protocol.clone());
        out
    }
}

/// `raw / 10^decimals` as f64. Precision loss is acceptable for display/scoring
/// values; the exact integer amount always travels alongside.
fn scaled(raw: U256, decimals: u8) -> Option<f64> {
    let v: f64 = raw.to_string().parse().ok()?;
    Some(v / 10f64.powi(decimals as i32))
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::{I256, address};

    const SEED: &str = include_str!("../../../data/labels/ethereum-mainnet.json");

    #[test]
    fn seed_label_file_is_valid_and_checksummed() {
        let e = Enricher::from_json(SEED, 1).expect("seed label file must load");
        assert!(
            e.label_count() >= 20,
            "seed list unexpectedly small: {}",
            e.label_count()
        );
    }

    #[test]
    fn rejects_bad_checksum_and_wrong_chain() {
        let bad = r#"{"chain_id":1,"entries":[{"address":"0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb4","name":"x","category":"token"}]}"#;
        assert!(matches!(
            Enricher::from_json(bad, 1),
            Err(LabelError::BadAddress { .. })
        ));
        let typo = r#"{"chain_id":1,"entries":[{"address":"0xA0B86991c6218b36c1d19D4a2e9Eb0cE3606eB48","name":"x","category":"token"}]}"#;
        assert!(matches!(
            Enricher::from_json(typo, 1),
            Err(LabelError::BadAddress { .. })
        ));
        assert!(matches!(
            Enricher::from_json(SEED, 10),
            Err(LabelError::WrongChain { .. })
        ));
    }

    #[test]
    fn values_stablecoin_transfer_to_a_mixer() {
        let e = Enricher::from_json(SEED, 1).unwrap();
        let usdc = address!("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");
        let tornado = address!("0x910Cbd523D972eb0a6f4cAe4618aD62622b39DbF");
        let ev = DecodedEvent::Erc20Transfer {
            from: Address::repeat_byte(1),
            to: tornado,
            amount: U256::from(2_500_000_000u64), // 2,500 USDC (6 decimals)
        };
        let out = e.enrich(usdc, &ev);
        assert_eq!(out.token.as_ref().unwrap().symbol, "USDC");
        assert_eq!(out.value_usd, Some(2500.0));
        assert_eq!(out.price.as_ref().unwrap().source, "peg_assumption");
        let to = out.labels.iter().find(|l| l.role == "to").unwrap();
        assert_eq!(to.category, EntityCategory::Mixer);
    }

    #[test]
    fn unknown_token_is_never_valued() {
        let e = Enricher::from_json(SEED, 1).unwrap();
        let ev = DecodedEvent::Erc20Transfer {
            from: Address::ZERO,
            to: Address::ZERO,
            amount: U256::from(1u64),
        };
        let out = e.enrich(Address::repeat_byte(0xEE), &ev);
        assert_eq!(out.value_usd, None);
        assert!(out.price.is_none());
    }

    #[test]
    fn oracle_feed_prices_subsequent_transfers() {
        let weth = address!("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
        let feed = Address::repeat_byte(0xFE);
        let e = Enricher::from_json(SEED, 1)
            .unwrap()
            .with_oracle_feeds([OracleFeed {
                aggregator: feed,
                token: weth,
                answer_decimals: 8,
            }]);
        let transfer = DecodedEvent::Erc20Transfer {
            from: Address::ZERO,
            to: Address::ZERO,
            amount: U256::from(2u64) * U256::from(10u64).pow(U256::from(18u64)),
        };
        assert_eq!(
            e.enrich(weth, &transfer).value_usd,
            None,
            "no price before any oracle update"
        );
        e.observe(
            feed,
            100,
            &DecodedEvent::OracleAnswerUpdated {
                answer: I256::try_from(300_000_000_000i64).unwrap(),
                round_id: U256::from(1u64),
                updated_at: 0,
            },
        );
        let out = e.enrich(weth, &transfer);
        assert_eq!(out.value_usd, Some(6000.0));
        assert_eq!(out.price.unwrap().as_of_block, Some(100));
    }
}
