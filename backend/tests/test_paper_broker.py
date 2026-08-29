"""Tests for the PaperBroker: simulated fills, positions, and cash flow."""

import pytest

from app.core.brokers.paper import PaperBroker
from app.core.models import (
    AccountMode,
    BrokerHealth,
    Order,
    OrderType,
    OrderStatus,
    Side,
)


def make_broker(cash: float = 100_000.0) -> PaperBroker:
    return PaperBroker(account_id="paper-test", initial_cash=cash)


def market_order(symbol: str, side: Side, qty: float) -> Order:
    return Order(symbol=symbol, side=side, quantity=qty, order_type=OrderType.MARKET)


def limit_order(symbol: str, side: Side, qty: float, limit: float) -> Order:
    return Order(symbol=symbol, side=side, quantity=qty, order_type=OrderType.LIMIT, limit_price=limit)


# ------------------------------------------------------------------ basics -- #

def test_paper_broker_health_and_mode():
    b = make_broker()
    assert b.health() == BrokerHealth.HEALTHY
    assert b.get_account().mode == AccountMode.PAPER
    assert b.get_account().cash == 100_000.0


def test_market_buy_fills_immediately_and_updates_cash():
    b = make_broker()
    o = b.place_order(market_order("RELIANCE", Side.BUY, 10), market_price=2_450.0)
    assert o.status == OrderStatus.FILLED
    assert o.filled_price == 2_450.0
    acct = b.get_account()
    assert acct.cash == pytest.approx(100_000.0 - 24_500.0)
    assert acct.positions["RELIANCE"].quantity == 10
    assert acct.positions["RELIANCE"].avg_price == pytest.approx(2_450.0)
    assert acct.trades_today == 1


def test_market_sell_realizes_pnl_and_reduces_position():
    b = make_broker()
    b.place_order(market_order("RELIANCE", Side.BUY, 10), market_price=2_400.0)
    o = b.place_order(market_order("RELIANCE", Side.SELL, 10), market_price=2_500.0)
    assert o.status == OrderStatus.FILLED
    acct = b.get_account()
    assert "RELIANCE" not in acct.positions
    assert acct.realized_pnl_today == pytest.approx(1_000.0)
    assert acct.cash == pytest.approx(100_000.0 + 1_000.0)


def test_partial_sell_keeps_remaining_position():
    b = make_broker()
    b.place_order(market_order("RELIANCE", Side.BUY, 10), market_price=2_400.0)
    b.place_order(market_order("RELIANCE", Side.SELL, 4), market_price=2_500.0)
    pos = b.get_account().positions["RELIANCE"]
    assert pos.quantity == pytest.approx(6)
    assert b.get_account().realized_pnl_today == pytest.approx(400.0)


def test_limit_buy_rests_until_price_reaches_limit():
    b = make_broker()
    o = b.place_order(limit_order("RELIANCE", Side.BUY, 10, limit=2_400.0), market_price=2_450.0)
    assert o.status == OrderStatus.PENDING
    assert len(b.get_account().open_orders) == 1

    filled = b.on_market_tick("RELIANCE", 2_430.0)  # above limit -> no fill
    assert filled == []

    filled = b.on_market_tick("RELIANCE", 2_395.0)  # below limit -> fills
    assert len(filled) == 1
    assert filled[0].filled_price == pytest.approx(2_395.0)
    assert b.get_account().open_orders == []


def test_limit_sell_fills_when_price_rises():
    b = make_broker()
    b.place_order(market_order("RELIANCE", Side.BUY, 10), market_price=2_400.0)
    o = b.place_order(limit_order("RELIANCE", Side.SELL, 10, limit=2_550.0), market_price=2_450.0)
    assert o.status == OrderStatus.PENDING
    filled = b.on_market_tick("RELIANCE", 2_560.0)
    assert len(filled) == 1
    assert filled[0].status == OrderStatus.FILLED


def test_cancel_removes_pending_order():
    b = make_broker()
    o = b.place_order(limit_order("RELIANCE", Side.BUY, 10, limit=2_400.0), market_price=2_450.0)
    cancelled = b.cancel_order(o.order_id)
    assert cancelled is not None
    assert cancelled.status == OrderStatus.CANCELLED
    assert b.get_account().open_orders == []
    assert b.cancel_order(o.order_id) is None  # already terminal


def test_invalid_price_rejects_order():
    b = make_broker()
    o = b.place_order(market_order("RELIANCE", Side.BUY, 10), market_price=-1.0)
    assert o.status == OrderStatus.REJECTED
    assert b.get_account().cash == 100_000.0


def test_mark_all_updates_equity():
    b = make_broker()
    b.place_order(market_order("RELIANCE", Side.BUY, 10), market_price=2_400.0)
    b.mark_all({"RELIANCE": 2_500.0})
    acct = b.get_account()
    assert acct.positions["RELIANCE"].current_price == pytest.approx(2_500.0)
    assert acct.equity == pytest.approx(acct.cash + 25_000.0)
