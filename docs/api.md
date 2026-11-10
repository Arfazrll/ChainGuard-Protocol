# API

Base URL: the engine, `http://localhost:4000` by default. JSON everywhere. All endpoints are rate-limited: 600 requests/minute per API key, 120 per IP without one. Responses carry `x-ratelimit-limit` and `x-ratelimit-remaining`, and a 429 response includes `retry-after`.

## Public: public chain data, no key

| Endpoint | Returns |
|---|---|
| `GET /api/health` | engine status, loaded rules and invariants, lane states |
| `GET /api/stats` | counters and latency percentiles |
| `GET /api/lanes` | state of the rules, invariants, ML and audit lanes |
| `GET /api/rules`, `GET /api/invariants` | definitions and current invariant status |
| `GET /api/alerts?limit=50`, `GET /api/alerts/:id` | alerts with evidence, lane, lifecycle |
| `GET /api/scores`, `GET /api/scores/:protocol` | risk scores with components; a protocol's audited score history |
| `GET /api/audit?subject=&kind=&limit=` | public audit entries (body, hash, prev_hash) |
| `GET /api/audit/head` | latest `seq` and hash: record it to anchor the chain |
| `GET /api/audit/verify` | `200 {valid: true, entries, head}` or `409 {valid: false, broken_at, reason}` |

## Organization: `Authorization: Bearer cg_<prefix>_<secret>`

| Endpoint | Role | Does |
|---|---|---|
| `GET /api/org` | viewer | the key's org and role |
| `GET /api/org/watchlist` | viewer | watched addresses |
| `GET /api/org/alerts` | viewer | public alerts touching the watchlist |
| `GET /api/org/audit` | viewer | public entries plus this org's own entries |
| `POST /api/org/watchlist` `{address, label, note}` | analyst | watch an address |
| `DELETE /api/org/watchlist/:id` | analyst | stop watching |
| `GET /api/org/routes` | admin | alert routes, secrets redacted |
| `POST /api/org/routes` `{kind, min_severity, config}` | admin | `webhook` (`url`, `secret`), `pagerduty` (`routing_key`), `telegram` (`bot_token`, `chat_id`) |
| `DELETE /api/org/routes/:id` | admin | remove a route |
| `GET /api/org/keys`, `POST /api/org/keys` `{role, label}`, `DELETE /api/org/keys/:id` | admin | list, create (returned once), revoke |

These responses mean:
- **401:** a missing or invalid key.
- **403:** the key's role is too small for this call.
- **404:** the id does not exist, *or* it belongs to another org. Requests cannot tell the two apart.

Create the first org and admin key:

```sh
cd apps/engine && mix chain_guard.org.create "Acme Risk" --watch 0x2718...25d3:Euler
# in a release: bin/chain_guard eval 'ChainGuard.Release.create_org("Acme Risk")'
```

## Live: Phoenix Channels at `ws://localhost:4000/socket`

| Topic | Access | Events |
|---|---|---|
| `alerts:global` | public | `alert:raised`, `alert:updated`, `alert:retracted`, `alert:finalized` |
| `live:<chain_id>` | public | `block` (with fund-flow edges), `invariants`, `scores`, `reorg`, `block:orphaned`, `integrity_halt` |
| `alerts:org:<org_id>` | `token` connect param = that org's key | the alert events above, for alerts touching the org's watchlist |

## Reports: `services/report` on `http://localhost:8800`

`GET /reports/alerts/<alert-id>.pdf` returns a compliance PDF. It contains the summary, evidence, the alert's lifecycle in the audit chain with full hashes, and an independent re-check of those hashes. From the command line: `uv run chainguard-report alert <alert-id>`.
