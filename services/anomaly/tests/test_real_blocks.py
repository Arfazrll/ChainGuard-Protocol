"""The ML lane on real mainnet data.

200 consecutive blocks before the Euler Finance exploit (16,817,796 to
16,817,995, captured by ingestd from two independent providers and shrunk
with `chainguard-anomaly shrink`), then the exploit block itself, replayed
exactly as the engine would post them.
"""

from pathlib import Path

import pytest

from chainguard_anomaly import stream
from chainguard_anomaly.detector import ChainDetector

HERE = Path(__file__).parent
BASELINE = HERE / "fixtures" / "euler-pre-attack-200.jsonl.gz"
EULER = HERE.parents[2] / "apps/engine/test/fixtures/incidents/euler-finance-2023-03-13.jsonl"
EULER_TX = "0xc310a0affe2169d1f6feec1c63dbc7f7c62a887fa48795d327d4d2da2d6b111d"


@pytest.fixture(scope="module")
def replay():
    det = ChainDetector(1)
    baseline = []
    for kind, _chain, block, records in stream.read(BASELINE):
        assert kind == "block"
        baseline += det.process(block, records)["anomalies"]
    [(_, _, block, records)] = list(stream.read(EULER))
    return det, baseline, det.process(block, records)["anomalies"], block


def test_the_baseline_is_200_real_consecutive_blocks(replay):
    det, *_ = replay
    assert det.blocks_learned == 201
    nums = sorted(det.blocks_seen.values())
    assert nums[:200] == list(range(16_817_796, 16_817_996))


def test_the_euler_exploit_tx_is_flagged_with_dollar_evidence(replay):
    _, _, anomalies, block = replay
    [a] = [x for x in anomalies if x["key"] == f"tx_graph:{EULER_TX}"]
    assert block["number"] == 16_817_996
    reasons = " | ".join(a["reasons"])
    for feature in (
        "total usd $197,836,015",
        "max usd $38,904,507",
        "max protocol net out usd $8,904,507",
    ):
        assert feature in reasons
    assert "1 flash loan(s)" in reasons and "cycle" in reasons
    assert a["record_ids"], "evidence: the records behind it"


def test_ordinary_traffic_rarely_trips_the_ml_lane(replay):
    # Measured: 2 transactions out of ~15,500 in 200 blocks (a $10M exchange
    # batch while the model was still young, and a $1.6M single-protocol
    # withdrawal). Medium severity, rate-limited, never a page.
    _, baseline, _, _ = replay
    assert len(baseline) <= 3, [a["title"] for a in baseline]
