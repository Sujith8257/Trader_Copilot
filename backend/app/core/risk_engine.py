"""Deterministic Risk Engine.

RULE #1 of Trader Copilot: an LLM can only *propose* a trade. This module is
pure, deterministic code that decides whether a proposal may proceed. It never
performs I/O and never calls a model, so it is fully unit-testable.

Every check appends a human-readable violation (hard block) or warning (pass
with note) to the verdict — the user always sees *why*.
"""

from __future__ import annotations

from typing import Optional

from .models import (
    AccountState,
    Order,
    OrderStatus,
    RiskConfig,
    RiskVerdict,
    Side,
    TradeProposal,
)


class RiskEngine:
    def __init__(self, config: Optional[RiskConfig] = None) -> None:
        self.config = config or RiskConfig()

    # ------------------------------------------------------------------ #
    def evaluate(
        self,
        proposal: TradeProposal,
        account: AccountState,
        market_price: float,
        market_open: bool = True,
    ) -> RiskVerdict:
        cfg = self.config
        verdict = RiskVerdict(allowed=True)

        # 1. Kill switch -------------------------------------------------
        if not cfg.enabled:
            verdict.block("Kill switch is ACTIVE — all trading is disabled.")
            return verdict  # nothing else matters

        # 2. Market hours ------------------------------------------------
        if cfg.enforce_market_hours and not market_open:
            verdict.block("Market is closed — order rejected.")

        # 3. Symbol & quantity validity -----------------------------------
        symbol = (proposal.symbol or "").strip().upper()
        if not symbol:
            verdict.block("Proposal has no symbol.")
        elif not symbol.replace(".", "").replace("-", "").isalnum():
            verdict.block(f"Invalid symbol format: {proposal.symbol!r}.")
        if proposal.quantity is None or proposal.quantity <= 0:
            verdict.block(f"Quantity must be positive (got {proposal.quantity}).")
            return verdict

        if market_price <= 0:
            verdict.block(f"Market price must be positive (got {market_price}).")
            return verdict

        # 4. Available cash ------------------------------------------------
        cost = proposal.quantity * market_price
        if proposal.side == Side.BUY and cost > account.cash:
            verdict.block(
                f"Insufficient cash: order needs {cost:,.2f} but account has "
                f"{account.cash:,.2f}."
            )

        # 5. Max single-position notional ----------------------------------
        if cost > cfg.max_position_notional:
            verdict.block(
                f"Order notional {cost:,.2f} exceeds max position size "
                f"{cfg.max_position_notional:,.2f}."
            )

        # 6. Max open positions ---------------------------------------------
        is_new_symbol = symbol not in account.positions
        if proposal.side == Side.BUY and is_new_symbol:
            if len(account.positions) >= cfg.max_open_positions:
                verdict.block(
                    f"Max open positions reached ({cfg.max_open_positions})."
                )

        return self._evaluate_late_checks(proposal, account, market_price, verdict, cost, symbol)

    # ------------------------------------------------------------------ #
    def _evaluate_late_checks(
        self,
        proposal: TradeProposal,
        account: AccountState,
        market_price: float,
        verdict: RiskVerdict,
        cost: float,
        symbol: str,
    ) -> RiskVerdict:
        cfg = self.config

        # 7. Max portfolio exposure -------------------------------------------
        if proposal.side == Side.BUY:
            projected = account.gross_exposure + cost
            equity = max(account.equity, 1e-9)
            exposure_pct = projected / equity
            if exposure_pct > cfg.max_portfolio_exposure_pct + 1e-9:
                verdict.block(
                    f"Projected exposure {exposure_pct:.1%} exceeds limit "
                    f"{cfg.max_portfolio_exposure_pct:.1%}."
                )
            elif exposure_pct > cfg.max_portfolio_exposure_pct * 0.9:
                verdict.warn(
                    f"Projected exposure {exposure_pct:.1%} is close to the "
                    f"{cfg.max_portfolio_exposure_pct:.1%} limit."
                )

        # 8. Stop-loss requirement & sanity -------------------------------------
        if cfg.stop_loss_required and proposal.stop_loss is None:
            verdict.block("A stop-loss is required by your risk profile.")
        if proposal.stop_loss is not None and proposal.side == Side.BUY:
            ref = proposal.entry_price or market_price
            if proposal.stop_loss >= ref:
                verdict.block(
                    f"For a BUY, stop-loss ({proposal.stop_loss}) must be below "
                    f"the entry reference ({ref:,.2f})."
                )
            if proposal.take_profit is not None and proposal.take_profit <= ref:
                verdict.block(
                    f"For a BUY, take-profit ({proposal.take_profit}) must be "
                    f"above the entry reference ({ref:,.2f})."
                )

        # 9. Duplicate-order protection -------------------------------------------
        for pending in account.open_orders:
            if (
                pending.status == OrderStatus.PENDING
                and pending.symbol == symbol
                and pending.side == proposal.side
            ):
                verdict.block(
                    f"Duplicate order protection: a pending {proposal.side.value} "
                    f"order for {symbol} already exists."
                )
                break

        # 10. Max trades per day ----------------------------------------------------
        if account.trades_today >= cfg.max_trades_per_day:
            verdict.block(
                f"Daily trade limit reached ({account.trades_today}/"
                f"{cfg.max_trades_per_day})."
            )

        # 11. Max daily loss ----------------------------------------------------------
        day_equity = max(account.day_start_equity, 1e-9)
        if cfg.max_daily_loss_abs is not None and account.realized_pnl_today <= -cfg.max_daily_loss_abs:
            verdict.block(
                f"Daily loss limit hit: {account.realized_pnl_today:,.2f} <= "
                f"-{cfg.max_daily_loss_abs:,.2f}."
            )
        loss_pct_limit = day_equity * cfg.max_daily_loss_pct
        if account.realized_pnl_today <= -loss_pct_limit:
            verdict.block(
                f"Daily loss {account.realized_pnl_today:,.2f} exceeds "
                f"{cfg.max_daily_loss_pct:.1%} of day-start equity "
                f"({day_equity:,.2f})."
            )

        # 12. Entry-vs-market price deviation --------------------------------------------
        if proposal.entry_price is not None and proposal.entry_price > 0:
            deviation = abs(proposal.entry_price - market_price) / market_price
            if deviation > cfg.max_price_deviation_pct:
                verdict.block(
                    f"Proposal entry {proposal.entry_price:,.2f} deviates "
                    f"{deviation:.2%} from market price {market_price:,.2f} "
                    f"(limit {cfg.max_price_deviation_pct:.2%})."
                )

        # Confidence honesty ----------------------------------------------------------------
        if proposal.source == "ai" and proposal.confidence is not None:
            if not 0.0 <= proposal.confidence <= 1.0:
                verdict.warn("AI confidence is out of range — treat as unreliable.")
            else:
                verdict.warn(
                    "AI confidence is an assessment, not a probability of success."
                )

        return verdict


def duplicate_pending_order(account: AccountState, symbol: str, side: Side) -> Optional[Order]:
    """Utility used by the paper engine to look up an existing pending order."""
    for order in account.open_orders:
        if order.symbol == symbol and order.side == side and order.status == OrderStatus.PENDING:
            return order
    return None
