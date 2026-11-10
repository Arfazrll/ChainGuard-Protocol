"""Rendering a compliance report PDF (reportlab, built-in fonts only).

Layout: summary, verdict on the audit trail, evidence, lifecycle (from the
audit chain), notes, and a methodology section that says exactly what was
checked. Every hash is printed in full so a reader can re-verify by hand.
"""

from __future__ import annotations

import hashlib
import io
import json
from datetime import UTC, datetime

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (
    KeepTogether,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

from .data import ReportData

INK = colors.HexColor("#1b1b1f")
MUTED = colors.HexColor("#5f5e5a")
HAIR = colors.HexColor("#d8d7d1")
BRAND = colors.HexColor("#4a3aa7")
OK = colors.HexColor("#0b7a50")
BAD = colors.HexColor("#b42318")
SEV = {
    "critical": colors.HexColor("#b42318"),
    "high": colors.HexColor("#c4501b"),
    "medium": colors.HexColor("#9a6700"),
    "low": MUTED,
    "info": MUTED,
}

_ss = getSampleStyleSheet()
H1 = ParagraphStyle(
    "h1",
    parent=_ss["Title"],
    fontName="Helvetica-Bold",
    fontSize=17,
    leading=21,
    alignment=0,
    textColor=INK,
    spaceAfter=4,
)
H2 = ParagraphStyle(
    "h2",
    parent=_ss["Heading2"],
    fontName="Helvetica-Bold",
    fontSize=11.5,
    leading=14,
    textColor=INK,
    spaceBefore=12,
    spaceAfter=6,
)
BODY = ParagraphStyle(
    "body", parent=_ss["BodyText"], fontName="Helvetica", fontSize=9, leading=12.5, textColor=INK
)
SMALL = ParagraphStyle("small", parent=BODY, fontSize=7.8, leading=10, textColor=MUTED)
MONO = ParagraphStyle("mono", parent=BODY, fontName="Courier", fontSize=7.4, leading=9.4)
CELL = ParagraphStyle("cell", parent=BODY, fontSize=8, leading=10)


def esc(v) -> str:
    """Escape for reportlab markup; on-chain strings are untrusted."""
    s = "" if v is None else str(v)
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def ascii_only(s: str) -> str:
    """Built-in fonts lack some glyphs (ellipsis, arrows): keep text renderable."""
    return (
        s.replace("…", "...")
        .replace("→", "->")
        .replace("—", "-")
        .replace("–", "-")
        .encode("latin-1", "replace")
        .decode("latin-1")
    )


def p(text, style=BODY):
    return Paragraph(ascii_only(text), style)


def _kv_table(rows: list[tuple[str, str]], widths=(38 * mm, 132 * mm)) -> Table:
    t = Table([[p(f"<b>{esc(k)}</b>", CELL), p(v, CELL)] for k, v in rows], colWidths=widths)
    t.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LINEBELOW", (0, 0), (-1, -1), 0.4, HAIR),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
            ]
        )
    )
    return t


def _grid(header: list[str], rows: list[list], widths) -> Table:
    data = [[p(f"<b>{esc(h)}</b>", CELL) for h in header]] + rows
    t = Table(data, colWidths=widths, repeatRows=1)
    t.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LINEBELOW", (0, 0), (-1, 0), 0.8, INK),
                ("LINEBELOW", (0, 1), (-1, -1), 0.3, HAIR),
                ("TOPPADDING", (0, 0), (-1, -1), 2.5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2.5),
            ]
        )
    )
    return t


def digest(data: ReportData) -> str:
    """A fingerprint of the report's inputs: same inputs, same digest."""
    material = json.dumps(
        {"alert": data.alert, "entries": [e.hash for e in data.entries], "head": data.head},
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(material.encode()).hexdigest()


def render(data: ReportData, generated_at: datetime | None = None) -> bytes:
    a = data.alert
    generated_at = generated_at or datetime.now(UTC)
    fingerprint = digest(data)
    buf = io.BytesIO()

    def footer(canvas, doc):
        canvas.saveState()
        canvas.setFont("Helvetica", 7)
        canvas.setFillColor(MUTED)
        canvas.drawString(18 * mm, 10 * mm, f"ChainGuard compliance report - alert {a.get('id')}")
        canvas.drawRightString(
            192 * mm, 10 * mm, f"page {doc.page} - inputs sha256 {fingerprint[:16]}"
        )
        canvas.restoreState()

    doc = SimpleDocTemplate(
        buf,
        pagesize=A4,
        leftMargin=18 * mm,
        rightMargin=18 * mm,
        topMargin=16 * mm,
        bottomMargin=18 * mm,
        title=ascii_only(f"ChainGuard report: {a.get('title', '')}"),
        author="ChainGuard",
        subject=f"Alert {a.get('id')}",
    )

    sev = a.get("severity", "info")
    story = [
        p("ChainGuard compliance report", SMALL),
        p(esc(a.get("title", "")), H1),
        p(
            f'<font color="{SEV.get(sev, MUTED).hexval()}"><b>{esc(sev).upper()}</b></font>'
            f" &nbsp; lane {esc(a.get('lane'))} &nbsp; status <b>{esc(a.get('status'))}</b>"
            f" &nbsp; generated {generated_at.strftime('%Y-%m-%d %H:%M:%S UTC')}",
            BODY,
        ),
        Spacer(1, 6),
    ]

    # --- verdict ---------------------------------------------------------------
    chain_ok = bool(data.chain.get("valid"))
    verdict_ok = chain_ok and data.entries_ok and not data.problems
    color = OK if verdict_ok else BAD
    verdict = (
        "Audit trail verified. Every entry below re-hashes to its recorded hash, and the "
        f"engine re-derived the full chain of {data.chain.get('entries')} entries without a break."
        if verdict_ok
        else "Audit trail NOT verified: " + "; ".join(esc(x) for x in data.problems)
    )
    v = Table(
        [[p(f'<font color="{color.hexval()}"><b>{verdict}</b></font>', BODY)]], colWidths=[174 * mm]
    )
    v.setStyle(
        TableStyle(
            [
                ("BOX", (0, 0), (-1, -1), 0.8, color),
                ("TOPPADDING", (0, 0), (-1, -1), 6),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
            ]
        )
    )
    story += [v]

    # --- summary ---------------------------------------------------------------------
    weakness = a.get("weakness") or {}
    story += [
        p("Summary", H2),
        _kv_table(
            [
                ("Alert id", f'<font name="Courier">{esc(a.get("id"))}</font>'),
                ("Rule", f"{esc(a.get('rule_id'))} v{esc(a.get('rule_version'))}"),
                (
                    "Weakness class",
                    esc(weakness.get("class"))
                    + (
                        f" ({esc(', '.join(weakness.get('refs') or []))})"
                        if weakness.get("refs")
                        else ""
                    ),
                ),
                ("Severity", f"{esc(sev)} (requested {esc(a.get('requested_severity'))})"),
                (
                    "Chain / block",
                    f"chain {esc(a.get('chain_id'))}, block {esc(a.get('block_number'))}",
                ),
                ("Block hash", f'<font name="Courier">{esc(a.get("block_hash"))}</font>'),
                (
                    "Transactions",
                    "<br/>".join(
                        f'<font name="Courier">{esc(t)}</font>' for t in a.get("tx_hashes") or []
                    ),
                ),
                (
                    "Attested by",
                    f"{esc(', '.join(a.get('sources') or []))} (minimum {esc(a.get('min_attestations'))} independent nodes per evidence record)",
                ),
                ("Occurrences", esc(a.get("occurrences"))),
            ]
        ),
    ]

    # --- evidence ----------------------------------------------------------------------
    ev_rows = []
    for e in a.get("evidence") or []:
        labels = ", ".join(
            f"{lab.get('role')}: {lab.get('name')}"
            for lab in e.get("labels") or []
            if lab.get("role") != "contract"
        )
        usd = e.get("value_usd")
        ev_rows.append(
            [
                p(esc(e.get("kind")), CELL),
                p(
                    f'<font name="Courier" size="6.6">{esc(e.get("tx_hash"))}</font><br/>log {esc(e.get("log_index"))}, block {esc(e.get("block_number"))}',
                    CELL,
                ),
                p("" if usd is None else f"${usd:,.0f}", CELL),
                p(esc(labels) or "-", CELL),
                p(str(len(e.get("attested_by") or [])), CELL),
            ]
        )
    story += [
        p("Evidence", H2),
        p(
            "The exact on-chain records behind the alert. Each was returned identically by the listed number of independent RPC nodes.",
            SMALL,
        ),
        Spacer(1, 3),
        _grid(
            ["Event", "Transaction / position", "USD", "Parties", "Nodes"],
            ev_rows or [[p("-", CELL)] * 5],
            [24 * mm, 72 * mm, 22 * mm, 44 * mm, 12 * mm],
        ),
    ]

    # --- lifecycle from the audit chain -----------------------------------------------------
    rows = [
        [
            p(str(e.seq), CELL),
            p(esc(e.kind), CELL),
            p(esc(e.recorded_at), CELL),
            p(
                f'<font name="Courier" size="6.4">{esc(e.hash)}<br/>prev {esc(e.prev_hash)}</font>',
                CELL,
            ),
            p(
                ("ok" if e.hash_ok else "FAIL")
                + ("" if e.linked is None else (", linked" if e.linked else ", LINK BROKEN")),
                CELL,
            ),
        ]
        for e in data.entries
    ]
    story += [
        p("Lifecycle in the audit chain", H2),
        p(
            "Append-only entries recorded by the engine for this alert, oldest first. The last column is this report's own re-check of each entry.",
            SMALL,
        ),
        Spacer(1, 3),
        _grid(
            ["Seq", "Event", "Recorded at (UTC)", "Hash / previous hash (sha256)", "Check"],
            rows or [[p("-", CELL)] * 5],
            [11 * mm, 24 * mm, 33 * mm, 88 * mm, 18 * mm],
        ),
    ]

    if a.get("notes"):
        story += [p("Notes", H2)] + [p("- " + esc(n), BODY) for n in a["notes"]]

    head = data.head
    story += [
        KeepTogether(
            [
                p("Method", H2),
                p(
                    "ChainGuard is read-only: it holds no keys and never sends transactions. Evidence is "
                    "accepted only when a strict majority of at least two independent RPC nodes return it "
                    "identically. Alerts stay provisional until their blocks are final and are retracted if "
                    "a reorg orphans their evidence.",
                    BODY,
                ),
                Spacer(1, 4),
                p(
                    "Each audit entry's hash is sha256 over its canonical JSON body, which includes the "
                    "previous entry's hash. This report recomputed those hashes from the stored bodies. To "
                    "anchor the chain, record the head below in an external system; any later rewrite of "
                    "the history before it becomes detectable.",
                    BODY,
                ),
                Spacer(1, 4),
                _kv_table(
                    [
                        (
                            "Chain head",
                            f'seq {esc(head.get("seq"))}: <font name="Courier" size="7">{esc(head.get("hash"))}</font>',
                        ),
                        ("Engine", esc(data.engine)),
                        ("Inputs digest", f'<font name="Courier" size="7">{fingerprint}</font>'),
                    ]
                ),
            ]
        )
    ]

    doc.build(story, onFirstPage=footer, onLaterPages=footer)
    return buf.getvalue()
