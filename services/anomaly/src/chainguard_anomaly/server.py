"""HTTP API for the engine. Standard library only: no web framework to patch.

``POST /v1/blocks``  ``{"chain_id", "block": {"number", "hash", "timestamp"}, "records": [...]}``
    Score one completed block, then learn from it. Returns ``{"anomalies", "model"}``.
``POST /v1/orphan``  ``{"chain_id", "block_hash"}``
    A reorg orphaned this block: unlearn it.
``GET  /v1/model``   Model state per chain.
``GET  /healthz``    Liveness.

The service is read-only with respect to chains: it never talks to a node,
holds no key and only ever sees what the engine sends it. Bind it to a
private interface; it is an internal service, not a public API.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .detector import Detector

log = logging.getLogger("chainguard_anomaly")

MAX_BODY = 16 * 1024 * 1024


class _Handler(BaseHTTPRequestHandler):
    server: AnomalyServer  # type: ignore[assignment]
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # route access logs through logging
        log.debug("%s %s", self.address_string(), fmt % args)

    def _send(self, status: int, body: dict) -> None:
        data = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self) -> dict | None:
        try:
            n = int(self.headers.get("content-length") or 0)
        except ValueError:
            n = -1
        if n < 0 or n > MAX_BODY:
            self._send(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "body too large"})
            return None
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError as e:
            self._send(HTTPStatus.BAD_REQUEST, {"error": f"invalid JSON: {e}"})
            return None
        if not isinstance(body, dict):
            self._send(HTTPStatus.BAD_REQUEST, {"error": "expected a JSON object"})
            return None
        return body

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/healthz":
            self._send(HTTPStatus.OK, {"ok": True})
        elif self.path == "/v1/model":
            with self.server.lock:
                self._send(HTTPStatus.OK, {"chains": self.server.detector.summary()})
        else:
            self._send(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        body = self._body()
        if body is None:
            return
        chain_id = body.get("chain_id")
        if not isinstance(chain_id, int):
            self._send(HTTPStatus.BAD_REQUEST, {"error": "chain_id must be an integer"})
            return
        if self.path == "/v1/blocks":
            block, records = body.get("block"), body.get("records")
            if not isinstance(block, dict) or not isinstance(records, list):
                self._send(
                    HTTPStatus.BAD_REQUEST, {"error": "need block (object) and records (list)"}
                )
                return
            started = time.perf_counter()
            with self.server.lock:
                result = self.server.detector.process(chain_id, block, records)
            result["elapsed_ms"] = round((time.perf_counter() - started) * 1000, 1)
            for a in result["anomalies"]:
                log.info("anomaly %s block=%s %s", a["kind"], block.get("number"), a["title"])
            self._send(HTTPStatus.OK, result)
        elif self.path == "/v1/orphan":
            with self.server.lock:
                found = self.server.detector.orphan(chain_id, str(body.get("block_hash") or ""))
            self._send(HTTPStatus.OK, {"unlearned": found})
        else:
            self._send(HTTPStatus.NOT_FOUND, {"error": "not found"})


class AnomalyServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, addr: tuple[str, int], detector: Detector | None = None) -> None:
        super().__init__(addr, _Handler)
        self.detector = detector or Detector()
        # One lock: model updates are ordered, and the engine sends one block at a time.
        self.lock = threading.Lock()


def serve(host: str, port: int, detector: Detector | None = None) -> None:
    srv = AnomalyServer((host, port), detector)
    log.info("chainguard-anomaly listening on http://%s:%d", host, port)
    try:
        srv.serve_forever()
    finally:
        srv.server_close()
