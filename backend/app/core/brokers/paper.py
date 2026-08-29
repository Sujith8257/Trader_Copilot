"""PaperBroker — simulated fills against virtual cash.

This is the default (and mandatory starting) account mode of Trader Copilot.
It implements the same BrokerClient surface a live broker pack will, so the
trading engine, Risk Engine, and journal can be built and tested entirely on
paper before any real-money integration exists.
"""

from __future__ import annotations

from typing import Optional

from ..models import (
    AccountMode,
    AccountState,
    BrokerHealth,
    Order,
    OrderStatus,
    Position,
    Side,
    utcnow,
)
from .base import BrokerClient


class PaperBroker(BrokerClient):
    name = "paper"

    def __init__(self, account_id: str, initial_cash: float = 1_000_000.0) -> None:
        self._account = AccountState(
            account_id=account_id,
            mode=AccountMode.PAPER,
            cash=initial_cash,
            day_start_equity=initial_cash,
        )
        self._orders: dict[str, Order] = {}

    # -- BrokerClient surface ------------------------------------------- #
    def health(self) -> BrokerHealth:
        return BrokerHealth.HEALTHY

    def get_account(self) -> AccountState:
        return self._account

    def place_order(self, order: Order, market_price: float) -> Order:
        if market_price <= 0:
            order.status = OrderStatus.REJECTED
            self._orders[order.order_id] = order
            return order
        if self._is_marketable(order, market_price):
            self._fill(order, market_price)
        else:
            # Resting order: stays pending until a matching price arrives.
            order.account_id = self._account.account_id
            self._account.open_orders.append(order)
        self._orders[order.order_id] = order
        return order

    def cancel_order(self, order_id: str) -> Optional[Order]:
        order = self._orders.get(order_id)
        if order is None or order.status != OrderStatus.PENDING:
            return None
        order.status = OrderStatus.CANCELLED
        self._account.open_orders = [
            o for o in self._account.open_orders if o.order_id != order_id
        ]
        return order

    def get_order(self, order_id: str) -> Optional[Order]:
        return self._orders.get(order_id)

    # -- Paper-specific helpers ------------------------------------------ #
    def on_market_tick(self, symbol: str, price: float) -> list[Order]:
        """Feed a price tick; fills any resting limit orders that became marketable."""
        filled: list[Order] = []
        for order in list(self._account.open_orders):
            if order.symbol == symbol and self._is_marketable(order, price):
                self._fill(order, price)
                self._account.open_orders = [
                    o for o in self._account.open_orders if o.order_id != order.order_id
                ]
                filled.append(order)
        if symbol in self._account.positions:
            self._account.positions[symbol].current_price = price
        return filled

    def mark_all(self, prices: dict[str, float]) -> None:
        """Update current prices for mark-to-market equity."""
        for symbol, price in prices.items():
            if symbol in self._account.positions:
                self._account.positions[symbol].current_price = price

    # -- internals ---------------------------------------------------------- #
    @staticmethod
    def _is_marketable(order: Order, market_price: float) -> bool:
        if order.order_type.value == "MARKET":
            return True
        if order.limit_price is None:
            return False
        if order.side == Side.BUY:
            return market_price <= order.limit_price
        return market_price >= order.limit_price

    def _fill(self, order: Order, price: float) -> None:
        order.status = OrderStatus.FILLED
        order.filled_price = price
        order.filled_at = utcnow()
        order.account_id = self._account.account_id

        qty = order.quantity
        if order.side == Side.BUY:
            cost = qty * price
            self._account.cash -= cost
            pos = self._account.positions.get(order.symbol)
            if pos is None:
                self._account.positions[order.symbol] = Position(
                    symbol=order.symbol, quantity=qty, avg_price=price, current_price=price
                )
            else:
                total_qty = pos.quantity + qty
                pos.avg_price = (pos.avg_price * pos.quantity + cost) / total_qty
                pos.quantity = total_qty
                pos.current_price = price
        else:  # SELL
            proceeds = qty * price
            self._account.cash += proceeds
            pos = self._account.positions.get(order.symbol)
            if pos is not None:
                pnl = (price - pos.avg_price) * qty
                self._account.realized_pnl_today += pnl
                pos.quantity -= qty
                if pos.quantity <= 1e-9:
                    del self._account.positions[order.symbol]
        self._account.trades_today += 1
