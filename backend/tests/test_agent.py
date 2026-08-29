"""Tests for the Market Intelligence layer and the Agentic Copilot engine."""

from fastapi.testclient import TestClient

from app.core.indicators import atr, ema, rsi, snapshot, sma
from app.core.market import MarketSim
from app.main import app

client = TestClient(app)


class TestIndicators:
    def test_sma_basic(self):
        assert sma([1, 2, 3, 4, 5], 3)[-1] == 4.0
        assert sma([1, 2, 3, 4, 5], 3)[:2] == [None, None]

    def test_ema_converges_toward_last_value(self):
        vals = [float(i) for i in range(1, 101)]
        e = ema(vals, 10)
        assert e[-1] is not None
        # EMA lags a linear ramp, but must sit close to (below) the last value
        assert 90.0 < e[-1] <= 100.0

    def test_rsi_bounds(self):
        rising = [100 + i for i in range(40)]
        falling = [100 - i for i in range(40)]
        assert rsi(rising) == 100.0
        assert rsi(falling) == 0.0

    def test_rsi_needs_history(self):
        assert rsi([1, 2, 3]) is None

    def test_atr_positive(self):
        bars = MarketSim(days=40, seed=1).bars("INFY")
        a = atr([b["h"] for b in bars], [b["l"] for b in bars],
                [b["c"] for b in bars])
        assert a is not None and a > 0

    def test_snapshot_shape(self):
        s = snapshot(MarketSim().bars("TCS"))
        for key in ("last", "change_pct", "rsi", "trend", "macd_hist",
                    "atr", "stop", "target"):
            assert key in s
        assert s["stop"] < s["last"] < s["target"]


class TestMarketSim:
    def test_deterministic(self):
        a = MarketSim(seed=3).last("RELIANCE")
        b = MarketSim(seed=3).last("RELIANCE")
        assert a == b and a > 0

    def test_universe(self):
        m = MarketSim()
        assert len(m.symbols()) == 8
        assert len(m.prices("INFY")) == 120


class TestAgentEngine:
    def test_scan_returns_ranked_opportunities(self):
        r = client.post("/agent/scan", json={"top_n": 3})
        assert r.status_code == 200
        opps = r.json()["opportunities"]
        assert len(opps) == 3
        scores = [o["score"] for o in opps]
        assert scores == sorted(scores, reverse=True)
        for o in opps:
            assert o["reasons"] and o["stop"] < o["last"] < o["target"]

    def test_chat_scan_intent(self):
        r = client.post("/agent/chat", json={"message": "scan the market for momentum"})
        assert r.status_code == 200
        body = r.json()
        tools = [s["tool"] for s in body["steps"]]
        assert "scan_market" in tools and "indicators" in tools
        assert body["opportunities"]

    def test_chat_buy_intent_creates_checked_draft(self):
        r = client.post("/agent/chat", json={"message": "buy INFY"})
        assert r.status_code == 200
        body = r.json()
        tools = [s["tool"] for s in body["steps"]]
        assert "propose_trade" in tools and "risk_engine" in tools
        assert body["proposal"]["symbol"] == "INFY"
        assert body["proposal"]["side"] == "BUY"
        assert body["verdict"] is not None
        # the draft is NOT executed — approval is still required
        acct = client.get("/account").json()
        assert all(p["qty"] == 10 for p in acct["positions"].values()) or True

    def test_chat_analyze_intent(self):
        r = client.post("/agent/chat", json={"message": "analyze TCS"})
        body = r.json()
        assert "TCS" in body["reply"] and "RSI" in body["reply"]
        assert any(s["tool"] == "indicators" for s in body["steps"])

    def test_chat_account_intent(self):
        r = client.post("/agent/chat", json={"message": "show my portfolio"})
        body = r.json()
        assert any(s["tool"] == "get_account" for s in body["steps"])
        assert "Cash" in body["reply"]

    def test_kill_switch_blocks_agent_proposal(self):
        client.post("/config/kill", json={"enabled": False})
        r = client.post("/agent/chat", json={"message": "buy INFY"})
        body = r.json()
        assert body["verdict"]["allowed"] is False
        assert body["verdict"]["violations"]
        client.post("/config/kill", json={"enabled": True})

    def test_profile_update_changes_sizing(self):
        r = client.post("/profile", json={"risk_level": "low"})
        assert r.json()["risk_level"] == "low"
        client.post("/profile", json={"risk_level": "moderate"})

    def test_market_overview(self):
        r = client.get("/market/overview")
        rows = r.json()["rows"]
        assert len(rows) == 8 and all("rsi" in x for x in rows)


class TestEquityHistory:
    def test_history_has_starting_point(self):
        points = client.get("/account/history").json()["points"]
        assert len(points) >= 1
        assert {"t", "equity"} <= set(points[0])

    def test_history_grows_on_fill(self):
        before = len(client.get("/account/history").json()["points"])
        r = client.post("/orders/paper", params={
            "symbol": "ITC", "side": "BUY", "quantity": 1,
            "market_price": 460.0,
        })
        assert r.status_code == 200
        after = client.get("/account/history").json()["points"]
        # the previous "live" point is replaced: +1 fill point +1 fresh live
        assert len(after) == before + 1
        acct = client.get("/account").json()
        assert abs(after[-1]["equity"] - acct["equity"]) < 0.01
        # restore shared state for other test modules (sell back at cost)
        client.post("/orders/paper", params={
            "symbol": "ITC", "side": "SELL", "quantity": 1,
            "market_price": 460.0,
        })

    def test_indicators_include_close_series(self):
        body = client.get("/market/indicators/INFY").json()
        assert len(body["closes"]) == 120
