# chainguard-anomaly: the ML lane

A Python service that learns what normal looks like on a chain and flags what does not. The detection engine (`apps/engine`, `ChainGuard.Anomaly`) posts every completed block to it **asynchronously**: rules and invariants never wait for it, and if it is down the engine skips blocks and reports the lane as `degraded`.

ML alerts are **capped at medium** (novel patterns: low). The cap is enforced in the engine, not trusted from this service. An anomaly is a statistical signal that asks a human to look; it never pages on its own.

## Models

All three learn online and are **reorg-aware**: every observation is keyed by the block hash it came from, and `POST /v1/orphan` unlearns a reorged block. Blocks are scored *before* they are learned, and anomalous observations are kept out of training, so an attack never teaches the model that attacks are normal.

| Model | Learns | Flags |
|---|---|---|
| Protocol flow baseline | per labeled protocol, its net USD outflow in blocks where it was active (rolling 2,000) | a material net outflow (≥ $1M) with robust z ≥ 6 on a log scale (median/MAD), after 20 active blocks |
| Fund-flow graph (IsolationForest) | the shape of every token-moving transaction: transfers, addresses, tokens, USD moved, largest transfer, flash loans, swaps, protocols, fan-in/out, cycles, largest protocol net outflow | a top-0.5% score **and** at least one feature beyond the 99.9th percentile of normal **and** ≥ $250K moved; the alert lists those features |
| Novel patterns | which event kinds each labeled contract emits | the first time a contract emits a kind, after 300 blocks of warm-up |

## Run

```sh
uv sync
uv run chainguard-anomaly serve --port 8700          # then start the engine with
                                                     # CHAINGUARD_ANOMALY_URL=http://127.0.0.1:8700
uv run chainguard-anomaly replay capture.jsonl       # score an ingestd capture offline
uv run pytest
```

API: `POST /v1/blocks`, `POST /v1/orphan`, `GET /v1/model`, `GET /healthz` (see `server.py`). The service holds no keys and never talks to a node; it only sees what the engine sends. Bind it to a private interface.

## Evaluation on real data

`tests/test_real_blocks.py` replays **200 consecutive mainnet blocks before the Euler exploit** (16,817,796–16,817,995, captured by ingestd from two providers), then the exploit block. The test fixture `tests/fixtures/euler-pre-attack-200.jsonl.gz` is shrunk by `chainguard-anomaly shrink`: addresses and hashes become short stable aliases, and every feature the models compute is unchanged.

See the measured results in the main README.
