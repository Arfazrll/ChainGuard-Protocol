# ADR-0004: Audit chain, risk scores, tenant isolation and one-command self-host

**Status:** Accepted
**Date:** 2026-11-10
**Deciders:** SvlteChain maintainers

## Context

Milestone 4 makes SvlteChain usable by a risk team rather than only readable by an engineer (brief §2, §11, §14):

- **Defensible decisions:** every alert and score must be reconstructable and provably unaltered (invariant 4).
- **A risk-score API** as the product's second face.
- **Several customers on one deployment,** without one seeing another's watchlist or routing (invariant 6).
- **A compliance-ready report.**
- **"A stranger self-hosts and sees live alerts in one command."**

## Decision

### Tamper-evident audit chain (PostgreSQL, `ChainGuard.Audit`)
- **What is logged:** one table, `audit_log`, with one row per event: every alert lifecycle event (`alert.raised`, `alert.updated`, `alert.retracted`, `alert.finalized`), every risk-score change (`score`), and tenant-scoped matches (`org.match`).
- **What a row holds:**
  - `body`: the canonical JSON that was hashed (sorted keys, no whitespace). It carries the event's payload (inputs, sources consulted, rule version), its `seq`, its timestamp and the **previous entry's hash**.
  - `hash = sha256(body)`.
  - The body is stored as text, not jsonb, so the hashed bytes survive verbatim.
- **Append-only in the database:** triggers raise on `UPDATE`, `DELETE` and `TRUNCATE`, and the migration refuses to roll back.
- **Ordered appends across engine nodes** come from a transaction-scoped advisory lock.
- **Verification:** `Audit.verify/0` (`GET /api/audit/verify`) re-derives every hash from the stored bodies and checks every link. Gaps, edited bodies and re-hashed rows are each reported at the first broken `seq`.
- **Limit (stated plainly):** a database superuser can disable the trigger and rewrite the whole suffix consistently. The current head is therefore published (`GET /api/audit/head`, and in every report) for external anchoring. The chain is tamper-*evident*, not tamper-proof.
- **Written off the hot path:** `Audit.Writer` listens on PubSub. Detection never waits for PostgreSQL. During an outage, entries queue in order (bounded, overflow counted) and are retried; the lane reports `degraded`.

### Risk scores (`ChainGuard.Risk`, `GET /api/scores`)
- **Model:** deterministic and explainable (`risk-v1`):
  - The score starts at 100.
  - Alert deductions by severity: critical 45, high 25, medium 10, low 3. They halve every 6 hours, ML-lane alerts count half, and the total is capped at 70.
  - Each broken invariant deducts 30, capped at 60.
  - Bands: low (80+), elevated (60–79), high (40–59), critical (below 40). Confidence reflects how many of the protocol's invariants are reporting.
- **Attribution** follows the damage:
  - invariant alerts count against their own protocol;
  - transfer evidence counts against protocols with a *net* outflow (a repaid flash-loan lender is not penalized);
  - privileged changes count against the emitting protocol.
- **Audit:** every score change, with its components and inputs, goes to the audit chain.

### Tenants, RBAC and isolation (`ChainGuard.Tenants`)
- **Data:** orgs, API keys, watchlists and routes live in PostgreSQL.
- **API keys:** `cg_<prefix>_<secret>`, stored as prefix plus SHA-256 of the secret, compared in constant time, and shown once.
- **Roles:** `viewer` < `analyst` (edit watchlist) < `admin` (routes, keys).
- **Scoping:** every org-scoped query takes the org from the authenticated key, never from the request. Route secrets are never returned.
- **Socket:** public topics stay public. `alerts:org:<id>` needs that org's key as the `token` connect parameter. A present-but-invalid token is refused rather than downgraded to anonymous.
- **Matching:** `Tenants.Matcher` matches each public alert's evidence addresses against the watchlists. A matching org gets the event on its private channel, delivery to its own routes (same retrying fan-out as global connectors), and an org-scoped `org.match` audit entry that the public audit API never shows.
- **Rate limits:** a fixed-window limit per key (600/min) or per IP (120/min) on the whole API.

### Compliance report (`services/report`, Python + reportlab)
- `chainguard-report alert <id>`, or `GET /reports/alerts/<id>.pdf` from the dashboard.
- **Contents:** summary, verdict on the audit trail, exact evidence with attesting nodes, the alert's lifecycle from the audit chain with full hashes, and the method.
- **Independent check:** the report does not take the engine's word for it. It re-hashes every included entry and checks the links itself, and states plainly when the trail is not verified.

### Self-host in one command
- **Containers:** `docker compose -f deploy/compose/docker-compose.yml up --build` brings up PostgreSQL, the engine (Elixir release, migrates on start), the ML and report services, the dashboard and the landing page.
- **Default feed:** the bundled replay of the two real incidents, so alerts, scores and the audit chain appear with no RPC and no keys. The `live` profile adds Redpanda, ingestd and ClickHouse for mainnet.
- **CI acceptance:** the `compose` job builds every image, starts the stack and asserts the alerts, the critical score, a valid chain, a PDF and both front ends.
- **Native:** `scripts/up.sh [--replay]` does the same natively (Git Bash, Linux, macOS). It checks prerequisites, migrates, builds, starts every service with PID files and logs in `var/`, creates a demo org and waits for health. `scripts/down.sh` stops the process trees.

## Options considered

| Option | Why not |
|---|---|
| Audit log as files | Weaker guarantees and harder multi-node ordering; PostgreSQL gives a database-level append-only guard and transactional appends. |
| Store the body as jsonb | jsonb normalizes key order and number formatting, so the hashed bytes would not be recoverable. |
| Merkle tree per block | More moving parts than a linear chain for the volumes involved; the published head plays the anchor role. |
| JWTs for API auth | Revocation needs a lookup anyway; opaque hashed keys are simpler and revocable. |
| A learned risk model | A score a risk team cannot explain is not one they can act on. |

## Consequences
- **Detection and audit are decoupled.** PostgreSQL can be down without stopping alerts, but entries then queue in memory until it returns.
- **Restarts:** the audit chain survives restarts. Window and model state still do not (ADR-0003).
- **Verification cost:** verification reads the whole chain. It is batched, but it is O(n); periodic anchoring and incremental verification are follow-ups.

## Action items
1. [x] Audit chain with database-level append-only guard, verification and head API; CI checks the triggers and the tamper tests.
2. [x] Risk scores with audited changes; dashboard panel with audit status.
3. [x] Tenants, roles, keys, org channels, routes, rate limits; isolation tests required by CI.
4. [x] PDF compliance report with an independent chain check.
5. [x] `scripts/up.sh` (tested on this machine) and Docker Compose with a CI acceptance job.
6. [ ] Publish the audit head externally on a schedule (e.g. to a signed log), and incremental verification.
7. [ ] OAuth/SSO for humans on top of API keys, and a secrets vault for route credentials (brief §11).
8. [ ] OpenTelemetry traces and Prometheus metrics (brief §13); Helm chart and Terraform (brief §12).
