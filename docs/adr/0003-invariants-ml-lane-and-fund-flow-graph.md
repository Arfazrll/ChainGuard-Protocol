# ADR-0003: Invariant monitors, the ML anomaly lane, and the fund-flow graph

**Status:** Accepted
**Date:** 2026-11-10
**Deciders:** ChainGuard maintainers

## Context

Milestone 3 completes the detection engine's three lanes (brief §8) and adds the fund-flow graph to the dashboard. Rules (ADR-0002) catch attack shapes someone has already described. Two gaps remain:

- **Health, not attacks.** A depegging stablecoin, a stale or jumping oracle, or a protocol bleeding funds is a risk whatever the cause.
- **The unknown.** An exploit nobody wrote a rule for.

Both must hold the platform invariants: multi-node evidence before high severity (2), reorg safety (3), and no false urgency (5).

## Decision

### Invariant lane (Elixir, `ChainGuard.Invariants`)
- **YAML definitions** (`priv/invariants/`), validated at load, three kinds: `peg`, `oracle`, `outflow` (format: [docs/invariants.md](../invariants.md)). Bundled: USDC, USDT and DAI pegs; ETH/USD and BTC/USD oracle sanity; Euler, Aave, Compound V3 and Balancer outflow.
- **One supervised GenServer per invariant**, evaluated with the rule lane on every completed block. A crashing monitor restarts alone; the others keep running.
- **Reorg safety in one place:** the monitor snapshots state per block hash and restores it when a block is orphaned. Checks are pure and written as if the chain never reorgs.
- **Prices from the chain:** pegs read Chainlink `AnswerUpdated` directly. Ingestion now prices WETH, USDC, USDT and DAI transfers from the same feeds (`oracle_feeds` in the ingestd config), replacing the $1 peg assumption once a feed has updated.

### ML lane (Python service, `services/anomaly`, plus `ChainGuard.Anomaly`)
- **Separate service, off the hot path.** The engine hands each completed block to `ChainGuard.Anomaly` *asynchronously*. Rules and invariants never wait for ML. If the service is slow or down, blocks are skipped and counted (`ml_skipped`), the lane reports `degraded` with exponential backoff, and the other lanes are unaffected.
- **Three online models**, each keyed by block hash so a reorged block is *unlearned*:
  1. per-protocol flow baseline (robust z-score of log net outflow, median/MAD);
  2. IsolationForest over the shape of each transaction's fund-flow graph (transfers, addresses, tokens, USD, flash loans, cycles, fan-out, protocols touched);
  3. novel event kinds per labeled contract after warm-up.

  Blocks are scored *before* they are learned, and anomalous observations never enter training.
- **A graph anomaly needs two things:** a top-0.5% IsolationForest score *and* at least one feature beyond the 99.9th percentile of normal. Without the second condition the alert has no reason to show, and IsolationForest scores saturate outside the training range, so the score alone has little margin.
- **Severity ceiling: medium (novel patterns: low).** Enforced twice: in the client, and in the alert manager's `lane_gate/2`, so no service response can page anyone. CI fails if either is removed.
- **No web framework.** The service uses the standard-library `http.server` with one model lock. Dependencies are numpy and scikit-learn, locked in `uv.lock`.

### Fund-flow graph (dashboard, Cytoscape.js)
- The engine adds per-block **flow edges** to every `block` event (`ChainGuard.Flows`): priced transfers aggregated per `from → to` pair. It keeps the top 40 edges by USD plus every edge touching a mixer or bridge, so laundering paths are never cut.
- The dashboard keeps a rolling window of the last 12 blocks, **drops orphaned blocks**, and marks red only the addresses and transactions that are evidence in an open alert. Category is encoded by node shape with a legend, never by colour alone. The graph has a table view, and Cytoscape loads lazily (120 kB gzipped) outside the initial bundle.

### Landing page (`apps/landing`, SvelteKit)
At the owner's request the landing page moved up from milestone 4. It is a separate SvelteKit 3 / Svelte 5 static site, so marketing and the dashboard deploy and evolve independently. With an engine reachable, its stat band and terminal are live over the same Phoenix Channels. Otherwise it plays back a recorded real run and incident replays, and labels them so.

## Options considered

| Option | Why not |
|---|---|
| Invariants as rules with extra scopes | State machines (bands, staleness, hysteresis) don't fit match predicates; separate kinds keep both formats simple. |
| Read TVL with `eth_call balanceOf` | A new read path (multi-node quorum on calls) for a first version; net priced outflow catches drains with data we already have. Listed as a follow-up. |
| ML inside the BEAM (Nx) | The brief keeps ML in Python; a separate service also isolates its failure modes. |
| Synchronous ML call per block | One slow model call would delay every alert. |
| IsolationForest score alone | Saturates outside the training range; flagged ordinary exchange batches. |
| Let ML raise high/critical | Statistical signals page people for normal-but-rare events; invariant 5. |

## Consequences
- Detection on Euler is now confirmed by two independent lanes (rule + invariant) on the same transaction.
- Monitor and ML state are in memory: a restart re-warms (protocol baselines need 20 active blocks; the graph model needs 1,000 transactions, about 5–10 blocks; novelty arms after 300 blocks).
- Outflow invariants only see priced tokens; oracle-priced tokens are unpriced until their feed's first update after startup.

## Action items
1. [x] Invariant lane with 9 bundled invariants, reorg rollback, status API and channel events.
2. [x] Real-incident regression: USDC depeg (blocks 16,802,107 / 16,802,135), Euler outflow on block 16,817,996.
3. [x] ML service with three models, reorg unlearning, HTTP API, offline replay CLI; engine client with backoff and severity ceiling.
4. [x] Fund-flow graph and invariant panel in the dashboard; lane tags on alerts.
5. [x] CI: Python job, landing job; invariant guard covers the ML ceiling and lane tests.
6. [ ] Seed oracle prices at startup (`latestRoundData` via quorum `eth_call`) so tokens are priced from the first block.
7. [ ] Balance-based TVL invariants (quorum `eth_call`), and persistence of monitor and model state across restarts.
8. [ ] Redpanda path end to end in Compose (carried over from ADR-0002).
