"""chainguard-anomaly: serve | replay | shrink."""

from __future__ import annotations

import argparse
import gzip
import json
import logging
import sys
import time

from . import stream
from .detector import Detector
from .server import serve


def _replay(paths: list[str], quiet: bool) -> int:
    det = Detector()
    blocks = anomalies = 0
    by_kind: dict[str, int] = {}
    started = time.perf_counter()
    for path in paths:
        for kind, chain_id, block, records in stream.read(path):
            if kind == "orphan":
                det.orphan(chain_id, block["hash"])
                continue
            res = det.process(chain_id, block, records)
            blocks += 1
            for a in res["anomalies"]:
                anomalies += 1
                by_kind[a["kind"]] = by_kind.get(a["kind"], 0) + 1
                if not quiet:
                    print(f"#{block['number']} {a['kind']:<14} {a['title']}")
                    for r in a["reasons"]:
                        print(f"    - {r}")
    elapsed = time.perf_counter() - started
    print(
        json.dumps(
            {
                "blocks": blocks,
                "anomalies": anomalies,
                "by_kind": by_kind,
                "seconds": round(elapsed, 2),
                "model": det.summary(),
            },
            indent=2,
        )
    )
    return 0


def _shrink(src: str, dst: str) -> int:
    n = 0
    with gzip.open(dst, "wt", encoding="utf-8") as out:
        for kind, chain_id, block, records in stream.read(src):
            if kind != "block":
                continue
            b, rs = stream.shrink(block, records)
            out.write(
                json.dumps({"chain_id": chain_id, "block": b, "records": rs}, separators=(",", ":"))
            )
            out.write("\n")
            n += 1
    print(f"wrote {n} blocks to {dst}", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="chainguard-anomaly", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve", help="run the HTTP service the engine calls")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, default=8700)
    r = sub.add_parser("replay", help="score ingestd or compact JSONL files offline")
    r.add_argument("paths", nargs="+")
    r.add_argument("-q", "--quiet", action="store_true")
    k = sub.add_parser("shrink", help="ingestd JSONL -> small structure-preserving test fixture")
    k.add_argument("src")
    k.add_argument("dst")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if args.cmd == "serve":
        serve(args.host, args.port)
        return 0
    if args.cmd == "replay":
        return _replay(args.paths, args.quiet)
    return _shrink(args.src, args.dst)


if __name__ == "__main__":
    sys.exit(main())
