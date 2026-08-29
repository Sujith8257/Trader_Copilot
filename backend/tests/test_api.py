"""Smoke test for the FastAPI surface."""

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["risk_engine_enabled"] is True
    assert body["paper_broker"] == "HEALTHY"


def test_account_starts_empty():
    r = client.get("/account")
    assert r.status_code == 200
    assert r.json()["cash"] == 1_000_000.0


def test_proposal_evaluation_allowed_and_blocked():
    ok = client.post(
        "/proposals/evaluate",
        json={
            "symbol": "RELIANCE", "side": "BUY", "quantity": 10,
            "stop_loss": 2_400.0, "take_profit": 2_550.0,
            "market_price": 2_450.0, "source": "ai", "confidence": 0.72,
        },
    )
    assert ok.status_code == 200
    assert ok.json()["allowed"] is True

    bad = client.post(
        "/proposals/evaluate",
        json={
            "symbol": "RELIANCE", "side": "BUY", "quantity": 10,
            "market_price": 2_450.0, "market_open": False,
        },
    )
    assert bad.json()["allowed"] is False
    assert any("Market is closed" in v for v in bad.json()["violations"])


def test_paper_order_roundtrip():
    r = client.post(
        "/orders/paper?symbol=INFY&side=BUY&quantity=5&market_price=1500.0"
    )
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "FILLED"
    assert body["filled_price"] == 1_500.0


def test_agent_probe_returns_brain_and_local_models():
    r = client.get("/agent/probe")
    assert r.status_code == 200
    body = r.json()
    assert body["brain"] in ("local", "llm")
    assert isinstance(body["local_models"], list) and len(body["local_models"]) >= 1
    assert "openai_configured" in body


def test_backtest_runs_without_touching_live_account():
    before = client.get("/account").json()["cash"]
    r = client.post("/backtest", json={"steps": 12, "warmup": 50})
    assert r.status_code == 200
    body = r.json()
    for key in ("final_equity", "total_return_pct", "max_drawdown_pct",
                "win_rate_pct", "trades", "equity_curve"):
        assert key in body
    assert len(body["equity_curve"]) == 12
    # the live paper broker must be untouched
    after = client.get("/account").json()["cash"]
    assert before == after


def test_websocket_streams_agent_trace():
    with client.websocket_connect("/ws/agent") as ws:
        ready = ws.receive_json()
        assert ready["type"] == "ready"

        ws.send_text('{"message": "scan the market"}')

        types = []
        last = None
        while True:
            msg = ws.receive_json()
            types.append(msg["type"])
            last = msg
            if msg["type"] == "done":
                break
            assert msg.get("type") in {"step", "opportunities", "reply", "error"}

    assert "step" in types
    assert "reply" in types
    assert last["type"] == "done"
    assert last["steps"]  # a real trace was streamed
    assert last["opportunities"]
# -- Crypto paper trading (24/7 market) --------------------------------------- #


def test_crypto_account_and_overview():
    r = client.get("/account?market=crypto")
    assert r.status_code == 200
    body = r.json()
    assert body["account_id"] == "crypto-paper"
    assert body["market"] == "crypto"
    assert body["cash"] == 1_000_000.0
    ov = client.get("/market/overview?market=crypto")
    syms = [row["symbol"] for row in ov.json()["rows"]]
    assert "BTC" in syms and "ETH" in syms


def test_crypto_agent_scans_only_crypto():
    r = client.post("/agent/chat", json={"message": "scan the market", "market": "crypto"})
    assert r.status_code == 200
    syms = {o["symbol"] for o in r.json()["opportunities"]}
    assert syms <= {"BTC", "ETH", "SOL", "BNB", "XRP", "ADA", "DOGE", "LINK"}
    # the stocks account is untouched by crypto activity
    assert client.get("/account").json()["account_id"] == "paper-primary"


def test_crypto_proposal_is_always_market_open():
    ok = client.post("/proposals/evaluate", json={
        "symbol": "BTC", "side": "BUY", "quantity": 0.001,
        "stop_loss": 5500000.0, "take_profit": 6200000.0,
        "market_price": 5800000.0, "market": "crypto", "market_open": False,
    })
    assert ok.status_code == 200
    assert ok.json()["allowed"] is True
