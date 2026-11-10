# Invariant monitors

An invariant is a property of a protocol that must always hold: a stablecoin trades at its peg, an oracle is fresh and does not jump, a lending market does not bleed out. Rules describe *attacks*; invariants describe *health*, so they also catch failures nobody has written a rule for.

Invariants are YAML files in `apps/engine/priv/invariants/`, validated at startup like rules (unknown fields and bad values are rejected with the file name). **Each invariant runs in its own supervised process.** A monitor that crashes restarts alone with fresh state, and the others keep running.

## Kinds

### `peg`: a stablecoin stays within bands around its peg

```yaml
id: usdc-peg
kind: peg
name: USDC holds its $1 peg
protocol: circle
weakness: { class: stablecoin-depeg }
feed:
  name: USDC/USD
  decimals: 8
  aggregators:                 # Chainlink aggregators rotate behind the proxy: list current and past
    - "0x54bCC589d9743E521c64233706FC8cB36D275b07"
    - "0x789190466E21a8b78b8027866CBBDc151542A26C"
peg_usd: 1.0
bands:
  - { deviation: 0.02, severity: high }      # 2% off peg
  - { deviation: 0.05, severity: critical }  # 5% off peg
```

Reads Chainlink `AnswerUpdated` events from the listed aggregators. An alert fires when the price enters a **wider band than it was in before** (in band → 2% → 5%), so a depeg that lasts hours raises one high and, if it deepens, one critical. It does not raise one alert per oracle update. After the price recovers into the band, the next breach re-arms, and the alert manager merges it into the open alert within the dedup window.

### `oracle`: an oracle is fresh and does not jump

```yaml
id: eth-usd-oracle
kind: oracle
feed: { name: ETH/USD, decimals: 8, aggregators: ["0x7d4E742018fb52E48b08BE73d041C18B21de6Fb5"] }
max_jump: 0.10          # one update moving the answer more than 10%
jump_severity: high
max_age_seconds: 5400   # heartbeat 1 h + margin
stale_severity: medium
```

Staleness is judged at **block time** (the chain's clock, not the server's), and fires once until the next update. The evidence is the last update actually seen.

### `outflow`: a protocol's net outflow stays below a limit

```yaml
id: euler-outflow
kind: outflow
protocol: euler            # every address labeled with this protocol (roles from/to)
within_blocks: 50
max_net_outflow_usd: 5000000
severity: critical
reference_tvl_usd: 200000000   # optional: adds "x% of reference TVL" to the title
```

Net USD leaving the protocol's labeled contracts over the last `within_blocks` blocks, from priced transfers. Transfers between two of the protocol's own contracts cancel out. It fires once, and re-arms only after the window falls below half the limit (hysteresis), so a slow drain does not page every block.

**What it does not see:** it is a drawdown proxy, not a balance read. Unpriced tokens do not count. A token is priced by its label (stablecoins) or by a configured Chainlink feed after the feed's first update. Contracts missing from the label set do not count either. Limits are per deployment: Aave sees $10M+ withdrawals in normal operation, Euler in 2023 did not.

## Reorgs

The monitor snapshots its state before every block, keyed by block hash. When a block is orphaned, it restores the snapshot taken before that block and drops the later ones (they were built on it). Alerts raised on the orphaned block are retracted by the alert manager like any other. Checks are written as if the chain never reorgs; the monitor makes that true.

## Alerts

Invariant alerts carry `lane: "invariant"` and go through the same gate as rules. High and critical need evidence attested by at least two independent nodes; otherwise they are capped at medium. They are also deduplicated and rate-limited (defaults: 6 h dedup, 2 per minute).

## Status

`GET /api/invariants` and the `invariants` event on `live:<chain>` report each monitor as `ok`, `breached` or `warming_up` (no data for that feed or protocol yet), with its current value and limit. The dashboard's Invariants panel shows the same.

## Regression tests

`apps/engine/test/chain_guard/invariants_test.exs` replays the **USDC depeg of 11 March 2023**. It covers two mainnet blocks captured from two independent providers:

- Block 16,802,107 (Chainlink round 870, $0.98214): stays quiet, inside the 2% band.
- Block 16,802,135 (round 871, $0.97652): raises exactly one high alert, `USDC/USD at $0.9765: 2.35% off its $1.0000 peg (band 2.00%)`.

The Euler Finance replay (block 16,817,996) raises `euler-outflow` (critical) on the same transaction as the `flash-loan-drain` rule: two lanes, one verdict.
