"""Coinbase Advanced Trade integration — LIVE market data + LIVE trading.

Two capabilities behind one client:

1. Market data (public, no auth): products, daily candles, spot prices.
   Powers charts, indicator snapshots, the AI Radar, and paper fills so the
   whole app runs on REAL prices — no simulated data for crypto.
2. Trading (auth): CDP API key JWT (EdDSA for Ed25519 keys, ES256 for EC),
   account balances, and market orders. The key NEVER leaves the backend —
   it is read from environment / backend/.env, and is git-ignored.

All market prices are converted to INR (live USD/INR) so the INR-denominated
paper account, Risk Engine, and UI stay consistent. The live Coinbase account
reports its native balances.
"""

from __future__ import annotations

import base64
import os
import threading
import time
import uuid
from typing import Optional

import requests

BASE_URL = "https://api.coinbase.com"
_API = "/api/v3/brokerage"

# Products available on Coinbase Advanced Trade (sim universe had BNB —
# Coinbase does not list BNB, so AVAX takes its slot).
COINBASE_PRODUCTS = (
    "BTC", "ETH", "SOL", "XRP", "ADA", "DOGE", "LINK", "AVAX",
)

_GRANULARITIES = {
    "ONE_MINUTE": 60, "FIVE_MINUTE": 300, "FIFTEEN_MINUTE": 900,
    "THIRTY_MINUTE": 1800, "ONE_HOUR": 3600, "TWO_HOUR": 7200,
    "SIX_HOUR": 21600, "ONE_DAY": 86400,
}


# -- credentials ------------------------------------------------------------- #

def _load_dotenv(path: str) -> None:
    """Tiny .env parser (no dependency): KEY=VALUE lines into os.environ."""
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            k, v = k.strip(), v.strip().strip('"').strip("'")
            os.environ.setdefault(k, v)


def load_credentials() -> tuple[Optional[str], Optional[str]]:
    """Resolve (api_key_name, private_key_b64) from env or backend/.env."""
    _load_dotenv(os.path.join(os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__)))), ".env"))
    return os.getenv("COINBASE_API_KEY"), os.getenv("COINBASE_PRIVATE_KEY")


def decode_private_key(b64_key: str):
    """Decode a CDP private key into a cryptography private key object.

    Supports the two formats Coinbase issues:
      * 64 raw bytes  — Ed25519 (seed || public), JWT alg EdDSA (newest keys)
      * DER/PEM blob  — EC P-256, JWT alg ES256
    """
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.serialization import (
        load_der_private_key, load_pem_private_key,
    )

    der = base64.b64decode(b64_key.strip())
    if len(der) == 64:
        return Ed25519PrivateKey.from_private_bytes(der[:32]), "EdDSA"
    try:
        return load_der_private_key(der, password=None), "ES256"
    except ValueError:
        return load_pem_private_key(der, password=None), "ES256"


# -- client ------------------------------------------------------------------- #

class CoinbaseError(RuntimeError):
    pass


class CoinbaseClient:
    """Thin REST client for Coinbase Advanced Trade (requests, thread-safe)."""

    def __init__(self, api_key: Optional[str] = None, private_key: Optional[str] = None,
                 timeout: int = 20) -> None:
        self.api_key, self.private_key = api_key, private_key
        if self.api_key is None or self.private_key is None:
            self.api_key, self.private_key = load_credentials()
        self._timeout = timeout
        self._key_obj = None
        self._alg = None
        self._lock = threading.Lock()

    # -- auth -------------------------------------------------------------- #
    @property
    def configured(self) -> bool:
        return bool(self.api_key and self.private_key)

    def _jwt(self, method: str, path: str) -> str:
        import jwt  # PyJWT

        with self._lock:
            if self._key_obj is None:
                self._key_obj, self._alg = decode_private_key(self.private_key)
        now = int(time.time())
        claims = {
            "sub": self.api_key,
            "iss": "cdp",
            "nbf": now,
            "exp": now + 120,
            "uri": f"{method} api.coinbase.com{path}",
        }
        headers = {"kid": self.api_key, "nonce": uuid.uuid4().hex}
        return jwt.encode(claims, self._key_obj, algorithm=self._alg, headers=headers)

    def _request(self, method: str, path: str, *, auth: bool = False,
                 params: Optional[dict] = None, json_body: Optional[dict] = None) -> dict:
        headers = {"Content-Type": "application/json"}
        if auth:
            if not self.configured:
                raise CoinbaseError("Coinbase API key not configured.")
            headers["Authorization"] = f"Bearer {self._jwt(method, path)}"
        r = requests.request(
            method, f"{BASE_URL}{path}", headers=headers, params=params,
            json=json_body, timeout=self._timeout,
        )
        try:
            body = r.json()
        except ValueError:
            body = {}
        if r.status_code >= 400:
            msg = body.get("message") or r.text[:300]
            raise CoinbaseError(f"Coinbase {method} {path} -> {r.status_code}: {msg}")
        return body

    # -- public market data ------------------------------------------------- #
    def get_spot(self, product_id: str) -> float:
        body = self._request("GET", f"{_API}/market/products/{product_id}")
        return float(body["price"])

    def get_candles(self, product_id: str, granularity: str = "ONE_DAY",
                    limit: int = 350) -> list[dict]:
        """OHLCV candles, oldest-first: [{start, o, h, l, c, v}, ...]."""
        if granularity not in _GRANULARITIES:
            raise CoinbaseError(f"Bad granularity {granularity}")
        body = self._request(
            "GET", f"{_API}/market/products/{product_id}/candles",
            params={"granularity": granularity, "limit": min(limit, 350)},
        )
        candles = body.get("candles", [])
        candles.sort(key=lambda c: c["start"])  # Coinbase returns newest-first
        return candles

    # -- authenticated account surface --------------------------------------- #
    def get_accounts(self) -> list[dict]:
        body = self._request("GET", f"{_API}/accounts", auth=True, params={"limit": 250})
        return body.get("accounts", [])

    def get_order(self, order_id: str) -> dict:
        return self._request("GET", f"{_API}/orders/historical/{order_id}", auth=True)

    def market_order(self, product_id: str, side: str, *, quote_size: Optional[str] = None,
                     base_size: Optional[str] = None) -> dict:
        """Market IOC order. BUY sized in quote currency, SELL in base."""
        payload: dict = {
            "product_id": product_id,
            "side": side,
            "order_type": "market_market_ioc",
        }
        if side == "BUY":
            payload["market_market_ioc"] = {"quote_size": quote_size}
        else:
            payload["market_market_ioc"] = {"base_size": base_size}
        return self._request("POST", f"{_API}/orders", auth=True, json_body=payload)


# -- live market (MarketSim-compatible surface, REAL data) -------------------- #

class LiveCoinbaseMarket:
    """Drop-in replacement for MarketSim backed by REAL Coinbase candles.

    Same read surface as MarketSim (symbols/bars/prices/last) so the agent,
    indicators, and AI Radar need zero changes. All prices are in INR
    (spot/candle USD x live USD-INR). Cached with TTLs to respect rate limits.
    """

    def __init__(self, client: Optional[CoinbaseClient] = None,
                 products: tuple[str, ...] = COINBASE_PRODUCTS,
                 quote: str = "USD", days: int = 120) -> None:
        self.client = client or CoinbaseClient()
        self._products = tuple(products)
        self._quote = quote
        self._days = days
        self._bars: dict[str, list[dict]] = {}
        self._bars_ts: dict[str, float] = {}
        self._spot: dict[str, tuple[float, float]] = {}  # sym -> (price, ts)
        self._fx: Optional[tuple[float, float]] = None   # (rate, ts)
        self._lock = threading.Lock()
        self.last_error: Optional[str] = None

    # -- MarketSim-compatible surface ---------------------------------------- #
    def symbols(self) -> list[str]:
        return list(self._products)

    def product(self, symbol: str) -> str:
        return f"{symbol.strip().upper()}-{self._quote}"

    def _usd_inr(self) -> float:
        now = time.time()
        with self._lock:
            if self._fx and now - self._fx[1] < 3600:
                return self._fx[0]
        rate = None
        errors = []
        # Fallback chain — all free, key-less FX feeds:
        for fetch in (
            lambda: float(requests.get(
                "https://open.er-api.com/v6/latest/USD", timeout=10
            ).json()["rates"]["INR"]),
            lambda: float(requests.get(
                "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest"
                "/v1/currencies/usd.min.json", timeout=10,
            ).json()["usd"]["inr"]),
            lambda: float(requests.get(
                "https://api.frankfurter.dev/v1/latest?base=USD&symbols=INR",
                timeout=10,
            ).json()["rates"]["INR"]),
        ):
            try:
                rate = fetch()
                break
            except Exception as e:  # noqa: BLE001 - try the next feed
                errors.append(type(e).__name__)
        if rate is None:  # keep last known rate; never fabricate
            with self._lock:
                if self._fx:
                    return self._fx[0]
                raise CoinbaseError(f"USD/INR unavailable: {errors}")
        with self._lock:
            self._fx = (rate, now)
        return rate

    def _refresh_bars(self, symbol: str) -> list[dict]:
        now = time.time()
        cached = self._bars.get(symbol)
        if cached and now - self._bars_ts.get(symbol, 0) < 300:
            return cached
        candles = self.client.get_candles(self.product(symbol), "ONE_DAY",
                                          limit=self._days)
        fx = self._usd_inr()
        bars = [{
            "o": round(float(c["open"]) * fx, 2),
            "h": round(float(c["high"]) * fx, 2),
            "l": round(float(c["low"]) * fx, 2),
            "c": round(float(c["close"]) * fx, 2),
            "v": round(float(c["volume"]), 2),
            "start": c["start"],
        } for c in candles]
        if not bars:
            raise CoinbaseError(f"No candles for {symbol}")
        with self._lock:
            self._bars[symbol], self._bars_ts[symbol] = bars, now
        return bars

    def bars(self, symbol: str) -> list[dict]:
        return self._refresh_bars(symbol.strip().upper())

    def prices(self, symbol: str) -> list[float]:
        return [b["c"] for b in self.bars(symbol)]

    def last(self, symbol: str) -> float:
        symbol = symbol.strip().upper()
        now = time.time()
        with self._lock:
            hit = self._spot.get(symbol)
            if hit and now - hit[1] < 30:
                return hit[0]
        fx = self._usd_inr()
        price = self.client.get_spot(self.product(symbol)) * fx
        with self._lock:
            self._spot[symbol] = (price, now)
        return price

    def status(self) -> dict:
        """Diagnostics for /health — is live data flowing, and how fresh."""
        with self._lock:
            fresh = sum(1 for ts in self._bars_ts.values() if time.time() - ts < 600)
        return {
            "source": "coinbase-live",
            "products": len(self._products),
            "symbols_cached": len(self._bars),
            "bars_fresh": fresh,
            "usd_inr": round(self._fx[0], 4) if self._fx else None,
            "last_error": self.last_error,
        }
