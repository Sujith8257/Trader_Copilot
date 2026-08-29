"""Coinbase integration tests — fully offline (stubbed client, no network)."""

import base64

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from app.core.brokers.coinbase import CoinbaseBroker
from app.core.coinbase import CoinbaseClient, CoinbaseError, LiveCoinbaseMarket, decode_private_key
from app.core.models import Order, Side


# -- key decoding -------------------------------------------------------------- #

def test_decode_ed25519_key():
    """64 raw bytes = Ed25519 (seed || public) — the newest CDP key format."""
    from cryptography.hazmat.primitives import serialization

    priv = Ed25519PrivateKey.generate()
    seed = priv.private_bytes(
        serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
        serialization.NoEncryption(),
    )  # 32 bytes
    pub = priv.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    b64 = base64.b64encode(seed + pub).decode()
    key, alg = decode_private_key(b64)
    assert isinstance(key, Ed25519PrivateKey)
    assert alg == "EdDSA"


def test_decode_bad_key_raises():
    import pytest

    with pytest.raises(Exception):
        decode_private_key(base64.b64encode(b"not-a-key").decode())


# -- live market with a stubbed client ------------------------------------------- #

class StubClient(CoinbaseClient):
    """Offline stand-in: no HTTP, deterministic candles + fx."""

    def __init__(self):
        # bypass CoinbaseClient.__init__ so real .env creds are never loaded
        import threading

        self.api_key, self.private_key = "stub", "stub"
        self._timeout = 5
        self._key_obj = None
        self._alg = None
        self._lock = threading.Lock()

    def get_spot(self, product_id):
        return {"BTC-USD": 60_000.0, "ETH-USD": 3_000.0}[product_id]

    def get_candles(self, product_id, granularity="ONE_DAY", limit=350):
        base = 60_000.0 if product_id == "BTC-USD" else 3_000.0
        # newest-first, like Coinbase
        return [
            {"start": str(1_700_000_000 + i * 86_400),
             "open": str(base), "high": str(base * 1.01),
             "low": str(base * 0.99), "close": str(base * 1.005),
             "volume": "123.4"}
            for i in range(limit - 1, -1, -1)
        ]


def _live_market(monkeypatch):
    m = LiveCoinbaseMarket(client=StubClient(), products=("BTC", "ETH"))
    # pre-seed the fx cache (simulates a successful live fetch) and pin it
    import time

    m._fx = (90.0, time.time())
    monkeypatch.setattr(m, "_usd_inr", lambda: 90.0)
    return m


def test_live_market_converts_to_inr(monkeypatch):
    m = _live_market(monkeypatch)
    assert m.last("BTC") == 60_000.0 * 90.0
    bars = m.bars("BTC")
    assert len(bars) == m._days
    assert bars[0]["c"] == round(60_000.0 * 1.005 * 90.0, 2)  # oldest first
    assert m.symbols() == ["BTC", "ETH"]


def test_live_market_is_agent_compatible(monkeypatch):
    from app.core.indicators import snapshot

    m = _live_market(monkeypatch)
    s = snapshot(m.bars("ETH"))
    assert s["last"] > 0 and s["trend"] in ("UP", "DOWN")


def test_live_market_status(monkeypatch):
    m = _live_market(monkeypatch)
    m.bars("BTC")
    st = m.status()
    assert st["source"] == "coinbase-live"
    assert st["bars_fresh"] == 1 and st["usd_inr"] == 90.0


# -- live broker ------------------------------------------------------------------ #

def test_live_broker_disabled_without_key():
    client = StubClient()
    client.api_key = client.private_key = None
    broker = CoinbaseBroker(client=client)
    assert broker.health().value == "DISABLED"
    order = broker.place_order(
        Order(symbol="BTC", side=Side.BUY, quantity=0.01), 5_000_000.0
    )
    assert order.status.value == "REJECTED"


def test_live_broker_rejects_unknown_symbol():
    broker = CoinbaseBroker(client=StubClient.__new__(StubClient))
    assert not broker.supports_symbol("TCS")
    assert broker.supports_symbol("BTC")


def test_live_broker_order_rejection_maps_to_rejected():
    class FailingClient(StubClient):
        def market_order(self, product_id, side, *, quote_size=None, base_size=None):
            raise CoinbaseError("insufficient balance")

    class FxOnly:
        @staticmethod
        def _usd_inr():
            return 90.0

    broker = CoinbaseBroker(client=FailingClient(), market=FxOnly())
    order = broker.place_order(
        Order(symbol="BTC", side=Side.BUY, quantity=0.01), 5_400_000.0
    )
    assert order.status.value == "REJECTED"
    assert "insufficient balance" in (broker.last_error or "")
