# SvlteChain detection engine

Elixir/Phoenix/Broadway: consumes the ingestion stream, runs the YAML rules in `priv/rules/`, owns the alert lifecycle and fans out to Phoenix Channels, webhooks, PagerDuty and Telegram.

See the [root README](../../README.md), the [rule format](../../docs/rules.md) and [ADR-0002](../../docs/adr/0002-detection-engine-and-alert-lifecycle.md).

```sh
mix deps.get && mix test
CHAINGUARD_SOURCE=jsonl CHAINGUARD_JSONL_PATH=../../var/stream.jsonl mix phx.server
```
