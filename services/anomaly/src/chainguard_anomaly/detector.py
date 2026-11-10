"""The anomaly detector: learns what normal looks like per chain, flags outliers.

Three models, all online, all reorg-aware (every observation is keyed by the
block hash it came from, so an orphaned block is *unlearned*):

1. **Protocol flow baseline** (volume spikes). For each labeled protocol, a
   rolling window of its per-block net USD outflow in blocks where it was
   active. A block is anomalous when the protocol's net outflow is material
   and sits far above its own history (robust z-score on a log scale: median
   and MAD, so one past spike does not mask the next).
2. **Fund-flow graph model** (abnormal graphs). An IsolationForest over the
   shape of every token-moving transaction: transfer and address counts,
   dollar size, flash loans, cycles, fan-out, protocols touched. Refit
   periodically on recent non-anomalous transactions.
3. **Novel patterns** (unseen call patterns). The first time a labeled
   contract emits an event kind after warm-up.

Anomalies are scored *before* the block is learned, and anomalous
observations are kept out of training, so an attack does not teach the model
that attacks are normal.
"""

from __future__ import annotations

import math
from collections import OrderedDict, deque
from dataclasses import dataclass, field

import numpy as np
from sklearn.ensemble import IsolationForest

from .features import GRAPH_FEATURES, contract_kinds, protocol_flows, tx_graphs

_LOG_FEATURES = {"transfers", "addresses", "total_usd", "max_usd", "max_protocol_net_out_usd"}


@dataclass(frozen=True)
class Settings:
    # Protocol flow baseline
    flow_window: int = 2_000  # active blocks remembered per protocol
    flow_min_obs: int = 20  # below this, the protocol is still warming up
    flow_z: float = 6.0  # robust z on log1p(net outflow USD)
    flow_scale_floor: float = 0.5  # log units; keeps tiny MADs from exploding z
    flow_material_usd: float = 1_000_000.0
    # Fund-flow graph model
    graph_buffer: int = 20_000
    graph_min_train: int = 1_000
    graph_refit_every: int = 25  # blocks
    graph_contamination: float = 0.005  # top 0.5% of IsolationForest scores...
    graph_extreme_q: float = 0.999  # ...and a dollar feature far beyond normal:
    graph_usd_factor: float = 5.0  # >= 5x its 99.9th percentile (counts: context only,
    graph_count_factor: float = 2.0  # shown at >= 2x)
    graph_material_usd: float = 250_000.0
    graph_trees: int = 200
    # Novel patterns
    novelty_warmup_blocks: int = 300
    # Idempotency
    remember_blocks: int = 4_096


def _usd(v: float) -> str:
    return f"${v:,.0f}"


def _short(h: str) -> str:
    return f"{h[:6]}…{h[-4:]}" if h and len(h) > 14 else h


@dataclass
class _FlowHistory:
    obs: deque = field(default_factory=deque)  # (block_hash, log1p(net_out))

    def values(self) -> np.ndarray:
        return np.fromiter((v for _, v in self.obs), dtype=float, count=len(self.obs))


class ChainDetector:
    """All model state for one chain."""

    def __init__(self, chain_id: int, settings: Settings | None = None) -> None:
        self.chain_id = chain_id
        self.s = settings or Settings()
        self.flows: dict[str, _FlowHistory] = {}
        self.graph_buf: deque[tuple[str, np.ndarray]] = deque(maxlen=self.s.graph_buffer)
        self.forest: IsolationForest | None = None
        self.forest_threshold: float | None = None
        self.forest_p999: np.ndarray | None = None
        self.blocks_since_fit = 0
        self.kinds_first_seen: dict[tuple[str, str], str] = {}
        self.blocks_seen: OrderedDict[str, int] = OrderedDict()
        self.blocks_learned = 0
        self.anomalies_raised = 0

    # --- public ------------------------------------------------------------

    def process(self, block: dict, records: list[dict]) -> dict:
        block_hash = block.get("hash") or ""
        if block_hash in self.blocks_seen:
            return {"anomalies": [], "duplicate": True, "model": self.summary()}

        anomalies = (
            self._score_flows(block, records)
            + self._score_graphs(block, records)
            + self._novelty(block, records)
        )
        self.anomalies_raised += len(anomalies)
        self._remember(block_hash, block.get("number") or 0)
        self._maybe_refit()
        return {"anomalies": anomalies, "duplicate": False, "model": self.summary()}

    def orphan(self, block_hash: str) -> bool:
        """Unlearn everything a reorged-away block contributed."""
        if self.blocks_seen.pop(block_hash, None) is None:
            return False
        self.blocks_learned = max(0, self.blocks_learned - 1)
        for h in self.flows.values():
            h.obs = deque((bh, v) for bh, v in h.obs if bh != block_hash)
        kept = [(bh, v) for bh, v in self.graph_buf if bh != block_hash]
        if len(kept) != len(self.graph_buf):
            self.graph_buf = deque(kept, maxlen=self.s.graph_buffer)
            self.blocks_since_fit = self.s.graph_refit_every  # refit on next block
        self.kinds_first_seen = {
            k: bh for k, bh in self.kinds_first_seen.items() if bh != block_hash
        }
        return True

    def summary(self) -> dict:
        warm = sum(1 for h in self.flows.values() if len(h.obs) >= self.s.flow_min_obs)
        return {
            "chain_id": self.chain_id,
            "blocks_learned": self.blocks_learned,
            "protocols_tracked": len(self.flows),
            "protocols_warm": warm,
            "graph_samples": len(self.graph_buf),
            "graph_model": "fitted" if self.forest is not None else "warming_up",
            "novelty": "armed"
            if self.blocks_learned >= self.s.novelty_warmup_blocks
            else "warming_up",
            "anomalies_raised": self.anomalies_raised,
        }

    # --- model 1: protocol flow baseline -------------------------------------

    def flow_score(self, protocol: str, net_out_usd: float) -> tuple[float, float, int] | None:
        """(z, median USD, observations) or None while warming up."""
        h = self.flows.get(protocol)
        if h is None or len(h.obs) < self.s.flow_min_obs:
            return None
        xs = h.values()
        med = float(np.median(xs))
        mad = float(np.median(np.abs(xs - med)))
        scale = max(1.4826 * mad, self.s.flow_scale_floor)
        return (math.log1p(net_out_usd) - med) / scale, math.expm1(med), len(xs)

    def _score_flows(self, block: dict, records: list[dict]) -> list[dict]:
        out = []
        block_hash = block.get("hash") or ""
        for p, f in protocol_flows(records).items():
            net = f.net_out_usd
            scored = self.flow_score(p, net)
            anomalous = (
                scored is not None
                and net >= self.s.flow_material_usd
                and scored[0] >= self.s.flow_z
            )
            if anomalous:
                z, med, n = scored
                out.append(
                    {
                        "kind": "protocol_flow",
                        "key": f"protocol_flow:{p}",
                        "score": round(z, 2),
                        "threshold": self.s.flow_z,
                        "title": (
                            f"{f.name} net outflow {_usd(net)} in block #{block.get('number')}: "
                            f"far above its usual {_usd(med)} (median of {n} active blocks)"
                        ),
                        "reasons": [
                            f"robust z {z:.1f} on log net outflow (threshold {self.s.flow_z})",
                            f"{f.transfers} transfers, {len(f.counterparties)} counterparties, "
                            f"{len(f.txs)} txs",
                        ],
                        "record_ids": f.top_outflow_ids(),
                        "features": {
                            "net_out_usd": net,
                            "out_usd": f.out_usd,
                            "in_usd": f.in_usd,
                            "median_net_out_usd": med,
                            "observations": n,
                        },
                    }
                )
            else:
                # Learn only normal, active blocks: the baseline is "activity
                # when it happens", and attacks never become normal.
                h = self.flows.setdefault(p, _FlowHistory())
                if f.transfers:
                    h.obs.append((block_hash, math.log1p(net)))
                    while len(h.obs) > self.s.flow_window:
                        h.obs.popleft()
        return out

    # --- model 2: fund-flow graph IsolationForest ---------------------------

    def graph_scores(self, X: np.ndarray) -> np.ndarray:
        """Anomaly score per row: higher is more anomalous."""
        assert self.forest is not None
        return -self.forest.score_samples(X)

    def _score_graphs(self, block: dict, records: list[dict]) -> list[dict]:
        block_hash = block.get("hash") or ""
        graphs = tx_graphs(records)
        if not graphs:
            return []
        X = np.vstack([g.vector() for g in graphs])
        flagged: set[int] = set()
        out = []
        if self.forest is not None and self.forest_threshold is not None:
            scores = self.graph_scores(X)
            for i, (g, sc) in enumerate(zip(graphs, scores, strict=True)):
                # IsolationForest scores saturate beyond the training range, so
                # the score alone has little margin. An anomaly must also be
                # concretely beyond normal on some feature: that is what the
                # alert then shows as its reason.
                if (
                    sc > self.forest_threshold
                    and g.values["total_usd"] >= self.s.graph_material_usd
                    and (extremes := self._extreme_features(X[i]))
                ):
                    flagged.add(i)
                    out.append(self._graph_anomaly(g, extremes, float(sc)))
        for i, row in enumerate(X):
            if i not in flagged:
                self.graph_buf.append((block_hash, row))
        return out

    def _graph_anomaly(self, g, extremes: list[str], score: float) -> dict:
        v = g.values
        reasons = list(extremes)
        if v["flash_loans"]:
            reasons.append(f"{int(v['flash_loans'])} flash loan(s)")
        if v["cycle"]:
            reasons.append("funds return to a sender (cycle)")
        if g.mixer_or_bridge:
            reasons.append("touches a mixer or bridge")
        return {
            "kind": "tx_graph",
            "key": f"tx_graph:{g.tx}",
            "score": round(score, 3),
            "threshold": round(float(self.forest_threshold), 3),
            "title": (
                f"Unusual fund-flow graph in tx {_short(g.tx)}: {int(v['transfers'])} transfers "
                f"across {int(v['addresses'])} addresses, {_usd(v['total_usd'])} moved"
                + (f", {len(g.protocols)} protocols" if g.protocols else "")
            ),
            "reasons": reasons,
            "record_ids": g.record_ids,
            "features": v,
        }

    def _extreme_features(self, row: np.ndarray) -> list[str]:
        """Features far beyond the 99.9th percentile of what the model trained on.

        Returns the reasons to show, or [] when nothing is extreme enough to
        alert on. Only a dollar feature (total moved, largest transfer,
        largest protocol net outflow) at >= `graph_usd_factor` x its p99.9
        can make a transaction anomalous; counts (tokens, protocols, fan-out)
        at >= `graph_count_factor` x are added as context but never trigger
        on their own. Measured on 200 real blocks: counts barely past p99.9
        are ordinary aggregator routes.
        """
        if self.forest_p999 is None:
            return []
        out: list[str] = []
        triggered = False
        for j, name in enumerate(GRAPH_FEATURES):
            if name in ("cycle", "flash_loans"):
                continue
            val, ref = float(row[j]), float(self.forest_p999[j])
            if name in _LOG_FEATURES:
                val, ref = math.expm1(val), math.expm1(ref)
            is_usd = name.endswith("usd")
            factor = self.s.graph_usd_factor if is_usd else self.s.graph_count_factor
            if ref <= 0 or val < factor * ref:
                continue
            triggered |= is_usd
            fmt = _usd if is_usd else (lambda x: f"{x:,.0f}")
            out.append(
                f"{name.replace('_', ' ')} {fmt(val)}: {val / ref:,.0f}x the p99.9 of normal "
                f"({fmt(ref)})"
            )
        return out if triggered else []

    def _maybe_refit(self) -> None:
        self.blocks_since_fit += 1
        if len(self.graph_buf) < self.s.graph_min_train:
            return
        if self.forest is not None and self.blocks_since_fit < self.s.graph_refit_every:
            return
        X = np.vstack([row for _, row in self.graph_buf])
        forest = IsolationForest(
            n_estimators=self.s.graph_trees,
            max_samples=min(512, len(X)),
            random_state=0,
            n_jobs=1,
        ).fit(X)
        train_scores = -forest.score_samples(X)
        self.forest = forest
        self.forest_p999 = np.quantile(X, self.s.graph_extreme_q, axis=0)
        self.forest_threshold = float(np.quantile(train_scores, 1 - self.s.graph_contamination))
        self.blocks_since_fit = 0

    # --- model 3: novel patterns ------------------------------------------------

    def _novelty(self, block: dict, records: list[dict]) -> list[dict]:
        block_hash = block.get("hash") or ""
        armed = self.blocks_learned >= self.s.novelty_warmup_blocks
        out = []
        for contract, kind, name, rid in contract_kinds(records):
            key = (contract, kind)
            if key in self.kinds_first_seen:
                continue
            self.kinds_first_seen[key] = block_hash
            if armed:
                out.append(
                    {
                        "kind": "novel_pattern",
                        "key": f"novel_pattern:{contract}:{kind}",
                        "score": 1.0,
                        "threshold": 1.0,
                        "title": (
                            f"First {kind} event from {name} "
                            f"in {self.blocks_learned} blocks observed"
                        ),
                        "reasons": [f"{name} ({_short(contract)}) never emitted {kind} before"],
                        "record_ids": [rid],
                        "features": {"blocks_observed": self.blocks_learned},
                    }
                )
        return out

    # --- bookkeeping --------------------------------------------------------------

    def _remember(self, block_hash: str, number: int) -> None:
        self.blocks_seen[block_hash] = number
        self.blocks_learned += 1
        while len(self.blocks_seen) > self.s.remember_blocks:
            self.blocks_seen.popitem(last=False)


class Detector:
    """One :class:`ChainDetector` per chain."""

    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or Settings()
        self.chains: dict[int, ChainDetector] = {}

    def chain(self, chain_id: int) -> ChainDetector:
        if chain_id not in self.chains:
            self.chains[chain_id] = ChainDetector(chain_id, self.settings)
        return self.chains[chain_id]

    def process(self, chain_id: int, block: dict, records: list[dict]) -> dict:
        return self.chain(chain_id).process(block, records)

    def orphan(self, chain_id: int, block_hash: str) -> bool:
        return self.chain(chain_id).orphan(block_hash)

    def summary(self) -> dict:
        return {str(c): d.summary() for c, d in sorted(self.chains.items())}
