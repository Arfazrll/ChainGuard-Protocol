"""Writes apps/landing/src/lib/data/ml-scores.json from the real-data replay.

Scores are online: each transaction is scored by the model as it stood when
its block arrived (only once the model was fitted), exactly as in production.
Run: uv run python scripts/landing_scores.py
"""

import json
from pathlib import Path

import numpy as np

from chainguard_anomaly import stream
from chainguard_anomaly.detector import ChainDetector
from chainguard_anomaly.features import tx_graphs

ROOT = Path(__file__).resolve().parents[3]
BASELINE = ROOT / "services/anomaly/tests/fixtures/euler-pre-attack-200.jsonl.gz"
EULER = ROOT / "apps/engine/test/fixtures/incidents/euler-finance-2023-03-13.jsonl"
OUT = ROOT / "apps/landing/src/lib/data/ml-scores.json"
EULER_TX = "0xc310a0affe2169d1f6feec1c63dbc7f7c62a887fa48795d327d4d2da2d6b111d"

det = ChainDetector(1)
scores: list[float] = []
flagged = 0
for _, _, block, records in stream.read(BASELINE):
    gs = tx_graphs(records)
    if det.forest is not None and gs:
        scores += det.graph_scores(np.vstack([g.vector() for g in gs])).tolist()
    flagged += sum(a["kind"] == "tx_graph" for a in det.process(block, records)["anomalies"])

[(_, _, block, records)] = list(stream.read(EULER))
g = next(g for g in tx_graphs(records) if g.tx == EULER_TX)
euler = float(det.graph_scores(g.vector()[None, :])[0])
threshold = float(det.forest_threshold)

lo, hi = 0.30, max(euler, max(scores)) + 0.02
edges = np.linspace(lo, hi, 41)
counts, _ = np.histogram(np.clip(scores, lo, hi), bins=edges)
OUT.write_text(
    json.dumps(
        {
            "source": "services/anomaly/scripts/landing_scores.py",
            "blocks": 200,
            "txs_scored": len(scores),
            "threshold": round(threshold, 4),
            "flagged_baseline": flagged,
            "bins": [
                {"x0": round(float(a), 4), "x1": round(float(b), 4), "n": int(n)}
                for a, b, n in zip(edges[:-1], edges[1:], counts, strict=True)
            ],
            "highlight": {"score": round(euler, 4), "label": "Euler exploit tx"},
        },
        indent=1,
    )
    + "\n"
)
print(
    f"{len(scores)} txs scored, threshold {threshold:.3f}, euler {euler:.3f}, "
    f"baseline flagged {flagged}"
)
