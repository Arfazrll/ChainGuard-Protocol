# SvlteChain

[![CI](https://github.com/Arfazrll/ChainGuard-Protocol/actions/workflows/ci.yml/badge.svg)](https://github.com/Arfazrll/ChainGuard-Protocol/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Rust](https://img.shields.io/badge/Rust-1.88%2B-b7410e?logo=rust&logoColor=white)
![Elixir](https://img.shields.io/badge/Elixir-1.20%20%2F%20OTP%2029-4b275f?logo=elixir&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.12-3776ab?logo=python&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-4169e1?logo=postgresql&logoColor=white)
![Angular](https://img.shields.io/badge/Angular-22-dd0031?logo=angular&logoColor=white)
![SvelteKit](https://img.shields.io/badge/SvelteKit-3-ff3e00?logo=svelte&logoColor=white)

**Real-time on-chain risk and threat monitoring.** SvlteChain watches a blockchain live and verifies every block across independent nodes. It detects attacks and protocol failures as they happen, in three detection lanes, and raises alerts that carry the exact on-chain evidence behind them. Every alert and risk score is written to a tamper-evident audit chain.

**Read-only by design.** SvlteChain never holds a key, never signs and never sends a transaction. It is a watchtower, not a trader. If it were breached, there would be nothing to steal.

| Milestone | Scope | Status |
|---|---|---|
| 1 | Reorg-safe multi-node ingestion (Rust) | Done |
| 2 | Rule engine, Broadway consumer, alert connectors, live dashboard | Done |
| 3 | Per-protocol invariants, ML anomaly service, fund-flow graph, landing page | Done |
| 4 | Risk-score API, tamper-evident audit trail, tenant isolation, compliance reports, one-command self-host | Done (no hosted demo yet) |

Nothing in this README claims more than what is in the repository. Every figure below comes from a test or a recorded run, with its conditions stated.

## Demo in one command

```sh
scripts/up.sh --replay                                     # native: Rust, Elixir, uv, Node, PostgreSQL
docker compose -f deploy/compose/docker-compose.yml up     # or containers
```

Both replay two real incidents captured from mainnet, the USDC depeg and the Euler Finance exploit, so alerts, risk scores and the audit chain appear within seconds. No RPC endpoint or key is needed. Open the dashboard at http://localhost:4300. Drop `--replay` (or use the Compose `live` profile) to watch Ethereum mainnet instead.

![Dashboard after the incident replay: fund-flow graph with the Euler exploit path in red, alerts from two lanes, protocol risk scores and a verified audit chain](docs/media/dashboard.png)

| Landing page | Compliance report (PDF) |
|---|---|
| ![Landing page](docs/media/landing.png) | ![First page of the compliance report for the Euler alert](docs/media/report.png) |

## Contents

- [Architecture](#architecture)
- [From block to alert](#from-block-to-alert)
- [Detection lanes](#detection-lanes)
- [Risk scores, audit trail and tenants](#risk-scores-audit-trail-and-tenants)
- [Proof on real incidents](#proof-on-real-incidents)
- [Measured results](#measured-results)
- [Run it](#run-it)
- [Configuration](#configuration)
- [Tests and CI](#tests-and-ci)
- [Repository layout](#repository-layout)
- [Platform invariants](#platform-invariants)
- [Documentation](#documentation)

## Architecture

```mermaid
flowchart LR
    subgraph sources["Sources"]
        A["RPC node A"]
        B["RPC node B"]
        N["RPC node n"]
    end

    subgraph ingest["ingestd (Rust)"]
        Q["Quorum: a strict majority<br/>of at least 2 nodes"]
        R["Reorg tracker<br/>provisional / final"]
        D["ABI decode + enrich<br/>labels, Chainlink prices"]
        Q --> R --> D
    end

    BUS[("Redpanda<br/>or JSONL stream")]

    subgraph engine["Detection engine (Elixir, supervised)"]
        L1["Lane 1: rules<br/>YAML"]
        L2["Lane 2: invariants<br/>per protocol"]
        L3["Lane 3: ML client<br/>async"]
        M["Alert manager<br/>gate, dedup, rate limit,<br/>retract on reorg"]
        RS["Risk scores"]
        T["Tenant matcher<br/>watchlists, routes"]
        L1 --> M
        L2 --> M
        L3 --> M
        M --> RS
        M --> T
    end

    ML["Anomaly service<br/>(Python)"]
    PG[("PostgreSQL<br/>audit hash chain,<br/>orgs, keys, watchlists")]

    subgraph out["Outputs"]
        W["Webhook / PagerDuty / Telegram"]
        UI["Dashboard (Angular)<br/>Landing (SvelteKit)"]
        API["REST API<br/>alerts, scores, audit, org"]
        REP["Report service (Python)<br/>compliance PDFs"]
    end

    A & B & N --> Q
    D --> BUS --> L1 & L2 & L3
    L3 <-->|"HTTP, off the hot path"| ML
    M -->|"append-only"| PG
    RS -->|"append-only"| PG
    T --> PG
    M --> W
    T -->|"org routes"| W
    M -->|"Phoenix Channels"| UI
    M --> API
    API --> REP
```

| Layer | Technology | Why |
|---|---|---|
| Ingestion | Rust (alloy primitives), allowlisted JSON-RPC client | CPU-heavy decoding that must run for days without leaking. The only process that talks to nodes, and it can only call read methods. |
| Stream bus | Redpanda (Kafka API), or JSONL for replay and local runs | Decouples ingestion from detection; streams are replayable. |
| Detection | Elixir, Phoenix, Broadway | One supervised process per rule and per invariant. A crash restarts that monitor alone. Backpressure comes from Broadway. |
| ML | Python 3.12, scikit-learn, uv | Kept off the hot path as a separate service. |
| Audit, tenants | PostgreSQL 17 | Append-only enforced by the database; transactional, ordered appends. |
| Reports | Python, reportlab | PDFs that re-check the audit chain independently of the engine. |
| Frontends | Angular (dashboard), SvelteKit (landing), Cytoscape.js | Live updates over Phoenix Channels. |

## From block to alert

```mermaid
sequenceDiagram
    autonumber
    participant N as RPC nodes (2+)
    participant I as ingestd
    participant E as Engine
    participant ML as Anomaly service
    participant DB as Audit chain
    participant C as Connectors / dashboard

    I->>N: head, header and all logs of block h
    N-->>I: answers from each node
    I->>I: strict-majority quorum, else refuse to advance
    I->>E: block_adopted + upserts (provisional, attested_by)
    E->>E: rules and invariants evaluate the block
    E->>C: alert raised (high/critical only with 2+ attesting nodes)
    E-)DB: alert.raised and score change, hash-chained
    E-)ML: compact block (asynchronous)
    ML--)E: anomalies, capped at medium
    Note over I,E: Later, a reorg replaces block h
    I->>E: block_orphaned(h)
    E->>E: invariants roll back state, ML unlearns h
    E->>C: alert retracted (PagerDuty resolves)
    E-)DB: alert.retracted
    I->>E: block_finalized(h') once 64 blocks deep
    E->>C: alert final
```

Every alert has a lifecycle that follows the blocks its evidence came from:

```mermaid
stateDiagram-v2
    direction LR
    [*] --> Gate: candidate from a lane
    Gate --> Provisional: severity checked
    Gate --> Provisional: capped at medium if fewer than 2 nodes attested, or if raised by the ML lane
    Provisional --> Provisional: duplicate merges, no re-page
    Provisional --> Final: every evidence block finalized
    Provisional --> Retracted: an evidence block orphaned by a reorg
    Final --> [*]
    Retracted --> [*]
```

Final alerts are never retracted: ingestion halts loudly rather than rewrite finalized history. Every transition is an entry in the audit chain.

## Detection lanes

### Lane 1: rules for known attacks

Rules are YAML data, validated at load, and each runs in its own supervised process. Format: [docs/rules.md](docs/rules.md).

| Rule | Severity | Catches |
|---|---|---|
| `flash-loan-drain` | critical | A flash-loan transaction in which a labeled protocol ends with a large *net* USD outflow |
| `privileged-change` | high | Proxy upgrade, admin change, ownership transfer or role grant on a known protocol |
| `emergency-pause` | high | A known protocol emits `Paused` |
| `approval-farming` | medium | 8 or more wallets give unlimited approval to the same new, unknown spender within 50 blocks |
| `mixer-interaction` | low | Funds move into or out of a labeled mixer |

### Lane 2: invariants per protocol

Properties that must always hold, one supervised monitor each. A monitor snapshots its state per block and rolls back when a reorg orphans a block. Format: [docs/invariants.md](docs/invariants.md).

| Kind | Bundled monitors | Fires when |
|---|---|---|
| `peg` | USDC, USDT, DAI (Chainlink) | The price enters a wider band than before: 2% off peg is high, 5% is critical |
| `oracle` | ETH/USD, BTC/USD | One update moves more than 10% (high), or the feed is older than 90 minutes at block time (medium) |
| `outflow` | Euler, Aave, Compound V3, Balancer | Net USD outflow from the protocol's labeled contracts over 50 blocks exceeds its limit |

### Lane 3: ML for the unknown

A separate Python service ([services/anomaly](services/anomaly/README.md)) runs three online models. Every observation is keyed by block hash, so a reorged block is unlearned, and anomalous observations never enter training.

| Model | Learns | Flags |
|---|---|---|
| Protocol flow baseline | Each protocol's net outflow in its active blocks | A material outflow far above its own median (robust z-score) |
| Fund-flow graph (IsolationForest) | The shape of every token-moving transaction | A top-0.5% score **and** a dollar feature at 5x or more of the 99.9th percentile of normal |
| Novel patterns | Which event kinds each labeled contract emits | The first occurrence of a kind after warm-up |

ML alerts are **capped at medium**, enforced twice in the engine and checked by CI. If the service is down, the lane reports `degraded` and skips blocks; the other two lanes are never delayed.

**Alerts** from all lanes carry severity, weakness class, transaction hashes, log indexes, block hashes and the nodes that attested the evidence. Connectors: HMAC-signed webhooks, PagerDuty Events v2 (resolves on retraction) and Telegram.

## Risk scores, audit trail and tenants

**Risk scores** (`GET /api/scores`) give every protocol a health score from 0 to 100, with its reasons.

- **Calculation:** each open alert attributed to the protocol deducts by severity (critical 45, high 25, medium 10, low 3), capped at 70. The deduction halves every 6 hours, and ML alerts count half. Each broken invariant deducts 30, capped at 60.
- **Bands:** low (80+), elevated (60–79), high (40–59), critical (below 40).
- **Attribution:** an alert counts against the protocol that lost funds (net outflow), so the repaid flash-loan lender in the Euler exploit keeps 100.
- **Audit:** every change is written to the audit chain with its inputs.

**Audit trail** (`GET /api/audit/verify`): every alert lifecycle event and score change is one row in PostgreSQL. Each row's hash covers its canonical JSON body, which includes the previous row's hash.

- The database refuses `UPDATE`, `DELETE` and `TRUNCATE` on the table.
- An edit made by someone who bypasses that guard breaks the chain at that row, and `verify` reports where.
- The current head (`GET /api/audit/head`) can be recorded elsewhere to anchor the history. The chain is tamper-evident, not tamper-proof; [ADR-0004](docs/adr/0004-audit-chain-risk-scores-tenants-self-host.md) states the limits.

**Tenants** ([docs/api.md](docs/api.md)): chain data and alerts are public, but each organization's watchlist and alert routing are confidential.

- **Keys:** API keys (`cg_<prefix>_<secret>`, stored hashed) carry a role: viewer, analyst or admin.
- **Alert routing:** an alert whose evidence touches an org's watched address goes to that org's private channel and its own webhook, PagerDuty or Telegram routes, and nowhere else.
- **Isolation:** one org can never read or change another org's data, and the tests that prove it block merges.

**Compliance reports** ([services/report](services/report/README.md)): a PDF per alert with the evidence, the attesting nodes, the alert's lifecycle in the audit chain with full hashes, and the report's own re-check of every hash.

## Proof on real incidents

Incident fixtures are real mainnet blocks captured by `ingestd` from two independent providers. CI replays them through the full Broadway pipeline on every change, and the Compose job replays them through the containers.

| Incident | What SvlteChain raises |
|---|---|
| **Euler Finance exploit**, 13 Mar 2023, block 16,817,996 | **Rule:** `flash-loan-drain`, critical. Euler net outflow **$8,904,507** in tx `0xc310…111d`, matching published post-mortems (~8.87M DAI).<br>**Invariant:** `euler-outflow`, critical, on the same tx.<br>**ML:** the same tx, flagged on three dollar features.<br>**Risk score:** Euler 0 (critical); Aave, the lender, 100.<br>Nothing else in the block's 410 records is high or critical. |
| **USDC depeg**, 11 Mar 2023, blocks 16,802,107 and 16,802,135 | Quiet at Chainlink round 870 ($0.98214, inside the 2% band). At round 871 ($0.97652), exactly one high alert: `USDC/USD at $0.9765: 2.35% off its $1.0000 peg (band 2.00%)`. Circle's score drops to 45 (high). |
| Ordinary 2026 mainnet traffic, 827 records | Nothing high or critical |

**USDC/USD on Chainlink during the depeg** (rounds 856 to 984, blocks 16,795,835 to 16,803,482). The `usdc-peg` invariant fires once at round 871, the first answer outside the 2% band (red line at $0.98). After that it stays quiet while the price remains in the same band, and would escalate to critical below $0.95.

```mermaid
%%{init: {'themeVariables': {'xyChart': {'plotColorPalette': '#6250d6, #d03b3b'}}}}%%
xychart-beta
    title "Chainlink USDC/USD, 11 March 2023"
    x-axis "Chainlink round" ["856","862","868","870","871","874","880","886","892","898","904","910","916","922","928","934","940","946","952","958","964","970","976","983","984"]
    y-axis "USD" 0.87 --> 1.01
    line [1.0002,0.9878,0.9879,0.9821,0.9765,0.9687,0.9543,0.9462,0.9484,0.9438,0.9424,0.9443,0.9512,0.9458,0.9382,0.9327,0.9249,0.9114,0.899,0.9062,0.8918,0.8816,0.8976,0.8800,0.8833]
    line [0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98,0.98]
```

**Why the ML lane flags the Euler transaction.** Each bar is how far the exploit transaction sits above the 99.9th percentile of the 200 ordinary blocks before it. A dollar feature needs 5x or more (red line) to raise an alert.

```mermaid
%%{init: {'themeVariables': {'xyChart': {'plotColorPalette': '#6250d6, #d03b3b'}}}}%%
xychart-beta
    title "Euler exploit tx vs p99.9 of normal (multiple)"
    x-axis ["Total moved", "Largest transfer", "Protocol net outflow"]
    y-axis "x p99.9 of normal" 0 --> 40
    bar [32, 11, 35]
    line [5, 5, 5]
```

## Measured results

| What | Result | Conditions |
|---|---|---|
| One-command start | `scripts/up.sh --replay`: all services healthy in 63 s; 3 alerts, 8 risk scores and a valid 15-entry audit chain right after | One Windows dev machine, warm build caches, 2026-11-10 |
| Production release | The Elixir release migrates a fresh database and replays the incidents with the same 3 alerts and a valid chain | Same machine, outside Docker (see the CI `compose` job for the containers) |
| Live run, all three lanes | 45 consecutive blocks, 7,048 txs, 50,082 records, every block attested by 2 providers. 0 high or critical alerts on ordinary traffic. ML lane: 44 of 44 blocks scored, 0 errors, 0 skipped | Ethereum mainnet, `publicnode` + `drpc`, 2026-11-10 |
| Rules + invariants per block | p50 267 ms, p95 493 ms | 5 rules + 9 invariants, ~1,100 records per block, one Windows dev machine |
| Pipeline latency (record derived, then rules evaluated) | p50 about 530 to 600 ms | JSONL tail with 250 ms polling; not a benchmark |
| ML false positives | 2 of ~15,500 transactions in 200 real blocks before the Euler exploit. 1 transaction in the 45 live blocks ($25.1M moved across 30 addresses) | Shipped thresholds, medium severity, rate-limited |
| Block timestamp to detection | **Not measured** | The dev machine's clock was ~117 s behind. SvlteChain detected the skew and withheld the figure instead of reporting a wrong one |

## Run it

**One command.** `scripts/up.sh [--replay]` checks prerequisites, prepares the database, builds every part and starts all services in the background, with PID files and logs in `var/`. It creates a demo organization (its admin key goes to `var/demo-org.txt`), waits for every health check and prints the URLs. `scripts/down.sh` stops everything.

Requirements: Rust 1.88+, Erlang/OTP 29 with Elixir 1.20, Python 3.12 with [uv](https://docs.astral.sh/uv/), Node 24, and PostgreSQL 17 reachable at `CHAINGUARD_DATABASE_URL` (default `postgres://chainguard:chainguard@localhost/chain_guard_dev`).

**Containers.** `docker compose -f deploy/compose/docker-compose.yml up --build` runs the same stack (PostgreSQL, engine, ML, reports, dashboard, landing) and replays the incidents by default. For mainnet:

```sh
export CHAINGUARD_RPC_A=https://ethereum-rpc.publicnode.com
export CHAINGUARD_RPC_B=https://eth.drpc.org
CHAINGUARD_SOURCE=kafka docker compose -f deploy/compose/docker-compose.yml --profile live up --build
```

**By hand**, part by part:

```sh
cp config/ingestd.example.toml config/ingestd.toml     # set sink.path = "var/stream.jsonl"
cargo run --release -p chainguard-ingestd -- -c config/ingestd.toml
(cd services/anomaly && uv run chainguard-anomaly serve --port 8700)
(cd apps/engine && mix setup && CHAINGUARD_SOURCE=jsonl CHAINGUARD_JSONL_PATH=../../var/stream.jsonl \
  CHAINGUARD_ANOMALY_URL=http://127.0.0.1:8700 mix phx.server)
(cd services/report && uv run chainguard-report serve --port 8800)
(cd apps/dashboard && npm ci && npx ng serve --port 4300)
(cd apps/landing && npm ci && npm run dev)
```

| Service | Port | Endpoints |
|---|---|---|
| Engine | 4000 | `/api/health`, `/api/alerts`, `/api/scores`, `/api/audit/verify`, `/api/org/*`, socket `/socket`. Full list: [docs/api.md](docs/api.md) |
| Anomaly service | 8700 | `POST /v1/blocks`, `POST /v1/orphan`, `GET /v1/model`, `GET /healthz` |
| Report service | 8800 | `GET /reports/alerts/<id>.pdf` |
| Dashboard | 4300 | `?engine=` and `?report=` to point elsewhere |
| Landing page | 4400 | Live when an engine is reachable, otherwise a labeled recorded run |
| PostgreSQL | 5432 | Audit chain, orgs, keys, watchlists, routes |

## Configuration

Ingestion is configured in TOML (`config/ingestd.example.toml`): nodes, quorum, confirmations, labels, Chainlink price feeds and the sink. Keep API keys out of the file: `url_env` reads a node URL from the environment.

The engine reads environment variables:

| Variable | Purpose |
|---|---|
| `CHAINGUARD_DATABASE_URL` | PostgreSQL for the audit chain and tenants |
| `CHAINGUARD_SOURCE` | `jsonl`, `kafka` or `none` |
| `CHAINGUARD_JSONL_PATH`, `CHAINGUARD_JSONL_MODE` | Stream file, and `tail` (default) or `replay` |
| `CHAINGUARD_KAFKA_HOSTS`, `CHAINGUARD_KAFKA_TOPICS` | Redpanda consumer |
| `CHAINGUARD_ANOMALY_URL` | ML service; unset disables the lane |
| `CHAINGUARD_WEBHOOK_URL`, `CHAINGUARD_WEBHOOK_SECRET` | Global HMAC-signed webhook (orgs add their own routes through the API) |
| `CHAINGUARD_PAGERDUTY_ROUTING_KEY` | PagerDuty Events v2 |
| `CHAINGUARD_TELEGRAM_BOT_TOKEN`, `CHAINGUARD_TELEGRAM_CHAT_ID` | Telegram |
| `CHAINGUARD_*_MIN_SEVERITY` | Per-connector severity floor |
| `CHAINGUARD_CORS_ORIGINS` | Allowed browser origins (default: the local dashboard and landing page) |
| `SECRET_KEY_BASE`, `PHX_HOST` | Required for production releases |

Create an organization and its first admin key with `mix chain_guard.org.create "Acme Risk" --watch 0x…:Label`, or `bin/chain_guard eval 'ChainGuard.Release.create_org("Acme Risk")'` in a release.

## Tests and CI

| Suite | Command | Tests |
|---|---|---|
| Rust ingestion | `cargo test --workspace` | 45, plus 1 Anvil reorg test that runs in CI |
| Elixir engine | `cd apps/engine && mix test` | 77, including incident replays, the audit chain and tenant isolation (needs PostgreSQL) |
| Python ML service | `cd services/anomaly && uv run pytest` | 16, including 200 real mainnet blocks |
| Python report service | `cd services/report && uv run pytest` | 5 |
| Dashboard | `cd apps/dashboard && npx ng test --watch=false` | 10 |
| Landing page | `cd apps/landing && npm test` | 7 |
| Invariant guard | `scripts/check-invariants.sh` | Blocks merges |

CI runs nine jobs on every push and pull request:
- Rust (fmt, clippy, tests) and the invariant guard;
- the Anvil reorg test;
- the engine with incident replays (against a PostgreSQL service);
- the ML service and the report service;
- the dashboard and the landing page;
- `compose`, which builds every image, starts the stack and checks the replayed alerts, the critical risk score, a valid audit chain, a PDF report and both front ends.

The invariant guard fails the build if any of these are removed or weakened:
- read-only enforcement and multi-node verification;
- reorg handling;
- the alert-layer guards: single-source cap, retraction, dedup, rate limit;
- invariant rollback and the ML lane's medium ceiling;
- the audit chain's append-only triggers and tamper detection;
- tenant isolation.

The guard itself was mutation-tested: deliberately weakening guarded code made it fail on exactly the right tests. The weakened code included an engine alert-layer guard, the ML lane's never-learn-anomalies rule, the audit link check, and the org scope on watchlist deletes.

## Repository layout

```text
crates/
  ingest-core/        quorum source, reorg tracker, ABI decoding, enrichment
  rpc/                allowlisted read-only JSON-RPC client
  ingestd/            ingestion daemon (JSONL or Kafka sink, checkpoints)
apps/
  engine/             Elixir engine: rules, invariants, ML client, alerts, risk scores,
                      audit chain, tenants, REST API and channels
    priv/rules/         YAML detection rules
    priv/invariants/    YAML invariant monitors
    priv/repo/          PostgreSQL migrations (append-only audit log, tenants)
    test/fixtures/      real incident blocks for replay tests
  dashboard/          Angular live dashboard: fund-flow graph, alerts, risk, invariants
  landing/            SvelteKit landing page (static)
services/
  anomaly/            Python ML anomaly service
  report/             Python compliance report service (PDF)
data/labels/          public address labels (EIP-55 checked)
config/               ingestd configuration examples
deploy/               Dockerfiles, Compose stack, ClickHouse schema
docs/                 rule, invariant and API references, architecture decision records
scripts/              up.sh / down.sh, incident replay builder, invariant guard
```

## Platform invariants

These hold in every change. CI enforces 1 to 6.

1. **Read-only.** No keys, no signing, no transactions.
2. **Never trust a single node.** High and critical alerts need evidence attested by at least two independent nodes.
3. **Reorg-safe.** Everything is provisional until final; retract and re-emit on reorg.
4. **Tamper-evident audit trail.** Every alert event and score change is hash-chained and append-only in the database.
5. **No false urgency.** Dedup, rate limits, evidence on every alert, and an ML lane that never pages.
6. **Tenant isolation.** Watchlists, routes and keys never cross organizations; private alert channels need the org's key.
7. **No market-manipulation surface.** SvlteChain reports risk and never acts on it.

## Documentation

- [API reference](docs/api.md)
- [Writing detection rules](docs/rules.md)
- [Invariant monitors](docs/invariants.md)
- [ML anomaly service](services/anomaly/README.md) and [report service](services/report/README.md)
- [ADR-0001: reorg-safe multi-node ingestion](docs/adr/0001-reorg-safe-multi-node-ingestion.md)
- [ADR-0002: detection engine and alert lifecycle](docs/adr/0002-detection-engine-and-alert-lifecycle.md)
- [ADR-0003: invariants, the ML lane and the fund-flow graph](docs/adr/0003-invariants-ml-lane-and-fund-flow-graph.md)
- [ADR-0004: audit chain, risk scores, tenants and self-host](docs/adr/0004-audit-chain-risk-scores-tenants-self-host.md)

**Known limits.**
- **Not run here:** the Docker images and the Compose stack were written on a machine without Docker and are verified by the CI `compose` job, which has not run yet.
- **Not built yet:** there is no hosted public demo. Human sign-in (OAuth/SSO), a secrets vault for route credentials, scheduled external anchoring of the audit head, OpenTelemetry, Helm and Terraform are follow-ups listed in ADR-0004.
- **Pricing:** token prices come from labels (stablecoins) and from Chainlink feeds after their first update following start-up.
- **Outflow invariants** see priced transfers, not contract balances.
- **Restarts:** monitor and model state re-warms after a restart, while the audit chain persists.

## License

[MIT](LICENSE)
