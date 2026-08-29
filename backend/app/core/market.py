"""Deterministic market simulator — a seeded synthetic OHLC universe so the
entire agentic demo (scanner, indicators, proposals) runs fully offline.
Replace with a real market-data service in Phase 3; the agent's tool surface
stays identical."""

from __future__ import annotations

import random
from typing import Sequence

UNIVERSE: dict[str, float] = {
    "RELIANCE": 2450.0,
    "TCS": 3900.0,
    "INFY": 1520.0,
    "HDFCBANK": 1680.0,
    "TATAMOTORS": 980.0,
    "SBIN": 620.0,
    "ITC": 460.0,
    "ADANIENT": 3100.0,
}


class MarketSim:
    def __init__(self, days: int = 120, seed: int = 7) -> None:
        self._bars: dict[str, list[dict]] = {}
        rng = random.Random(seed)
        for sym, base in UNIVERSE.items():
            # per-symbol regime: some trending up, some down, different vols
            drift = rng.uniform(-0.0035, 0.0035)
            vol = rng.uniform(0.012, 0.028)
            price = base
            bars: list[dict] = []
            for _d in range(days):
                shock = rng.gauss(drift, vol)
                o = price
                c = max(1.0, o * (1 + shock))
                h = max(o, c) * (1 + abs(rng.gauss(0, vol / 2)))
                low = min(o, c) * (1 - abs(rng.gauss(0, vol / 2)))
                v = int(rng.uniform(0.8e6, 3.0e6) * (1 + abs(shock) * 40))
                bars.append(
                    {"o": round(o, 2), "h": round(h, 2), "l": round(low, 2),
                     "c": round(c, 2), "v": v}
                )
                price = c
            self._bars[sym] = bars

    def symbols(self) -> list[str]:
        return list(self._bars)

    def bars(self, symbol: str) -> Sequence[dict]:
        return self._bars[symbol.strip().upper()]

    def prices(self, symbol: str) -> list[float]:
        return [b["c"] for b in self.bars(symbol)]

    def last(self, symbol: str) -> float:
        return self._bars[symbol.strip().upper()][-1]["c"]
