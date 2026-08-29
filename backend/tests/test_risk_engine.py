"""Unit tests for the deterministic Risk Engine.

Every risk rule gets an explicit test. The Risk Engine must never change
behavior without a corresponding test update.
"""

from app.core.models import (
    AccountMode,
    AccountState,
    Order,
    OrderStatus,
    Position,
    RiskConfig,
    Side,
    TradeProposal,
)
from app.core.risk_engine import RiskEngine


def make_account(**overrides) -> AccountState:
    defaults = dict(
        account_id="test",
        mode=AccountMode.PAPER,
        cash=100_000.0,
        day_start_equity=100_000.0,
        realized_pnl_today=0.0,
        trades_today=0,
    )
    defaults.update(overrides)
    return AccountState(**defaults)


def make_proposal(**overrides) -> TradeProposal:
    defaults = dict(
        symbol="RELIANCE",
        side=Side.BUY,
        quantity=10,
        entry_price=2_450.0,
        stop_loss=2_400.0,
        take_profit=2_550.0,
        source="manual",
    )
    defaults.update(overrides)
    return TradeProposal(**defaults)


def evaluate(proposal=None, account=None, market_price=2_450.0, config=None, market_open=True):
    return RiskEngine(config).evaluate(
        proposal or make_proposal(),
        account or make_account(),
        market_price,
        market_open=market_open,
    )


# ------------------------------------------------------------------ rules -- #

def test_valid_proposal_is_allowed():
    v = evaluate()
    assert v.allowed
    assert v.violations == []


def test_kill_switch_blocks_everything():
    v = evaluate(config=RiskConfig(enabled=False))
    assert not v.allowed
    assert "Kill switch" in v.violations[0]


def test_market_closed_blocks():
    v = evaluate(market_open=False)
    assert not v.allowed
    assert "Market is closed" in v.violations[0]


def test_market_hours_can_be_disabled():
    v = evaluate(market_open=False, config=RiskConfig(enforce_market_hours=False))
    assert v.allowed


def test_blank_symbol_blocks():
    v = evaluate(proposal=make_proposal(symbol="  "))
    assert not v.allowed
    assert any("no symbol" in x for x in v.violations)


def test_invalid_symbol_blocks():
    v = evaluate(proposal=make_proposal(symbol="RELI@NCE"))
    assert not v.allowed


def test_zero_quantity_blocks():
    v = evaluate(proposal=make_proposal(quantity=0))
    assert not v.allowed


def test_insufficient_cash_blocks():
    acct = make_account(cash=2_000.0)
    v = evaluate(account=acct, market_price=2_450.0)  # needs 24,500
    assert not v.allowed
    assert any("Insufficient cash" in x for x in v.violations)


def test_max_position_notional_blocks():
    cfg = RiskConfig(max_position_notional=10_000.0)
    v = evaluate(config=cfg)  # 10 * 2450 = 24,500
    assert not v.allowed
    assert any("max position size" in x for x in v.violations)


def test_max_open_positions_blocks_new_symbol():
    acct = make_account()
    for i in range(3):
        acct.positions[f"S{i}"] = Position(symbol=f"S{i}", quantity=1, avg_price=100, current_price=100)
    v = evaluate(account=acct, config=RiskConfig(max_open_positions=3))
    assert not v.allowed
    assert any("Max open positions" in x for x in v.violations)


def test_existing_symbol_not_counted_as_new_position():
    acct = make_account()
    acct.positions["RELIANCE"] = Position(symbol="RELIANCE", quantity=1, avg_price=2_400, current_price=2_450)
    v = evaluate(account=acct, config=RiskConfig(max_open_positions=1))
    assert v.allowed


def test_portfolio_exposure_blocks():
    acct = make_account()
    acct.positions["BIG"] = Position(symbol="BIG", quantity=100, avg_price=900, current_price=900)
    v = evaluate(account=acct, config=RiskConfig(max_portfolio_exposure_pct=0.5))
    assert not v.allowed
    assert any("exposure" in x for x in v.violations)


def test_portfolio_exposure_warns_when_close():
    acct = make_account()
    acct.positions["BIG"] = Position(symbol="BIG", quantity=100, avg_price=860, current_price=860)
    v = evaluate(account=acct, config=RiskConfig(max_portfolio_exposure_pct=0.60))
    assert v.allowed
    assert any("close to the" in w for w in v.warnings)


def test_missing_stop_loss_blocks_when_required():
    v = evaluate(proposal=make_proposal(stop_loss=None))
    assert not v.allowed
    assert any("stop-loss is required" in x for x in v.violations)


def test_missing_stop_loss_ok_when_not_required():
    v = evaluate(proposal=make_proposal(stop_loss=None), config=RiskConfig(stop_loss_required=False))
    assert v.allowed


def test_stop_loss_above_entry_blocks_for_buy():
    v = evaluate(proposal=make_proposal(stop_loss=2_500.0))
    assert not v.allowed


def test_take_profit_below_entry_blocks_for_buy():
    v = evaluate(proposal=make_proposal(take_profit=2_300.0))
    assert not v.allowed


def test_duplicate_pending_order_blocks():
    acct = make_account()
    acct.open_orders.append(
        Order(symbol="RELIANCE", side=Side.BUY, quantity=5, status=OrderStatus.PENDING)
    )
    v = evaluate(account=acct)
    assert not v.allowed
    assert any("Duplicate order" in x for x in v.violations)


def test_max_trades_per_day_blocks():
    acct = make_account(trades_today=20)
    v = evaluate(account=acct, config=RiskConfig(max_trades_per_day=20))
    assert not v.allowed


def test_daily_loss_abs_blocks():
    acct = make_account(realized_pnl_today=-6_000.0, day_start_equity=100_000.0)
    v = evaluate(account=acct, config=RiskConfig(max_daily_loss_abs=5_000.0, max_daily_loss_pct=1.0))
    assert not v.allowed
    assert any("Daily loss limit hit" in x for x in v.violations)


def test_daily_loss_pct_blocks():
    acct = make_account(realized_pnl_today=-6_000.0, day_start_equity=100_000.0)
    v = evaluate(account=acct, config=RiskConfig(max_daily_loss_pct=0.05))
    assert not v.allowed
    assert any("of day-start equity" in x for x in v.violations)


def test_price_deviation_blocks():
    v = evaluate(proposal=make_proposal(entry_price=2_450.0), market_price=2_650.0)
    assert not v.allowed
    assert any("deviates" in x for x in v.violations)


def test_ai_confidence_adds_honesty_warning():
    v = evaluate(proposal=make_proposal(source="ai", confidence=0.72))
    assert v.allowed
    assert any("not a probability" in w for w in v.warnings)


def test_ai_confidence_out_of_range_warns():
    v = evaluate(proposal=make_proposal(source="ai", confidence=1.5))
    assert v.allowed
    assert any("out of range" in w for w in v.warnings)


def test_sell_ignores_cash_and_exposure_checks():
    acct = make_account()
    acct.positions["RELIANCE"] = Position(symbol="RELIANCE", quantity=10, avg_price=2_400, current_price=2_450)
    v = evaluate(proposal=make_proposal(side=Side.SELL))
    assert v.allowed
