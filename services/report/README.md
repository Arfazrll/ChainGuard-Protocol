# chainguard-report

Compliance-ready PDF reports for ChainGuard alerts.

A report contains:
- the alert summary (rule, weakness class, severity, block and transactions);
- the exact on-chain evidence and how many independent nodes attested each record;
- the alert's lifecycle as recorded in the tamper-evident audit chain, with full hashes;
- a verdict on the trail and the method used.

The report does not take the engine's word for the audit trail. It re-hashes every entry it includes (sha256 of the stored canonical body) and checks each link to the previous entry itself. If anything fails, the first page says so in red.

```sh
uv sync
uv run chainguard-report alert <alert-id> --engine http://localhost:4000 -o report.pdf
uv run chainguard-report serve --port 8800      # GET /reports/alerts/<alert-id>.pdf
uv run pytest
```

Uses reportlab with the built-in fonts, so it needs no font files. Text from the chain is escaped before rendering.
