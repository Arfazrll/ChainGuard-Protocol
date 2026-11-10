# Writing detection rules

Rules are **data**, not code: one YAML file per rule in `apps/engine/priv/rules/`. The engine validates every rule at startup. A typo in a field name, an unknown operator, or a missing weakness class is rejected with a message pointing at the file. A broken rule fails loudly; it never silently stops matching.

Each rule runs in its own supervised process. If a rule crashes, only that rule restarts; the others keep running.

## Anatomy

```yaml
id: flash-loan-drain            # kebab-case, unique
version: 1
name: Protocol drained inside a flash-loan transaction
severity: critical              # info | low | medium | high | critical
weakness:                       # required: every alert maps to a weakness class
  class: flash-loan-attack
  refs: ["OWASP-SC07:2025 Flash Loan Attacks"]
description: >
  Why this matters and what it does not catch.
scope: tx                       # record | tx | window (see below)
# … scope-specific fields …
title: "{{drain.name}} net outflow {{drain.value_usd|usd}} in tx {{tx_hash|short}}"
dedup:
  key: "{{tx_hash}}"            # alerts with the same key merge instead of paging again
  window_seconds: 86400
rate_limit: { per_minute: 5 }   # beyond this, new alerts are counted and suppressed
```

## Matching records (predicates)

A predicate is a map of `field: matcher`. Every entry must hold.

| Matcher | Example |
|---|---|
| equality | `kind: approval` |
| membership | `label.to.category: [mixer, bridge]` |
| comparison | `value_usd: { gte: 1000000 }` |
| presence | `label.spender: { exists: false }` |
| big integers | `event.amount: { gte: "2^255" }` (also `uint256_max`, `"1_000_000"`) |
| combinators | `any: [...]`, `all: [...]`, `not: {...}` |

Operators: `eq ne in not_in gt gte lt lte exists`. Addresses compare case-insensitively. A missing value never satisfies a comparison.

### Fields

| Field | Meaning |
|---|---|
| `kind` | decoded event: `erc20_transfer`, `erc721_transfer`, `approval`, `flash_loan`, `swap`, `ownership_transferred`, `proxy_upgraded`, `proxy_admin_changed`, `role_granted`, `paused`, `unpaused`, `oracle_answer_updated`, `undecodable`, `unknown` |
| `event.<field>` | decoded fields, e.g. `event.from`, `event.amount`, `event.spender`, `event.provider` |
| `value_usd` | USD value when the token and price are known (never guessed) |
| `token.symbol`, `token.decimals`, `price.source`, `protocol` | enrichment |
| `label.<role>` / `label.<role>.<field>` | public label of the address in `role` (`contract`, `from`, `to`, `owner`, `spender`, `receiver`, `initiator`, …); fields `name`, `category`, `protocol` |
| `attestations` | number of independent RPC nodes that returned this record identically |
| `contract`, `tx_hash`, `log_index`, `block_number`, `block.<field>`, `chain_id` | references |

Label categories: `token stablecoin dex lending bridge mixer exchange oracle protocol other`.

## Scopes

### `record`: one alert per matching record

```yaml
scope: record
match:
  kind: [proxy_upgraded, ownership_transferred]
  label.contract: { exists: true }
```

### `tx`: correlate all records of one transaction

Every requirement must hold within the same transaction.

```yaml
scope: tx
require:
  - name: loan
    match: { kind: flash_loan }
    min_count: 1                      # optional
    sum_value_usd: { gte: 100000 }    # optional
  - name: drain
    net_outflow:                      # net USD out of one labeled party
      party_category: [lending, dex, bridge, protocol]
      gte_usd: 1000000
evidence: [loan, drain]               # which matches become alert evidence
```

`net_outflow` nets every priced token transfer in and out of each labeled party. A flash-loan lender sends the principal out and gets it back with a fee, so its net flow is positive and it never trips the rule. A drained protocol's net flow is negative. Template variables: `<name>.value_usd`, `<name>.count`, `<name>.name`, `<name>.address`, `<name>.protocol`, `<name>.first.<field>`.

### `window`: distinct counts over recent blocks

```yaml
scope: window
match: { kind: approval, event.amount: { gte: "2^255" }, label.spender: { exists: false } }
group_by: event.spender      # one counter per spender
distinct: event.owner        # count distinct owners
threshold: 8
within_blocks: 50
novel_group: true            # only spenders first seen after warm-up
warmup_blocks: 300
```

Fires once when a group reaches the threshold, and again only after it has dropped back below it. When a reorg orphans a block, its contributions are removed from the window. Template variables: `group`, `count`, `threshold`, `within_blocks`, `first.<field>`.

## Templates

`{{field}}` or `{{field|filter}}`. Filters: `usd` → `$8,904,507`, `short` → `0x2718…25d3`. Unknown values render as `?`, so a template never breaks alerting.

## What the engine adds to every alert

- **Severity gate (invariant 2):** `high`/`critical` need evidence attested by at least two independent nodes. Otherwise the alert is capped at `medium` with a note.
- **Lifecycle (invariant 3):** `provisional` until every evidence block is final, then `final`; `retracted` if a reorg orphans the evidence. Connectors are told about retractions too (PagerDuty resolves the incident).
- **Evidence:** the exact records (tx hash, log index, block hash, raw decoded event, labels, attesting nodes).

## Testing a rule

Add a positive and a negative case to `apps/engine/test/chain_guard/rules/rules_test.exs`. Better still, capture a real incident with `ingestd` (`start_block = <block>`, `--max-blocks 1`) into `apps/engine/test/fixtures/incidents/` and add a replay test. See the Euler Finance replay in `pipeline_test.exs`.
