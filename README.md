# ChainGuard

Real-time on-chain risk and threat monitoring. ChainGuard watches blockchains live, detects attacks and risk as they happen, and emits alerts, a live dashboard and a risk-score API.

**Read-only by design.** ChainGuard never holds a key, never signs, never sends a transaction. It is a watchtower, not a trader.

> **Status: milestone 2 of 4.** Reorg-safe multi-node ingestion (Rust), the detection engine with 5 rules and alerting (Elixir), and a live dashboard (Angular) are built and tested. The risk-score API, tamper-evident audit trail, landing page and one-command self-host come in milestones 3–4. Nothing below claims more than what is in this repository.

## What works today

**Ingestion** (`crates/`, Rust)
- **Multi-node verification.** Every head, header and full per-block log set must be returned *identically* by a strict majority of independent RPC nodes (≥ 2). Lagging, forked, lying or log-dropping nodes are outvoted.
- **Reorg safety.** Records are emitted immediately as *provisional*; on a reorg, records from orphaned blocks are retracted and canonical ones re-emitted. A fork below finality halts ingestion loudly instead of rewriting history.
- **Decoding and enrichment.** ERC-20/721, approvals, Aave V2/V3 and Balancer flash loans, Uniswap-style swaps, ownership/proxy/role/pause changes, Chainlink updates. Public labels, token metadata, and USD value where a price is known (never guessed).

**Detection** (`apps/engine`, Elixir/Phoenix/Broadway)
- **Rules are YAML data**, validated at load, each in its own supervised process. Format: [docs/rules.md](docs/rules.md). Bundled rules:

  | Rule | Severity | Catches |
  |---|---|---|
  | `flash-loan-drain` | critical | flash-loan tx where a labeled protocol ends with a large *net* USD outflow |
  | `privileged-change` | high | proxy upgrade, admin change, ownership transfer or role grant on a known protocol |
  | `emergency-pause` | high | a known protocol emits `Paused` |
  | `approval-farming` | medium | ≥ 8 wallets give unlimited approval to the same new, unknown spender within 50 blocks |
  | `mixer-interaction` | low | funds move into or out of a labeled mixer |

- **Alerts** carry severity, weakness class and exact evidence (tx, log index, block hash, attesting nodes). High and critical are **capped at medium unless ≥ 2 nodes attested**. Duplicates merge, every rule is rate-limited, and alerts are **retracted when a reorg orphans their evidence** (PagerDuty resolves, webhooks get `alert.retracted`).
- **Connectors:** HMAC-signed webhooks, PagerDuty Events v2, Telegram.

**Dashboard** (`apps/dashboard`, Angular): live alert timeline with evidence, a per-block stream with notable flows, records-per-block chart (with table view), and latency tiles that show *n/a* rather than a wrong number.

Design: [ADR-0001 ingestion](docs/adr/0001-reorg-safe-multi-node-ingestion.md) · [ADR-0002 detection & alerts](docs/adr/0002-detection-engine-and-alert-lifecycle.md).

## Run it locally

Requires Rust ≥ 1.88, Erlang/OTP 29 + Elixir 1.20, Node 24.

```sh
# 1. Ingest Ethereum mainnet via two independent public RPCs → JSONL
cp config/ingestd.example.toml config/ingestd.toml     # set sink.path = "var/stream.jsonl"
cargo run --release -p chainguard-ingestd -- -c config/ingestd.toml

# 2. Detection engine, following that file (http://localhost:4000/api/health)
cd apps/engine && mix deps.get
CHAINGUARD_SOURCE=jsonl CHAINGUARD_JSONL_PATH=../../var/stream.jsonl mix phx.server

# 3. Dashboard (http://localhost:4300)
cd apps/dashboard && npm ci && npx ng serve
```

Replay a real incident instead of live data:

```sh
CHAINGUARD_SOURCE=jsonl CHAINGUARD_JSONL_MODE=replay \
CHAINGUARD_JSONL_PATH=test/fixtures/incidents/euler-finance-2023-03-13.jsonl mix phx.server
```

Alert destinations are configured through environment variables: `CHAINGUARD_WEBHOOK_URL` + `CHAINGUARD_WEBHOOK_SECRET`, `CHAINGUARD_PAGERDUTY_ROUTING_KEY`, `CHAINGUARD_TELEGRAM_BOT_TOKEN` + `CHAINGUARD_TELEGRAM_CHAT_ID`. Each has a `…_MIN_SEVERITY`. With `CHAINGUARD_SOURCE=kafka` the engine consumes Redpanda (`CHAINGUARD_KAFKA_HOSTS`, `…_TOPICS`).

## Tests

```sh
cargo test --workspace                     # 45 Rust tests (+1 Anvil test that runs in CI)
(cd apps/engine && mix test)               # 43 Elixir tests
(cd apps/dashboard && npx ng test --watch=false)   # 7 dashboard tests
scripts/check-invariants.sh                # what CI uses to block merges
```

**Historical incident replay.** `apps/engine/test/fixtures/incidents/euler-finance-2023-03-13.jsonl` is mainnet block 16,817,996, captured by `ingestd` from two independent providers. Replayed through the Broadway pipeline it raises exactly one critical `flash-loan-drain` alert: Euler's net outflow of **$8,904,507** in tx `0xc310…111d`, matching published post-mortems (~8.87M DAI). It raises nothing else high or critical from the block's other 354 records. A block of ordinary 2026 mainnet traffic (827 records) raises nothing high or critical.

CI fails if read-only enforcement, multi-node verification, reorg handling, or the alert-layer guards (single-source cap, retraction, dedup, rate limit) are removed. The guard itself was mutation-tested.

## Measured so far

| What | Result | Conditions |
|---|---|---|
| Live ingestion | 31 consecutive mainnet blocks in the longest run (plus runs of 12 and 4), 146–2,486 logs each, every one attested by 2 independent providers, 0 errors | `publicnode` + `drpc`, 2026-11-10 |
| Pipeline latency (record derived → rules evaluated) | p50 ≈ 530–600 ms, p95 ≈ 670 ms | One Windows dev machine, JSONL tail (250 ms poll), 8–12 live blocks. Not a benchmark |
| Rule evaluation | p50 ≈ 120 ms per block of ~1,700 records | Same run, 5 rules |
| Block timestamp → detection | **not measured** | The dev machine's clock was ~117 s behind; ChainGuard detected the skew and withheld the figure |

## Roadmap

1. ~~Reorg-safe multi-node ingestion~~ ✓
2. ~~Rule engine (5 rules), Broadway consumer, alert connectors, live dashboard over Phoenix Channels~~ ✓
3. Invariant monitors per protocol, Python ML anomaly service, fund-flow graph
4. Risk-score API, tamper-evident audit trail, landing page, one-command self-host with live demo

## Invariants

These hold in every change; CI fails if the code enforcing 1–3 and 5 is removed:

1. Read-only: no keys, no signing, no transactions.
2. Never trust a single node.
3. Reorg-safe: provisional until final; retract and re-emit on reorg.
4. Tamper-evident audit trail for every alert and score *(milestone 4)*.
5. No false urgency: dedup, rate-limit, evidence on every alert.
6. Tenant isolation of watchlists, labels and routing *(milestone 4: the socket is public-data-only until then)*.
7. No market-manipulation surface.

## License

MIT
