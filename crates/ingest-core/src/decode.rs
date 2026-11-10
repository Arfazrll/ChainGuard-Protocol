//! ABI decoding of raw logs into typed events.
//!
//! The set of decoded events is chosen for what the detection lanes need:
//! value movement (transfers, approvals, flash loans, swaps), privileged
//! actions (ownership, proxy upgrades, roles, pausing) and oracle updates.
//! Anything else is passed through as [`DecodedEvent::Unknown`] so no data is
//! ever dropped on the floor; raw topics and data travel with every record.

use crate::serde_num::{dec_i256, dec_u256};
use crate::types::RawLog;
use alloy_primitives::{Address, B256, I256, U256};
use alloy_sol_types::SolEvent;
use serde::{Deserialize, Serialize};

#[allow(missing_docs)]
mod abi {
    use alloy_sol_types::sol;

    sol! {
        event Transfer(address indexed from, address indexed to, uint256 value);
        event Approval(address indexed owner, address indexed spender, uint256 value);
        event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
        // EIP-1967 proxy events.
        event Upgraded(address indexed implementation);
        event AdminChanged(address previousAdmin, address newAdmin);
        // OpenZeppelin AccessControl / Pausable.
        event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
        event Paused(address account);
        event Unpaused(address account);
        // Chainlink aggregator.
        event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    }

    pub mod erc721 {
        alloy_sol_types::sol! {
            event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
        }
    }

    pub mod aave_v2 {
        alloy_sol_types::sol! {
            event FlashLoan(
                address indexed target,
                address indexed initiator,
                address indexed asset,
                uint256 amount,
                uint256 premium,
                uint16 referralCode
            );
        }
    }

    pub mod aave_v3 {
        alloy_sol_types::sol! {
            // `interestRateMode` is the DataTypes.InterestRateMode enum, ABI-encoded as uint8.
            event FlashLoan(
                address indexed target,
                address initiator,
                address indexed asset,
                uint256 amount,
                uint8 interestRateMode,
                uint256 premium,
                uint16 indexed referralCode
            );
        }
    }

    pub mod balancer_v2 {
        alloy_sol_types::sol! {
            event FlashLoan(address indexed recipient, address indexed token, uint256 amount, uint256 feeAmount);
        }
    }

    pub mod uniswap_v2 {
        alloy_sol_types::sol! {
            event Swap(
                address indexed sender,
                uint256 amount0In,
                uint256 amount1In,
                uint256 amount0Out,
                uint256 amount1Out,
                address indexed to
            );
        }
    }

    pub mod uniswap_v3 {
        alloy_sol_types::sol! {
            event Swap(
                address indexed sender,
                address indexed recipient,
                int256 amount0,
                int256 amount1,
                uint160 sqrtPriceX96,
                uint128 liquidity,
                int24 tick
            );
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FlashLoanProvider {
    AaveV2,
    AaveV3,
    BalancerV2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DexVenue {
    UniswapV2Like,
    UniswapV3Like,
}

/// A decoded on-chain event.
///
/// Amounts are serialized as decimal strings so 256-bit values survive JSON
/// and ClickHouse (`UInt256`/`Int256`) without loss.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DecodedEvent {
    Erc20Transfer {
        from: Address,
        to: Address,
        #[serde(with = "dec_u256")]
        amount: U256,
    },
    Erc721Transfer {
        from: Address,
        to: Address,
        #[serde(with = "dec_u256")]
        token_id: U256,
    },
    Approval {
        owner: Address,
        spender: Address,
        #[serde(with = "dec_u256")]
        amount: U256,
    },
    FlashLoan {
        provider: FlashLoanProvider,
        receiver: Address,
        /// Only Aave reports the initiator separately from the receiver.
        initiator: Option<Address>,
        asset: Address,
        #[serde(with = "dec_u256")]
        amount: U256,
        #[serde(with = "dec_u256")]
        fee: U256,
    },
    /// Normalized to pool-side signed deltas: positive means tokens flowed
    /// *into* the pool, negative means *out of* it (Uniswap V3 convention).
    Swap {
        venue: DexVenue,
        sender: Address,
        recipient: Address,
        #[serde(with = "dec_i256")]
        amount0: I256,
        #[serde(with = "dec_i256")]
        amount1: I256,
    },
    OwnershipTransferred {
        previous_owner: Address,
        new_owner: Address,
    },
    ProxyUpgraded {
        implementation: Address,
    },
    ProxyAdminChanged {
        previous_admin: Address,
        new_admin: Address,
    },
    RoleGranted {
        role: B256,
        account: Address,
        sender: Address,
    },
    Paused {
        account: Address,
    },
    Unpaused {
        account: Address,
    },
    OracleAnswerUpdated {
        #[serde(with = "dec_i256")]
        answer: I256,
        #[serde(with = "dec_u256")]
        round_id: U256,
        updated_at: u64,
    },
    /// topic0 matched a known signature but the payload did not decode
    /// (e.g. a non-standard token that does not index its Transfer fields).
    Undecodable {
        topic0: B256,
        reason: String,
    },
    Unknown {
        topic0: Option<B256>,
    },
}

impl DecodedEvent {
    /// Short machine name, e.g. `"erc20_transfer"`; mirrors the serde tag.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Erc20Transfer { .. } => "erc20_transfer",
            Self::Erc721Transfer { .. } => "erc721_transfer",
            Self::Approval { .. } => "approval",
            Self::FlashLoan { .. } => "flash_loan",
            Self::Swap { .. } => "swap",
            Self::OwnershipTransferred { .. } => "ownership_transferred",
            Self::ProxyUpgraded { .. } => "proxy_upgraded",
            Self::ProxyAdminChanged { .. } => "proxy_admin_changed",
            Self::RoleGranted { .. } => "role_granted",
            Self::Paused { .. } => "paused",
            Self::Unpaused { .. } => "unpaused",
            Self::OracleAnswerUpdated { .. } => "oracle_answer_updated",
            Self::Undecodable { .. } => "undecodable",
            Self::Unknown { .. } => "unknown",
        }
    }
}

fn decode_as<E: SolEvent>(log: &RawLog) -> Result<E, String> {
    E::decode_raw_log_validate(log.topics.iter().copied(), &log.data).map_err(|e| e.to_string())
}

/// Wrap a signed conversion that cannot overflow for in-range ABI values.
fn signed(v: U256) -> Option<I256> {
    I256::try_from(v).ok()
}

/// Decode one raw log. Never fails: unknown or malformed logs are preserved
/// as [`DecodedEvent::Unknown`] / [`DecodedEvent::Undecodable`].
pub fn decode_log(log: &RawLog) -> DecodedEvent {
    let Some(&topic0) = log.topics.first() else {
        return DecodedEvent::Unknown { topic0: None };
    };
    let undecodable = |reason: String| DecodedEvent::Undecodable { topic0, reason };

    let res: Result<DecodedEvent, String> = match topic0 {
        // ERC-20 and ERC-721 share the Transfer signature; ERC-721 indexes tokenId.
        t if t == abi::Transfer::SIGNATURE_HASH && log.topics.len() == 4 => {
            decode_as::<abi::erc721::Transfer>(log).map(|e| DecodedEvent::Erc721Transfer {
                from: e.from,
                to: e.to,
                token_id: e.tokenId,
            })
        }
        t if t == abi::Transfer::SIGNATURE_HASH => {
            decode_as::<abi::Transfer>(log).map(|e| DecodedEvent::Erc20Transfer {
                from: e.from,
                to: e.to,
                amount: e.value,
            })
        }
        t if t == abi::Approval::SIGNATURE_HASH && log.topics.len() == 3 => {
            decode_as::<abi::Approval>(log).map(|e| DecodedEvent::Approval {
                owner: e.owner,
                spender: e.spender,
                amount: e.value,
            })
        }
        t if t == abi::aave_v2::FlashLoan::SIGNATURE_HASH => {
            decode_as::<abi::aave_v2::FlashLoan>(log).map(|e| DecodedEvent::FlashLoan {
                provider: FlashLoanProvider::AaveV2,
                receiver: e.target,
                initiator: Some(e.initiator),
                asset: e.asset,
                amount: e.amount,
                fee: e.premium,
            })
        }
        t if t == abi::aave_v3::FlashLoan::SIGNATURE_HASH => {
            decode_as::<abi::aave_v3::FlashLoan>(log).map(|e| DecodedEvent::FlashLoan {
                provider: FlashLoanProvider::AaveV3,
                receiver: e.target,
                initiator: Some(e.initiator),
                asset: e.asset,
                amount: e.amount,
                fee: e.premium,
            })
        }
        t if t == abi::balancer_v2::FlashLoan::SIGNATURE_HASH => {
            decode_as::<abi::balancer_v2::FlashLoan>(log).map(|e| DecodedEvent::FlashLoan {
                provider: FlashLoanProvider::BalancerV2,
                receiver: e.recipient,
                initiator: None,
                asset: e.token,
                amount: e.amount,
                fee: e.feeAmount,
            })
        }
        t if t == abi::uniswap_v2::Swap::SIGNATURE_HASH => decode_as::<abi::uniswap_v2::Swap>(log)
            .and_then(|e| {
                let net = |inn: U256, out: U256| -> Option<I256> {
                    signed(inn)?.checked_sub(signed(out)?)
                };
                let amount0 = net(e.amount0In, e.amount0Out).ok_or("amount0 overflow")?;
                let amount1 = net(e.amount1In, e.amount1Out).ok_or("amount1 overflow")?;
                Ok(DecodedEvent::Swap {
                    venue: DexVenue::UniswapV2Like,
                    sender: e.sender,
                    recipient: e.to,
                    amount0,
                    amount1,
                })
            }),
        t if t == abi::uniswap_v3::Swap::SIGNATURE_HASH => decode_as::<abi::uniswap_v3::Swap>(log)
            .map(|e| DecodedEvent::Swap {
                venue: DexVenue::UniswapV3Like,
                sender: e.sender,
                recipient: e.recipient,
                amount0: e.amount0,
                amount1: e.amount1,
            }),
        t if t == abi::OwnershipTransferred::SIGNATURE_HASH => {
            decode_as::<abi::OwnershipTransferred>(log).map(|e| {
                DecodedEvent::OwnershipTransferred {
                    previous_owner: e.previousOwner,
                    new_owner: e.newOwner,
                }
            })
        }
        t if t == abi::Upgraded::SIGNATURE_HASH => {
            decode_as::<abi::Upgraded>(log).map(|e| DecodedEvent::ProxyUpgraded {
                implementation: e.implementation,
            })
        }
        t if t == abi::AdminChanged::SIGNATURE_HASH => {
            decode_as::<abi::AdminChanged>(log).map(|e| DecodedEvent::ProxyAdminChanged {
                previous_admin: e.previousAdmin,
                new_admin: e.newAdmin,
            })
        }
        t if t == abi::RoleGranted::SIGNATURE_HASH => {
            decode_as::<abi::RoleGranted>(log).map(|e| DecodedEvent::RoleGranted {
                role: e.role,
                account: e.account,
                sender: e.sender,
            })
        }
        t if t == abi::Paused::SIGNATURE_HASH => {
            decode_as::<abi::Paused>(log).map(|e| DecodedEvent::Paused { account: e.account })
        }
        t if t == abi::Unpaused::SIGNATURE_HASH => {
            decode_as::<abi::Unpaused>(log).map(|e| DecodedEvent::Unpaused { account: e.account })
        }
        t if t == abi::AnswerUpdated::SIGNATURE_HASH => decode_as::<abi::AnswerUpdated>(log)
            .and_then(|e| {
                Ok(DecodedEvent::OracleAnswerUpdated {
                    answer: e.current,
                    round_id: e.roundId,
                    updated_at: u64::try_from(e.updatedAt).map_err(|_| "updatedAt overflow")?,
                })
            }),
        _ => {
            return DecodedEvent::Unknown {
                topic0: Some(topic0),
            };
        }
    };

    res.unwrap_or_else(undecodable)
}

/// Helpers for building logs in tests (and in the testkit).
pub mod encode {
    use super::abi;
    use alloy_primitives::{Address, B256, Bytes, U256};
    use alloy_sol_types::SolEvent;

    /// Encode an ERC-20 `Transfer` as (topics, data).
    pub fn erc20_transfer(from: Address, to: Address, value: U256) -> (Vec<B256>, Bytes) {
        let ev = abi::Transfer { from, to, value };
        let data = ev.encode_log_data();
        (data.topics().to_vec(), data.data)
    }

    /// Encode a Balancer V2 `FlashLoan` as (topics, data).
    pub fn balancer_flash_loan(
        recipient: Address,
        token: Address,
        amount: U256,
        fee: U256,
    ) -> (Vec<B256>, Bytes) {
        let ev = abi::balancer_v2::FlashLoan {
            recipient,
            token,
            amount,
            feeAmount: fee,
        };
        let data = ev.encode_log_data();
        (data.topics().to_vec(), data.data)
    }

    /// Encode an EIP-1967 `Upgraded` as (topics, data).
    pub fn proxy_upgraded(implementation: Address) -> (Vec<B256>, Bytes) {
        let data = abi::Upgraded { implementation }.encode_log_data();
        (data.topics().to_vec(), data.data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::{address, b256, hex};

    fn raw(topics: Vec<B256>, data: Vec<u8>) -> RawLog {
        RawLog {
            address: address!("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"),
            topics,
            data: data.into(),
            block_hash: B256::ZERO,
            block_number: 1,
            tx_hash: B256::ZERO,
            tx_index: 0,
            log_index: 0,
        }
    }

    #[test]
    fn well_known_signature_hashes() {
        // keccak256("Transfer(address,address,uint256)") — the canonical ERC-20 topic.
        assert_eq!(
            abi::Transfer::SIGNATURE_HASH,
            b256!("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")
        );
        // keccak256("Approval(address,address,uint256)")
        assert_eq!(
            abi::Approval::SIGNATURE_HASH,
            b256!("0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925")
        );
        // keccak256("Upgraded(address)") — EIP-1967.
        assert_eq!(
            abi::Upgraded::SIGNATURE_HASH,
            b256!("0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b")
        );
        assert_eq!(
            abi::aave_v3::FlashLoan::SIGNATURE,
            "FlashLoan(address,address,address,uint256,uint8,uint256,uint16)"
        );
        assert_eq!(
            abi::balancer_v2::FlashLoan::SIGNATURE,
            "FlashLoan(address,address,uint256,uint256)"
        );
    }

    #[test]
    fn decodes_the_aave_v2_flash_loan_from_the_euler_exploit() {
        // Log 55 of mainnet tx 0xc310a0af…b111d (block 16,817,996): the 30M DAI
        // Aave V2 flash loan that funded the Euler Finance exploit.
        let attacker = address!("0xebc29199c817dc47ba12e3f86102564d640cbf99");
        let dai = address!("0x6b175474e89094c44da98b954eedeac495271d0f");
        let word = |a: Address| B256::left_padding_from(a.as_slice());
        let topics = vec![
            b256!("0x631042c832b07452973831137f2d73e395028b44b250dedc5abb0ee766e168ac"),
            word(attacker),
            word(attacker),
            word(dai),
        ];
        let mut data = vec![0u8; 96];
        data[..32].copy_from_slice(
            &U256::from(30_000_000u64)
                .checked_mul(U256::from(10u64).pow(U256::from(18u64)))
                .unwrap()
                .to_be_bytes::<32>(),
        );
        data[32..64].copy_from_slice(&U256::from(27_000u64).to_be_bytes::<32>());
        match decode_log(&raw(topics, data)) {
            DecodedEvent::FlashLoan {
                provider,
                receiver,
                asset,
                amount,
                ..
            } => {
                assert_eq!(provider, FlashLoanProvider::AaveV2);
                assert_eq!((receiver, asset), (attacker, dai));
                assert_eq!(
                    amount,
                    U256::from(30_000_000u64) * U256::from(10u64).pow(U256::from(18u64))
                );
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn decodes_a_real_usdc_transfer() {
        // Shape of a mainnet USDC Transfer log: 3 topics, amount in data.
        let from = address!("0x28C6c06298d514Db089934071355E5743bf21d60");
        let to = address!("0xdAC17F958D2ee523a2206206994597C13D831ec7");
        let (topics, data) = encode::erc20_transfer(from, to, U256::from(1_500_000_000u64));
        match decode_log(&raw(topics, data.to_vec())) {
            DecodedEvent::Erc20Transfer {
                from: f,
                to: t,
                amount,
            } => {
                assert_eq!((f, t), (from, to));
                assert_eq!(amount, U256::from(1_500_000_000u64));
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn transfer_with_four_topics_is_erc721() {
        let (mut topics, _) =
            encode::erc20_transfer(Address::ZERO, Address::repeat_byte(1), U256::ZERO);
        topics.push(B256::from(U256::from(42u64)));
        match decode_log(&raw(topics, vec![])) {
            DecodedEvent::Erc721Transfer { token_id, .. } => {
                assert_eq!(token_id, U256::from(42u64))
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn malformed_payload_is_preserved_not_dropped() {
        let (topics, _) = encode::erc20_transfer(Address::ZERO, Address::ZERO, U256::ZERO);
        let ev = decode_log(&raw(topics, hex!("deadbeef").to_vec()));
        assert!(matches!(ev, DecodedEvent::Undecodable { .. }), "{ev:?}");
    }

    #[test]
    fn unknown_topic_passes_through() {
        let ev = decode_log(&raw(vec![B256::repeat_byte(7)], vec![]));
        assert_eq!(
            ev,
            DecodedEvent::Unknown {
                topic0: Some(B256::repeat_byte(7))
            }
        );
        assert_eq!(
            decode_log(&raw(vec![], vec![])),
            DecodedEvent::Unknown { topic0: None }
        );
    }

    #[test]
    fn flash_loan_roundtrip() {
        let token = address!("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
        let (topics, data) = encode::balancer_flash_loan(
            Address::repeat_byte(9),
            token,
            U256::from(10u64).pow(U256::from(22u64)),
            U256::ZERO,
        );
        match decode_log(&raw(topics, data.to_vec())) {
            DecodedEvent::FlashLoan {
                provider,
                asset,
                amount,
                ..
            } => {
                assert_eq!(provider, FlashLoanProvider::BalancerV2);
                assert_eq!(asset, token);
                assert_eq!(amount, U256::from(10u64).pow(U256::from(22u64)));
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn amounts_serialize_as_decimal_strings() {
        let ev = DecodedEvent::Erc20Transfer {
            from: Address::ZERO,
            to: Address::ZERO,
            amount: U256::MAX,
        };
        let json = serde_json::to_value(&ev).unwrap();
        assert_eq!(json["kind"], "erc20_transfer");
        assert_eq!(json["amount"], U256::MAX.to_string());
        let back: DecodedEvent = serde_json::from_value(json).unwrap();
        assert_eq!(back, ev);
    }
}
