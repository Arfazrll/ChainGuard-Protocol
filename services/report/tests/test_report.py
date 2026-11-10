import hashlib
import io
import json
from datetime import UTC, datetime

from pypdf import PdfReader

from chainguard_report.data import ReportData, check_entries
from chainguard_report.render import ascii_only, render

GENESIS = "0" * 64
EULER_TX = "0xc310a0affe2169d1f6feec1c63dbc7f7c62a887fa48795d327d4d2da2d6b111d"


def chain(*kinds: str) -> list[dict]:
    """Entries exactly as the engine stores them: sha256 over canonical JSON incl. prev_hash."""
    out, prev = [], GENESIS
    for seq, kind in enumerate(kinds, start=1):
        body = json.dumps(
            {
                "kind": kind,
                "org_id": None,
                "payload": {"alert_id": "a1"},
                "prev_hash": prev,
                "recorded_at": f"2026-11-10T10:00:0{seq}Z",
                "seq": seq,
                "subject": "alert:a1",
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        h = hashlib.sha256(body.encode()).hexdigest()
        out.append(
            {
                "seq": seq,
                "kind": kind,
                "recorded_at": f"2026-11-10T10:00:0{seq}Z",
                "prev_hash": prev,
                "hash": h,
                "body": body,
            }
        )
        prev = h
    return out


ALERT = {
    "id": "c24d79603436c05c86f454652f0af919",
    "rule_id": "flash-loan-drain",
    "rule_version": 1,
    "lane": "rule",
    "title": "Euler Finance (main proxy) net outflow $8,904,507 in flash-loan tx 0xc310…111d",
    "severity": "critical",
    "requested_severity": "critical",
    "status": "final",
    "weakness": {"class": "flash-loan-attack", "refs": ["OWASP-SC07:2025 Flash Loan Attacks"]},
    "chain_id": 1,
    "block_number": 16817996,
    "block_hash": "0xde714b65354d54e684a95d80a1da7f668e8b2ee6ae8b5779f69ab9e04468b859",
    "tx_hashes": [EULER_TX],
    "sources": ["drpc", "publicnode"],
    "min_attestations": 2,
    "occurrences": 1,
    "notes": [],
    "evidence": [
        {
            "kind": "erc20_transfer",
            "tx_hash": EULER_TX,
            "log_index": 46,
            "block_number": 16817996,
            "value_usd": 38904507.35,
            "labels": [{"role": "from", "name": "Euler Finance (main proxy)"}],
            "attested_by": ["drpc", "publicnode"],
        }
    ],
}


def text(pdf: bytes) -> str:
    return " ".join(page.extract_text() for page in PdfReader(io.BytesIO(pdf)).pages)


def test_entries_are_rehashed_and_linked_independently():
    entries = chain("alert.raised", "alert.finalized")
    checks = check_entries(entries)
    assert [c.hash_ok for c in checks] == [True, True]
    assert [c.linked for c in checks] == [None, True]


def test_a_tampered_body_or_a_broken_link_is_caught():
    entries = chain("alert.raised", "alert.finalized")
    entries[0]["body"] = entries[0]["body"].replace("a1", "zz")
    assert [c.hash_ok for c in check_entries(entries)] == [False, True]

    entries = chain("alert.raised", "alert.finalized")
    entries[1]["prev_hash"] = "f" * 64
    checks = check_entries(entries)
    assert checks[1].linked is False and checks[1].hash_ok is False


def test_the_report_carries_evidence_lifecycle_and_a_verdict():
    data = ReportData(
        alert=ALERT,
        entries=check_entries(chain("alert.raised", "alert.finalized")),
        chain={"valid": True, "entries": 42, "head": "ab" * 32},
        head={"seq": 42, "hash": "ab" * 32},
        engine="http://localhost:4000",
    )
    pdf = render(data, generated_at=datetime(2026, 11, 10, tzinfo=UTC))
    assert pdf.startswith(b"%PDF")
    t = text(pdf)
    assert "Audit trail verified" in t
    assert "flash-loan-attack" in t and "16817996" in t
    assert "alert.finalized" in t
    assert "$38,904,507" in t
    assert "drpc, publicnode" in t
    meta = PdfReader(io.BytesIO(pdf)).metadata
    assert meta.title.startswith("ChainGuard report: Euler Finance")


def test_an_unverified_trail_is_stated_plainly():
    entries = chain("alert.raised")
    entries[0]["hash"] = "0" * 64
    data = ReportData(
        alert=ALERT,
        entries=check_entries(entries),
        chain={"valid": False, "broken_at": 7},
        head={"seq": 9, "hash": "c" * 64},
        engine="x",
        problems=["the engine reports the audit chain broken at entry 7"],
    )
    t = text(render(data))
    assert "NOT verified" in t and "broken at entry 7" in t and "FAIL" in t


def test_text_survives_the_built_in_fonts():
    assert ascii_only("0xc310…111d → Euler") == "0xc310...111d -> Euler"
