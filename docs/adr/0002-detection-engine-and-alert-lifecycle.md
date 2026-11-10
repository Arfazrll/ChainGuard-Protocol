# ADR-0002: Detection engine, alert lifecycle and live dashboard

**Status:** Accepted
**Date:** 2026-11-10
**Deciders:** ChainGuard maintainers

## Context

Milestone 2 adds the rule engine (5 rules), a Broadway consumer, webhook alerts and a basic live dashboard. It inherits ingestion's guarantees (ADR-0001), but alerts add new ways to fail:

- an alert raised on a block that is later reorged away (a false alarm that looks real)
- an alert raised on data from one node
- the same incident paging repeatedly
- a buggy community rule taking detection down
- latency numbers that look good because they are wrong

## Decision

### Elixir/Phoenix engine (`apps/engine`)
- **Broadway pipeline** over BroadwayKafka (Redpanda) in production, or over a JSONL producer (replay or tail of `ingestd`'s file sink) for incident replay and local demos. Processors are `partition_by` the chain key, so one chain's messages are handled strictly in order. A retraction can never overtake its upsert. Dispatch is retried per message with backoff; exhausted messages go to a bounded dead-letter ring.
- **One `Chain.Server` per chain** assembles blocks (complete when `record_count` upserts have arrived), evaluates rules, and maps `block_orphaned` → retract, `block_finalized` → finalize, `integrity_halt` → critical *system* alert. `seq` at or below the last processed one is a redelivery and is ignored.
- **Rules are YAML data** (`priv/rules/`, format in `docs/rules.md`), compiled and validated at load. Three scopes: `record`, `tx` (incl. `net_outflow`), and `window` (distinct counts, novelty with warm-up, reorg-aware). Evaluation is pure (`Rules.Evaluator`). **Each rule runs in its own supervised GenServer**, evaluated concurrently with a timeout, so a crashing rule restarts alone.
- **`Alerts.Manager`** owns the lifecycle. It caps severity at `medium` unless at least 2 nodes attested the evidence (invariant 2), merges duplicates inside a dedup window, applies a per-rule rate limit (invariant 5), and tracks evidence blocks so alerts become `final` or `retracted` (invariant 3). Final alerts are never retracted.
- **Fan-out:** Phoenix PubSub → Channels (`alerts:global`, `live:<chain>`), plus connectors in supervised tasks with exponential backoff: HMAC-SHA256-signed webhooks (timestamped against replay), PagerDuty Events v2 (trigger on raise, resolve on retraction), and Telegram (plain text, so on-chain names cannot inject markup). Merges never re-page.

### `net_outflow` instead of gross transfer thresholds
The first draft of `flash-loan-drain` matched "flash loan + large transfer out of a labeled protocol". That fires on every large flash loan, because the lender's principal leaves and returns. Real Euler exploit data shows the lender (Aave V2 aDAI) at **+$27,000** net (its fee) and Euler at **−$8,904,507**. Netting per labeled party separates them exactly.

### Honest latency
The authoring machine's clock turned out to be ~117 s behind real time, which surfaced as "0 ms" latency because lags were clamped at zero. Latencies are now signed, `clock_skew_suspected` is reported, and the dashboard shows *n/a* with the reason instead of a number. A skew-free metric, **pipeline latency** (`ingestd` derived the record → rules evaluated), is measured separately. Replayed history (blocks older than 10 minutes) never feeds latency figures.

### Dashboard (`apps/dashboard`, Angular 22, zoneless)
Phoenix Channels become RxJS observables, folded into signals. Pure reducers (`core/state.ts`) are unit-tested. Colors follow the brief's roles: violet for brand and the single chart series (validated with the dataviz validator on the dark surface), emerald only for live/verified, red/orange/amber only for severity. Severity is **never color alone**: medium (amber) and high (orange) measure ΔE 13.6, below the 15 floor, so every severity carries a label and a distinct glyph. The chart has a table-view twin, hover and focus tooltips, and is sized to its real width so text never stretches.

## Options considered

| Option | Why not |
|---|---|
| Rules as Elixir modules | Not community-writable; a rule bug can be arbitrary code. Data rules are reviewable and validated. |
| One GenServer per *chain* evaluating all rules | One bad rule would take down a chain's detection. |
| Gross-transfer drain rule | False positive on every large flash loan (shown above). |
| Clamp negative lag to 0 | Hides clock skew; produced the "0 ms" figures we caught. |

## Consequences
- Detection runs on provisional data immediately, and alerts self-correct on reorgs: a retraction is a first-class event for every connector.
- Window state and alerts are in memory: an engine restart loses open windows and recent alerts. The tamper-evident audit chain in PostgreSQL (milestone 4) makes them durable.
- The socket is unauthenticated and serves public data and public rules only. Tenant-scoped topics need auth (milestone 4, invariant 6).

## Action items
1. [x] Engine, 5 rules, alert lifecycle, webhook, PagerDuty and Telegram connectors, Channels, JSON API.
2. [x] Real-incident regression: Euler Finance (block 16,817,996) replayed through Broadway raises exactly one critical alert; a block of ordinary mainnet traffic raises nothing high or critical.
3. [x] Live end-to-end on mainnet: ingestd (2 providers) → JSONL → Broadway → rules → dashboard.
4. [x] CI: engine and dashboard jobs; the invariant guard covers engine invariants 2/3/5 (mutation-tested).
5. [ ] Redpanda path end to end (BroadwayKafka) in Compose; Docker is not available on the authoring machine.
6. [ ] More incident fixtures (privileged change, pause, approval-drainer campaigns).
7. [ ] Chainlink `latestRoundData` pricing for non-stable tokens (WETH, WBTC are unpriced today, so drains in them are invisible to `net_outflow`).
