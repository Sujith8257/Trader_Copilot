"""Market Intelligence — technical indicators computed in plain code,
OUTSIDE any LLM. The agent feeds these as structured context to the model
(or uses them directly), which is far more reliable than asking an LLM to
do math. Pure functions only — fully unit-testable."""

from __future__ import annotations

from typing import Optional, Sequence


def sma(values: Sequence[float], period: int) -> list[Optional[float]]:
    out: list[Optional[float]] = []
    for i in range(len(values)):
        out.append(None if i + 1 < period else sum(values[i + 1 - period : i + 1]) / period)
    return out


def ema(values: Sequence[float], period: int) -> list[Optional[float]]:
    """EMA seeded with the SMA of the first `period` values (classic convention)."""
    out: list[Optional[float]] = []
    k = 2.0 / (period + 1)
    e: Optional[float] = None
    for i, _v in enumerate(values):
        if i + 1 < period:
            out.append(None)
            continue
        e = sum(values[:period]) / period if e is None else values[i] * k + e * (1 - k)
        out.append(e)
    return out


def rsi(values: Sequence[float], period: int = 14) -> Optional[float]:
    """Wilder's RSI. Returns None when there is not enough data."""
    if len(values) < period + 1:
        return None
    gains = losses = 0.0
    for i in range(1, period + 1):
        d = values[i] - values[i - 1]
        gains += max(d, 0.0)
        losses += max(-d, 0.0)
    ag, al = gains / period, losses / period
    for i in range(period + 1, len(values)):
        d = values[i] - values[i - 1]
        ag = (ag * (period - 1) + max(d, 0.0)) / period
        al = (al * (period - 1) + max(-d, 0.0)) / period
    if al == 0:
        return 100.0
    rs = ag / al
    return 100.0 - 100.0 / (1.0 + rs)


def _last_valid(series: list[Optional[float]]) -> Optional[float]:
    for v in reversed(series):
        if v is not None:
            return v
    return None


def macd(values: Sequence[float], fast: int = 12, slow: int = 26, signal: int = 9) -> dict:
    ef, es = ema(values, fast), ema(values, slow)
    line = [None if (a is None or b is None) else a - b for a, b in zip(ef, es)]
    compact = [v for v in line if v is not None]
    sig = ema(compact, signal) if len(compact) >= signal else [None] * len(compact)
    m = _last_valid(line)
    s = _last_valid(sig)
    hist = None if (m is None or s is None) else m - s
    return {"macd": m, "signal": s, "hist": hist}


def bollinger(values: Sequence[float], period: int = 20, k: float = 2.0) -> dict:
    if len(values) < period:
        return {"mid": None, "upper": None, "lower": None}
    window = values[-period:]
    mid = sum(window) / period
    var = sum((x - mid) ** 2 for x in window) / period
    sd = var ** 0.5
    return {"mid": mid, "upper": mid + k * sd, "lower": mid - k * sd}


def atr(highs: Sequence[float], lows: Sequence[float], closes: Sequence[float], period: int = 14) -> Optional[float]:
    n = len(closes)
    if n < period + 1:
        return None
    trs: list[float] = []
    for i in range(1, n):
        tr = max(
            highs[i] - lows[i],
            abs(highs[i] - closes[i - 1]),
            abs(lows[i] - closes[i - 1]),
        )
        trs.append(tr)
    a = sum(trs[:period]) / period
    for tr in trs[period:]:
        a = (a * (period - 1) + tr) / period
    return a


def snapshot(bars: Sequence[dict]) -> dict:
    """One structured indicator snapshot from OHLCV bars — the exact payload
    the agent gives the LLM (or reasons over itself). Includes ATR-based
    stop/target levels (2x risk / 3x reward)."""
    closes = [b["c"] for b in bars]
    highs = [b["h"] for b in bars]
    lows = [b["l"] for b in bars]
    last = closes[-1]
    prev = closes[-2] if len(closes) > 1 else last
    e20, e50 = _last_valid(ema(closes, 20)), _last_valid(ema(closes, 50))
    r = rsi(closes)
    m = macd(closes)
    bb = bollinger(closes)
    a = atr(highs, lows, closes)
    stop = last - 2 * a if a else last * 0.98
    target = last + 3 * a if a else last * 1.03
    return {
        "last": round(last, 2),
        "change_pct": round((last / prev - 1) * 100, 2) if prev else 0.0,
        "rsi": round(r, 1) if r is not None else None,
        "ema20": round(e20, 2) if e20 else None,
        "ema50": round(e50, 2) if e50 else None,
        "trend": "UP" if (e20 and e50 and e20 > e50) else "DOWN",
        "macd": round(m["macd"], 3) if m["macd"] is not None else None,
        "macd_hist": round(m["hist"], 3) if m["hist"] is not None else None,
        "bb_upper": round(bb["upper"], 2) if bb["upper"] else None,
        "bb_lower": round(bb["lower"], 2) if bb["lower"] else None,
        "atr": round(a, 2) if a else None,
        "stop": round(stop, 2),
        "target": round(target, 2),
    }
