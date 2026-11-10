"""chainguard-report: compliance PDFs for ChainGuard alerts.

chainguard-report alert <alert-id> [--engine URL] [-o report.pdf]
chainguard-report serve [--port 8800] [--engine URL]   # GET /reports/alerts/<id>.pdf
"""

from __future__ import annotations

import argparse
import logging
import re
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .data import EngineError, collect
from .render import render

log = logging.getLogger("chainguard_report")
ALERT_PATH = re.compile(r"^/reports/alerts/([0-9a-f]{8,64})\.pdf$")


def serve(host: str, port: int, engine: str) -> None:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            log.info("%s %s", self.address_string(), fmt % args)

        def do_GET(self):  # noqa: N802
            if self.path == "/healthz":
                return self._send(HTTPStatus.OK, b'{"ok":true}', "application/json")
            m = ALERT_PATH.match(self.path)
            if not m:
                return self._send(HTTPStatus.NOT_FOUND, b"not found", "text/plain")
            try:
                pdf = render(collect(engine, m.group(1)))
            except EngineError as e:
                return self._send(HTTPStatus.BAD_GATEWAY, str(e).encode(), "text/plain")
            self.send_response(HTTPStatus.OK)
            self.send_header("content-type", "application/pdf")
            self.send_header(
                "content-disposition",
                f'attachment; filename="chainguard-alert-{m.group(1)[:12]}.pdf"',
            )
            self.send_header("content-length", str(len(pdf)))
            self.send_header("access-control-allow-origin", "*")
            self.end_headers()
            self.wfile.write(pdf)

        def _send(self, status, body: bytes, ctype: str):
            self.send_response(status)
            self.send_header("content-type", ctype)
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    srv = ThreadingHTTPServer((host, port), Handler)
    log.info("chainguard-report on http://%s:%d (engine %s)", host, port, engine)
    srv.serve_forever()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="chainguard-report", description=__doc__)
    ap.add_argument("--engine", default="http://localhost:4000")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("alert", help="write one alert's report")
    a.add_argument("alert_id")
    a.add_argument("-o", "--out")
    s = sub.add_parser("serve", help="serve reports over HTTP")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, default=8800)
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    if args.cmd == "serve":
        serve(args.host, args.port, args.engine)
        return 0
    try:
        data = collect(args.engine, args.alert_id)
    except EngineError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    out = args.out or f"chainguard-alert-{args.alert_id[:12]}.pdf"
    with open(out, "wb") as f:
        f.write(render(data))
    status = "verified" if not data.problems else "NOT verified: " + "; ".join(data.problems)
    print(f"wrote {out} ({len(data.entries)} audit entries, trail {status})")
    return 0 if not data.problems else 1


if __name__ == "__main__":
    sys.exit(main())
