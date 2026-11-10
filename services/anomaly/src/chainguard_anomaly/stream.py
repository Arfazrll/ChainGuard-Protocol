"""Reading block streams for offline replay and evaluation.

Two input formats:

* ``ingestd`` JSONL (the engine's input): ``block_adopted`` followed by its
  ``upsert`` records, plus ``block_orphaned``. Blocks are assembled exactly
  as the engine assembles them, and records are compacted the way the engine
  compacts them before posting.
* Compact JSONL (optionally gzipped), one block per line:
  ``{"chain_id", "block", "records"}``: what the engine posts.
"""

from __future__ import annotations

import gzip
import hashlib
import json
from collections.abc import Iterator
from pathlib import Path

SKIP_KINDS = {"unknown", "undecodable"}


def compact(record: dict) -> dict:
    """Same shape as ``ChainGuard.Anomaly.compact/1`` in the engine."""
    enr = record.get("enrichment") or {}
    event = dict(record.get("event") or {})
    kind = event.pop("kind", None)
    return {
        "id": record.get("id"),
        "tx": record.get("tx_hash"),
        "log": record.get("log_index"),
        "contract": record.get("contract"),
        "kind": kind,
        "event": event,
        "value_usd": enr.get("value_usd"),
        "token": (enr.get("token") or {}).get("symbol"),
        "labels": [
            {k: lab.get(k) for k in ("role", "address", "name", "category", "protocol")}
            for lab in enr.get("labels") or ()
        ],
    }


Event = tuple[str, int, dict, list[dict]]  # ("block" | "orphan", chain_id, block, records)


def _open(path: Path):
    return (
        gzip.open(path, "rt", encoding="utf-8")
        if path.suffix == ".gz"
        else path.open(encoding="utf-8")
    )


def read(path: str | Path) -> Iterator[Event]:
    path = Path(path)
    pending: dict | None = None

    def flush():
        nonlocal pending
        if pending is not None:
            p, pending = pending, None
            return ("block", p["chain_id"], p["block"], p["records"])
        return None

    with _open(path) as fh:
        for line in fh:
            if not line.strip():
                continue
            m = json.loads(line)
            t = m.get("type")
            if t is None and "records" in m:  # compact format
                yield ("block", m["chain_id"], m["block"], m["records"])
            elif t == "block_adopted":
                if ev := flush():
                    yield ev
                b = m["block"]
                pending = {
                    "chain_id": m["chain_id"],
                    "block": {k: b.get(k) for k in ("number", "hash", "timestamp")},
                    "records": [],
                    "expected": m.get("record_count"),
                }
                if pending["expected"] == 0 and (ev := flush()):
                    yield ev
            elif t == "upsert" and pending is not None:
                r = m["record"]
                if (r.get("event") or {}).get("kind") not in SKIP_KINDS:
                    pending["records"].append(compact(r))
                pending["expected"] = (pending["expected"] or 0) - 1
                if pending["expected"] == 0 and (ev := flush()):
                    yield ev
            elif t == "block_orphaned":
                if ev := flush():
                    yield ev
                yield ("orphan", m["chain_id"], m["block"], [])
    if ev := flush():
        yield ev


def _h(s: str | None, n: int) -> str | None:
    """Stable short alias: keeps graph identity, drops 40+ hex digits of entropy."""
    if not s:
        return s
    return "0x" + hashlib.blake2b(s.lower().encode(), digest_size=n // 2).hexdigest()


def shrink(block: dict, records: list[dict]) -> tuple[dict, list[dict]]:
    """Structure-preserving reduction of a compact block, for test fixtures.

    Addresses, tx hashes and record ids are replaced by short stable aliases
    (labeled addresses keep their labels), and event fields the models do not
    read are dropped. Every feature the detector computes is unchanged.
    """
    out = []
    for r in records:
        ev = r.get("event") or {}
        out.append(
            {
                "id": _h(r["id"], 12),
                "tx": _h(r.get("tx"), 12),
                "contract": _h(r.get("contract"), 10),
                "kind": r.get("kind"),
                "event": {k: _h(ev.get(k), 10) for k in ("from", "to") if ev.get(k)},
                "value_usd": r.get("value_usd"),
                "labels": [
                    {
                        **{k: lab.get(k) for k in ("role", "name", "category", "protocol")},
                        "address": _h(lab.get("address"), 10),
                    }
                    for lab in r.get("labels") or ()
                ],
            }
        )
    return {k: block.get(k) for k in ("number", "hash", "timestamp")}, out
