from helpers import VAULT, addr, drain_tx, event, h, label, swap_tx, transfer, vault

from chainguard_anomaly.features import _has_cycle, contract_kinds, protocol_flows, tx_graphs


def test_protocol_flows_net_out_and_in():
    tx = h("t")
    recs = [
        transfer(tx, VAULT, addr("a"), 5_000_000.0, [vault("from")]),
        transfer(tx, addr("b"), VAULT, 1_000_000.0, [vault("to")]),
        transfer(tx, VAULT, addr("c"), None, [vault("from")]),  # unpriced: never guessed
    ]
    f = protocol_flows(recs)["vault"]
    assert (f.out_usd, f.in_usd, f.net_out_usd) == (5_000_000.0, 1_000_000.0, 4_000_000.0)
    assert f.transfers == 2 and f.name == "Vault"
    assert f.top_outflow_ids() == [recs[0]["id"]]


def test_internal_transfers_and_token_labels_do_not_count():
    tx = h("t")
    v2 = label("to", addr("vault2"), "Vault 2", "lending", "vault")
    token = label("contract", addr("dai"), "Dai", "stablecoin", "maker")
    recs = [transfer(tx, VAULT, addr("vault2"), 9e6, [vault("from"), v2, token])]
    assert protocol_flows(recs) == {}


def test_cycle_detection():
    assert _has_cycle({"a": {"b"}, "b": {"c"}, "c": {"a"}})
    assert not _has_cycle({"a": {"b", "c"}, "b": {"c"}})
    assert _has_cycle({"a": {"a"}})


def test_tx_graph_shape_of_a_drain_vs_a_swap():
    drain = {g.tx: g for g in tx_graphs(drain_tx("x"))}[h("x")]
    swap = tx_graphs(swap_tx("s1", 1_000.0))[0]
    assert drain.values["flash_loans"] == 1 and drain.values["cycle"] == 1
    assert drain.values["max_protocol_net_out_usd"] == 10_000_000.0
    assert drain.values["protocols"] == 2 and drain.protocols == ["lender", "vault"]
    assert drain.record_ids[0].startswith("0x"), "flash loan first in evidence"
    assert swap.values["cycle"] == 1, "a swap returns funds to the user"
    assert swap.values["transfers"] == 2 and swap.values["flash_loans"] == 0
    assert len(drain.vector()) == len(swap.vector())


def test_contract_kinds_only_for_labeled_party_contracts():
    pool = addr("pool")
    lab = label("contract", pool, "Pool", "lending", "p")
    tok = label("contract", addr("t"), "Token", "token", None)
    out = contract_kinds(
        [event(h("1"), pool, "paused", [lab]), event(h("2"), addr("t"), "approval", [tok])]
    )
    assert [(k, n) for _, k, n, _ in out] == [("paused", "Pool")]
