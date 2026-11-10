# ADR-0001: Reorg-safe, multi-node-verified ingestion

**Status:** Accepted
**Date:** 2026-11-10
**Deciders:** SvlteChain maintainers

## Context

Ingestion is the foundation every detection lane, alert and risk score rests on. Three of the non-negotiable invariants land here first:

1. **Read-only.** No keys, no signing, no transactions.
2. **Never trust a single node.** A lagging, forked or dishonest RPC must not be able to inject, drop or alter data.
3. **Reorg-safe.** Recent blocks are provisional. Derived state from an orphaned block must be retracted and the canonical block's state re-emitted, never silently overwritten or left behind.

Ingestion must also be decoupled from processing (stream bus), replayable, and cheap to reason about under failure (crash between publish and checkpoint, bus outage, node outage).

## Decision

A Rust workspace with three crates, split so the hard logic has **no I/O** and can be tested exhaustively:

| Crate | Role |
|---|---|
| `chainguard-ingest-core` | Pure logic: quorum reconciliation, reorg tracker, ABI decode, enrichment, bus message types, testkit |
| `chainguard-rpc` | The only crate that speaks HTTP: an allowlisted, read-only JSON-RPC client |
| `chainguard-ingestd` | The daemon: config, checkpoint, sinks (JSONL, Redpanda), main loop |

### Read-only by construction
No Alloy provider, signer, wallet or network crates. Alloy is used only for primitives and ABI types. All node traffic goes through `HttpNode::call`, which refuses any method not in `ALLOWED_METHODS` (all reads) and anything matching a deny-list of prefixes (`eth_send`, `eth_sign`, `personal_`, `wallet_`, `admin_`, …) before a request is built. CI (`scripts/check-invariants.sh`) fails if a signer or keystore crate enters the build graph, if signing code appears in production sources, if the allowlist check is removed, or if any crate other than `chainguard-rpc` depends on an HTTP client.

### Quorum source
`QuorumSource` asks every configured node concurrently (per-request timeout) and accepts an answer only when at least `min_agreement` nodes return it identically. This applies to:
- **Head:** the highest height at least `min_agreement` nodes have reached, then a quorum on the block at that height.
- **Headers** by number and by hash, each validated per node (it returned the block that was asked for).
- **The full log set of a block** (`eth_getLogs` by `blockHash`), sorted by log index, validated per node (every log belongs to the requested block; no duplicate indices; no `removed` logs), and compared byte for byte.

`min_agreement` defaults to 2, must be a strict majority (so two conflicting answers can never both reach quorum), and values below 2 are rejected unless `allow_single_source` is set explicitly for development. Every record carries `attested_by`, so downstream detection can enforce "≥ 2 sources before high severity".

### Reorg tracker: a two-phase pure state machine
`ReorgTracker` holds a provisional window of the last `confirmations` canonical blocks, each with the records derived from it, a finalized anchor, and a short history of finalized hashes.

- `plan(segment)` computes, without mutating: a `Reorg` summary; `Retract` for every record of every orphaned block, newest block first; `BlockOrphaned`; `BlockAdopted` + `Upsert` for new blocks, oldest first; `BlockFinalized` for blocks now `confirmations` deep.
- `commit(plan)` applies it. The daemon calls it **only after the bus acknowledged the messages**. A failed publish therefore changes nothing and the step is retried.
- Reorgs are found by walking back parent hashes (quorum-verified) until the candidate reconnects to the window.
- A fork that diverges at or below the finalized anchor (or below the first ingested block) produces an `IntegrityHalt` message and stops ingestion until an operator intervenes. It is never silently adopted or ignored. A quorum head *below* the anchor is checked against finalized history: same hash means the nodes are lagging and it is ignored; a different hash means a halt.

### Bus semantics
Each chain gets one single-partition topic, so there is a total order. Every message carries a per-chain, strictly increasing `seq`. Records are keyed by `keccak256(chain_id ‖ block_hash ‖ log_index)`. The block **hash** is part of the identity, so the same log position on competing forks is a different record. Consumers materialize with "highest `seq` wins"; retractions are tombstones. In ClickHouse this is `ReplacingMergeTree(seq, is_deleted)`. Delivery is at-least-once: the checkpoint is written after the publish, and a replay after a crash re-sends identical `seq`s, which the table absorbs idempotently.

## Options considered

### Option A: Pure core + allowlisted client + two-phase tracker (chosen)
| Dimension | Assessment |
|---|---|
| Complexity | Medium: more code than using a provider SDK directly |
| Cost | Quorum multiplies RPC calls by N (3 calls per block per node) |
| Scalability | One process per chain; per-block work is O(logs) |
| Testability | High: every reorg and node-failure path runs in-memory, including property tests |

**Pros:** read-only is enforced in code and checked in CI; reorg handling is exhaustively testable; publish failures are safe by construction; consumers stay simple (highest seq wins).
**Cons:** a hand-written JSON-RPC client (small, but ours to maintain); N× RPC cost; WebSocket subscriptions are not used yet (polling).

### Option B: Alloy provider with a block-stream subscription
| Dimension | Assessment |
|---|---|
| Complexity | Low to start |
| Testability | Low: reorg behaviour is buried in transport and async streams |

**Pros:** less code, WS push. **Cons:** pulls in signer/wallet plumbing we must then prove unused; single-provider by default; reorg logic entangled with I/O.

### Option C: Write directly to ClickHouse with `ALTER … DELETE` on reorg
**Pros:** no bus. **Cons:** mutations are heavy and asynchronous in ClickHouse; no replay; couples ingestion to storage (contradicts the brief's decoupled, replayable bus).

## Trade-off analysis
The dominant risk for a security monitor is **wrong data looking right**: a phantom transfer from an orphaned block raising an alert, or a lying node hiding a drain. Option A spends RPC budget and some code to make those failures structurally impossible or loud (halt). Polling adds up to one poll interval of latency (2 s default) versus WS push. That is acceptable for v1, and WS `newHeads` can later trigger the same `next_plan` step without changing the tracker.

## Consequences
- **Easier:** proving invariants (tests named `invariant_*` are required by CI); replaying; adding chains (one daemon and one topic per chain); adding consumers (Elixir/Broadway reads the same topic).
- **Harder:** RPC cost scales with node count; the checkpoint holds the window's records (fine at 64 blocks, revisit for very log-heavy chains).
- **Revisit:**
  - Use the node's `finalized` block tag in addition to depth-based finality.
  - WebSocket `newHeads` as the poll trigger.
  - Move the checkpoint from JSON to an embedded KV store if it grows large.
  - Oracle-derived prices are "latest observed answer at or before the block" and can include an answer from a block later orphaned. They are marked with `as_of_block`.
  - Header hash verification (RLP re-hash) for defence in depth beyond quorum.

## Action items
1. [x] Core: quorum source, reorg tracker, decode, enrich, testkit.
2. [x] Reorg suite incl. property test; quorum suite; read-only guard tests.
3. [x] Daemon with JSONL and Redpanda sinks, atomic checkpoint, integrity-halt exit code.
4. [x] Live smoke test against Ethereum mainnet via two independent public RPCs.
5. [x] ClickHouse schema, Compose stack, CI with invariant guard and an Anvil reorg job.
6. [ ] Run the Compose stack and the Anvil job end to end (needs Docker / Foundry; not available on the authoring machine).
7. [ ] Prometheus metrics: event-to-ingest lag, quorum failures per node, reorg depth histogram.
8. [ ] `cargo-deny` (advisories, licenses, bans) in CI; pin GitHub Actions by SHA.
