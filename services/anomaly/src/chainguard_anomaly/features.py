"""Feature extraction from one block of compact records.

The engine posts every completed block as compact records (see
``ChainGuard.Anomaly.compact/1``)::

    {"id", "tx", "log", "contract", "kind", "event", "value_usd", "token", "labels"}

Two views are derived here, both pure:

* :func:`protocol_flows`: per labeled protocol, the USD that left and entered
  its contracts in this block (the volume-spike view).
* :func:`tx_graphs`: per transaction, the shape of its fund-flow graph (the
  abnormal-graph view).
"""

from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass, field

import numpy as np

# Labels of these categories describe assets or infrastructure, not a party
# that holds funds, so they never count as a protocol's flow.
NON_PARTY_CATEGORIES = frozenset({"token", "stablecoin", "oracle"})
TRANSFER_KINDS = frozenset({"erc20_transfer", "erc721_transfer"})


def _label(record: dict, role: str) -> dict | None:
    for lab in record.get("labels") or ():
        if lab.get("role") == role:
            return lab
    return None


def _party(record: dict, role: str) -> str | None:
    lab = _label(record, role)
    if lab and lab.get("protocol") and lab.get("category") not in NON_PARTY_CATEGORIES:
        return lab["protocol"]
    return None


def _usd(record: dict) -> float | None:
    v = record.get("value_usd")
    return float(v) if isinstance(v, int | float) and math.isfinite(v) else None


@dataclass
class ProtocolFlow:
    protocol: str
    name: str
    out_usd: float = 0.0
    in_usd: float = 0.0
    transfers: int = 0
    counterparties: set[str] = field(default_factory=set)
    txs: set[str] = field(default_factory=set)
    outflows: list[tuple[float, str]] = field(default_factory=list)

    @property
    def net_out_usd(self) -> float:
        return max(self.out_usd - self.in_usd, 0.0)

    def top_outflow_ids(self, n: int = 10) -> list[str]:
        return [rid for _, rid in sorted(self.outflows, reverse=True)[:n]]


def protocol_flows(records: list[dict]) -> dict[str, ProtocolFlow]:
    """Priced ERC-20 flow in and out of each labeled protocol in one block.

    Transfers between two contracts of the same protocol cancel out.
    """
    flows: dict[str, ProtocolFlow] = {}

    def get(protocol: str, record: dict, role: str) -> ProtocolFlow:
        if protocol not in flows:
            name = (_label(record, role) or {}).get("name") or protocol
            flows[protocol] = ProtocolFlow(protocol=protocol, name=name)
        return flows[protocol]

    for r in records:
        if r.get("kind") != "erc20_transfer":
            continue
        usd = _usd(r)
        if usd is None:
            continue
        ev = r.get("event") or {}
        src, dst = _party(r, "from"), _party(r, "to")
        if src and src != dst:
            f = get(src, r, "from")
            f.out_usd += usd
            f.transfers += 1
            f.counterparties.add((ev.get("to") or "").lower())
            f.txs.add(r.get("tx") or "")
            f.outflows.append((usd, r["id"]))
        if dst and dst != src:
            f = get(dst, r, "to")
            f.in_usd += usd
            f.transfers += 1
            f.counterparties.add((ev.get("from") or "").lower())
            f.txs.add(r.get("tx") or "")
    return flows


# Order matters: it is the column order of the graph model.
GRAPH_FEATURES = (
    "transfers",
    "addresses",
    "tokens",
    "total_usd",
    "max_usd",
    "flash_loans",
    "swaps",
    "protocols",
    "max_out_degree",
    "max_in_degree",
    "cycle",
    "max_protocol_net_out_usd",
)
# Columns modeled on a log scale (heavy-tailed counts and dollar amounts).
_LOG = {"transfers", "addresses", "total_usd", "max_usd", "max_protocol_net_out_usd"}


@dataclass
class TxGraph:
    tx: str
    values: dict[str, float]
    record_ids: list[str]
    protocols: list[str]
    mixer_or_bridge: bool

    def vector(self) -> np.ndarray:
        return np.array(
            [math.log1p(self.values[k]) if k in _LOG else self.values[k] for k in GRAPH_FEATURES],
            dtype=float,
        )


def _has_cycle(edges: dict[str, set[str]]) -> bool:
    """Directed cycle check (iterative DFS): funds that come back to a sender."""
    white, grey, black = 0, 1, 2
    color: dict[str, int] = defaultdict(int)
    for start in list(edges):
        if color[start] != white:
            continue
        stack = [(start, iter(edges.get(start, ())))]
        color[start] = grey
        while stack:
            node, it = stack[-1]
            nxt = next(it, None)
            if nxt is None:
                color[node] = black
                stack.pop()
            elif color[nxt] == grey:
                return True
            elif color[nxt] == white:
                color[nxt] = grey
                stack.append((nxt, iter(edges.get(nxt, ()))))
    return False


def tx_graphs(records: list[dict]) -> list[TxGraph]:
    """One fund-flow graph per transaction that moves tokens."""
    by_tx: dict[str, list[dict]] = defaultdict(list)
    for r in records:
        by_tx[r.get("tx") or ""].append(r)

    out: list[TxGraph] = []
    for tx, recs in by_tx.items():
        transfers = [r for r in recs if r.get("kind") in TRANSFER_KINDS]
        if not transfers:
            continue
        edges: dict[str, set[str]] = defaultdict(set)
        out_deg: dict[str, int] = defaultdict(int)
        in_deg: dict[str, int] = defaultdict(int)
        addresses: set[str] = set()
        tokens: set[str] = set()
        protocols: set[str] = set()
        net: dict[str, float] = defaultdict(float)
        priced: list[tuple[float, str]] = []
        mixer_or_bridge = False

        for r in transfers:
            ev = r.get("event") or {}
            a, b = (ev.get("from") or "").lower(), (ev.get("to") or "").lower()
            edges[a].add(b)
            out_deg[a] += 1
            in_deg[b] += 1
            addresses.update((a, b))
            tokens.add((r.get("contract") or "").lower())
            usd = _usd(r)
            if usd is not None:
                priced.append((usd, r["id"]))
                if p := _party(r, "from"):
                    net[p] += usd
                if p := _party(r, "to"):
                    net[p] -= usd

        for r in recs:
            for lab in r.get("labels") or ():
                if lab.get("protocol") and lab.get("category") not in NON_PARTY_CATEGORIES:
                    protocols.add(lab["protocol"])
                if lab.get("category") in ("mixer", "bridge"):
                    mixer_or_bridge = True

        flash = [r["id"] for r in recs if r.get("kind") == "flash_loan"]
        values = {
            "transfers": float(len(transfers)),
            "addresses": float(len(addresses)),
            "tokens": float(len(tokens)),
            "total_usd": sum(v for v, _ in priced),
            "max_usd": max((v for v, _ in priced), default=0.0),
            "flash_loans": float(len(flash)),
            "swaps": float(sum(1 for r in recs if r.get("kind") == "swap")),
            "protocols": float(len(protocols)),
            "max_out_degree": float(max(out_deg.values(), default=0)),
            "max_in_degree": float(max(in_deg.values(), default=0)),
            "cycle": 1.0 if _has_cycle(edges) else 0.0,
            "max_protocol_net_out_usd": max((v for v in net.values() if v > 0), default=0.0),
        }
        ids = flash + [rid for _, rid in sorted(priced, reverse=True)[:10]]
        out.append(
            TxGraph(
                tx=tx,
                values=values,
                record_ids=list(dict.fromkeys(ids)),
                protocols=sorted(protocols),
                mixer_or_bridge=mixer_or_bridge,
            )
        )
    return out


def contract_kinds(records: list[dict]) -> list[tuple[str, str, str, str]]:
    """(contract, kind, display name, record id) for events emitted by labeled contracts."""
    seen: dict[tuple[str, str], tuple[str, str, str, str]] = {}
    for r in records:
        lab = _label(r, "contract")
        if not lab or lab.get("category") in NON_PARTY_CATEGORIES:
            continue
        key = ((r.get("contract") or "").lower(), r.get("kind") or "")
        seen.setdefault(key, (key[0], key[1], lab.get("name") or key[0], r["id"]))
    return list(seen.values())
