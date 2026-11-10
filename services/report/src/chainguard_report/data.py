"""Collecting a report's inputs from the engine and checking them independently.

A report does not take the engine's word for the audit trail: every audit
entry it includes is re-hashed here (sha256 of the stored canonical body)
and its link to the previous entry is checked, using only the bytes the
engine returned.
"""

from __future__ import annotations

import hashlib
import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field


class EngineError(RuntimeError):
    pass


def _get(engine: str, path: str, ok=(200,)) -> dict:
    url = engine.rstrip("/") + path
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code in ok:
            return json.loads(e.read())
        raise EngineError(f"{url}: HTTP {e.code}") from e
    except urllib.error.URLError as e:
        raise EngineError(f"{url}: {e.reason}") from e


@dataclass
class EntryCheck:
    seq: int
    kind: str
    recorded_at: str
    hash: str
    prev_hash: str
    hash_ok: bool
    linked: bool | None  # None: previous entry not included in this report


@dataclass
class ReportData:
    alert: dict
    entries: list[EntryCheck]
    chain: dict  # /api/audit/verify result
    head: dict  # /api/audit/head
    engine: str
    problems: list[str] = field(default_factory=list)

    @property
    def entries_ok(self) -> bool:
        return all(e.hash_ok and e.linked is not False for e in self.entries)


def check_entries(raw: list[dict]) -> list[EntryCheck]:
    """Re-derive each entry's hash and check links between consecutive entries."""
    by_seq = {e["seq"]: e for e in raw}
    out = []
    for e in sorted(raw, key=lambda x: x["seq"]):
        body = e["body"]
        hash_ok = hashlib.sha256(body.encode()).hexdigest() == e["hash"]
        try:
            decoded = json.loads(body)
            hash_ok = hash_ok and decoded.get("prev_hash") == e["prev_hash"]
        except json.JSONDecodeError:
            hash_ok = False
        prev = by_seq.get(e["seq"] - 1)
        out.append(
            EntryCheck(
                seq=e["seq"],
                kind=e["kind"],
                recorded_at=e["recorded_at"],
                hash=e["hash"],
                prev_hash=e["prev_hash"],
                hash_ok=hash_ok,
                linked=None if prev is None else prev["hash"] == e["prev_hash"],
            )
        )
    return out


def collect(engine: str, alert_id: str) -> ReportData:
    alert = _get(engine, f"/api/alerts/{urllib.parse.quote(alert_id)}")
    subject = urllib.parse.quote(f"alert:{alert_id}")
    raw = _get(engine, f"/api/audit?subject={subject}&limit=200")["entries"]
    chain = _get(engine, "/api/audit/verify", ok=(200, 409))
    head = _get(engine, "/api/audit/head")
    data = ReportData(
        alert=alert, entries=check_entries(raw), chain=chain, head=head, engine=engine
    )
    if not raw:
        data.problems.append("no audit entries found for this alert")
    if not data.entries_ok:
        data.problems.append("an audit entry in this report failed its independent hash check")
    if not chain.get("valid"):
        data.problems.append(
            f"the engine reports the audit chain broken at entry {chain.get('broken_at')}"
        )
    return data
