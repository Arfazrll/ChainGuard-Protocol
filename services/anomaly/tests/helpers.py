"""Builders for compact records, exactly as the engine posts them."""

from __future__ import annotations

import hashlib
import itertools

_ids = itertools.count()


def h(seed: str, n: int = 64) -> str:
    return "0x" + hashlib.sha256(seed.encode()).hexdigest()[:n]


def addr(seed: str) -> str:
    return h("addr" + seed, 40)


def block(n: int, fork: str = "") -> dict:
    return {"number": n, "hash": h(f"block-{n}-{fork}"), "timestamp": 1_700_000_000 + 12 * n}


def label(role: str, address: str, name: str, category: str, protocol: str | None) -> dict:
    return {
        "role": role,
        "address": address,
        "name": name,
        "category": category,
        "protocol": protocol,
    }


def transfer(tx: str, src: str, dst: str, usd: float | None, labels=(), token: str = "dai") -> dict:
    i = next(_ids)
    return {
        "id": h(f"rec-{i}"),
        "tx": tx,
        "log": i,
        "contract": addr(token),
        "kind": "erc20_transfer",
        "event": {"from": src, "to": dst, "amount": "1"},
        "value_usd": usd,
        "token": token.upper(),
        "labels": list(labels),
    }


def event(tx: str, contract: str, kind: str, labels=()) -> dict:
    i = next(_ids)
    return {
        "id": h(f"rec-{i}"),
        "tx": tx,
        "log": i,
        "contract": contract,
        "kind": kind,
        "event": {},
        "value_usd": None,
        "token": None,
        "labels": list(labels),
    }


VAULT = addr("vault")


def vault(role: str) -> dict:
    return label(role, VAULT, "Vault", "lending", "vault")


def swap_tx(seed: str, usd: float) -> list[dict]:
    """An ordinary two-hop swap: user → pool → user."""
    tx, user, pool = h(seed), addr("u" + seed), addr("pool" + seed[-1])
    return [
        transfer(tx, user, pool, usd, token="usdc"),
        transfer(tx, pool, user, usd * 0.997, token="weth"),
    ]


def drain_tx(seed: str) -> list[dict]:
    """Flash loan → deposit → over-withdraw → repay, across two protocols."""
    tx, att, lender = h(seed), addr("attacker" + seed), addr("lender")
    lend = lambda r: label(r, lender, "Lender", "lending", "lender")  # noqa: E731
    return [
        {**event(tx, lender, "flash_loan", [lend("contract")])},
        transfer(tx, lender, att, 30_000_000.0, [lend("from")]),
        transfer(tx, att, VAULT, 30_000_000.0, [vault("to")]),
        *[transfer(tx, VAULT, att, 4_000_000.0, [vault("from")]) for _ in range(10)],
        transfer(tx, att, lender, 30_027_000.0, [lend("to")]),
        transfer(tx, att, addr("exit" + seed), 9_000_000.0),
    ]
