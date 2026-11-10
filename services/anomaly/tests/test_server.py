import json
import threading
import urllib.error
import urllib.request

import pytest
from helpers import block, swap_tx

from chainguard_anomaly.server import AnomalyServer


@pytest.fixture
def base_url():
    srv = AnomalyServer(("127.0.0.1", 0))
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()
    srv.server_close()


def call(url: str, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def test_health_score_orphan_and_model(base_url):
    assert call(base_url + "/healthz") == (200, {"ok": True})
    b = block(1)
    st, res = call(
        base_url + "/v1/blocks", {"chain_id": 1, "block": b, "records": swap_tx("a", 10.0)}
    )
    assert st == 200 and res["anomalies"] == [] and res["duplicate"] is False
    assert res["model"]["blocks_learned"] == 1
    st, res = call(base_url + "/v1/blocks", {"chain_id": 1, "block": b, "records": []})
    assert res["duplicate"] is True
    assert call(base_url + "/v1/orphan", {"chain_id": 1, "block_hash": b["hash"]}) == (
        200,
        {"unlearned": True},
    )
    st, res = call(base_url + "/v1/model")
    assert res["chains"]["1"]["blocks_learned"] == 0


def test_bad_requests_are_rejected(base_url):
    assert call(base_url + "/v1/blocks", {"block": {}, "records": []})[0] == 400
    assert call(base_url + "/v1/blocks", {"chain_id": 1, "block": {}})[0] == 400
    assert call(base_url + "/nope")[0] == 404
