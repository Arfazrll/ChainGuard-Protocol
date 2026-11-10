import random

from helpers import VAULT, addr, block, drain_tx, event, h, label, swap_tx, transfer, vault

from chainguard_anomaly.detector import ChainDetector, Settings

FAST = Settings(
    graph_min_train=300,
    graph_refit_every=5,
    graph_trees=50,
    novelty_warmup_blocks=20,
    flow_min_obs=20,
)


def normal_block(n: int, rng: random.Random) -> list[dict]:
    recs = []
    for i in range(rng.randint(15, 30)):
        recs += swap_tx(f"{n}-{i}", rng.lognormvariate(8, 1.5))
    # The vault is active with ordinary withdrawals and deposits.
    tx = h(f"vault-{n}")
    recs.append(transfer(tx, VAULT, addr(f"user{n}"), rng.lognormvariate(10, 0.8), [vault("from")]))
    recs.append(transfer(tx, addr(f"dep{n}"), VAULT, rng.lognormvariate(10, 0.8), [vault("to")]))
    return recs


def warmed(blocks: int = 60, settings: Settings = FAST) -> tuple[ChainDetector, random.Random]:
    det, rng = ChainDetector(1, settings), random.Random(7)
    for n in range(1, blocks + 1):
        det.process(block(n), normal_block(n, rng))
    return det, rng


def test_normal_traffic_raises_nothing_after_warm_up():
    det, rng = warmed()
    raised = [
        a for n in range(61, 101) for a in det.process(block(n), normal_block(n, rng))["anomalies"]
    ]
    assert raised == []
    assert det.summary()["graph_model"] == "fitted"


def test_a_drain_is_flagged_by_both_flow_and_graph_models_with_evidence():
    det, rng = warmed()
    recs = normal_block(61, rng) + drain_tx("attack")
    res = det.process(block(61), recs)
    kinds = {a["kind"]: a for a in res["anomalies"]}
    assert {"protocol_flow", "tx_graph"} <= set(kinds)
    # The lender's first-ever flash loan after warm-up is a novel pattern too.
    assert kinds["novel_pattern"]["title"].startswith("First flash_loan event from Lender")

    flow = kinds["protocol_flow"]
    assert flow["key"] == "protocol_flow:vault"
    assert flow["score"] >= FAST.flow_z
    assert flow["title"].startswith("Vault net outflow $")
    ids = {r["id"] for r in recs}
    assert flow["record_ids"] and set(flow["record_ids"]) <= ids

    graph = kinds["tx_graph"]
    assert graph["key"] == f"tx_graph:{h('attack')}"
    assert any("flash loan" in r for r in graph["reasons"])
    assert set(graph["record_ids"]) <= ids


def test_anomalies_are_not_learned_as_normal():
    det, rng = warmed()
    before = len(det.flows["vault"].obs)
    det.process(block(61), drain_tx("attack"))
    assert len(det.flows["vault"].obs) == before
    # The same attack shape is still anomalous next time.
    assert det.process(block(62), drain_tx("again"))["anomalies"]


def test_warming_up_protocols_are_not_scored():
    det = ChainDetector(1, FAST)
    res = det.process(block(1), drain_tx("early"))
    assert res["anomalies"] == []
    assert det.summary()["graph_model"] == "warming_up"


def test_reorg_unlearns_the_orphaned_block_and_duplicates_are_ignored():
    det, rng = warmed(30)
    b = block(31)
    det.process(b, normal_block(31, rng))
    obs = len(det.flows["vault"].obs)
    assert det.process(b, normal_block(31, rng))["duplicate"] is True
    assert len(det.flows["vault"].obs) == obs, "a redelivered block is not learned twice"

    assert det.orphan(b["hash"]) is True
    assert len(det.flows["vault"].obs) == obs - 1
    assert all(bh != b["hash"] for bh, _ in det.graph_buf)
    assert det.orphan(b["hash"]) is False
    # The canonical replacement is learned normally.
    assert det.process(block(31, "canonical"), normal_block(31, rng))["duplicate"] is False


def test_novel_event_kind_after_warm_up_and_reorg_resets_novelty():
    det, rng = warmed(25)
    pool = addr("pool-x")
    lab = label("contract", pool, "Pool X", "lending", "px")
    b = block(26)
    res = det.process(b, normal_block(26, rng) + [event(h("p"), pool, "proxy_upgraded", [lab])])
    [a] = [x for x in res["anomalies"] if x["kind"] == "novel_pattern"]
    assert a["title"] == "First proxy_upgraded event from Pool X in 25 blocks observed"
    # Seen once: not novel again...
    assert not det.process(block(27), [event(h("q"), pool, "proxy_upgraded", [lab])])["anomalies"]
    # ...unless the block it was first seen in is orphaned.
    det.orphan(b["hash"])
    det.orphan(block(27)["hash"])
    res = det.process(block(26, "c"), [event(h("r"), pool, "proxy_upgraded", [lab])])
    assert [x["kind"] for x in res["anomalies"]] == ["novel_pattern"]
