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
