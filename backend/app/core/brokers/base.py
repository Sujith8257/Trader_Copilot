"""Broker abstraction — the UTA-style unified account surface.

Inspired by OpenAlice's Unified Trading Account: the AI and the trading engine
talk to ONE account surface; each concrete broker adapts its own API, order
model, and error vocabulary behind this protocol. A missing broker pack
degrades only the accounts that need it — never the paper/research surfaces.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Optional

from ..models import AccountState, BrokerHealth, Order, OrderStatus


class BrokerClient(ABC):
    """Protocol every broker pack must implement."""

    name: str = "abstract"

    @abstractmethod
    def health(self) -> BrokerHealth:
        """Connection health: HEALTHY / DEGRADED / OFFLINE / DISABLED."""

    @abstractmethod
    def get_account(self) -> AccountState:
        """Current account snapshot: cash, positions, open orders."""

    @abstractmethod
    def place_order(self, order: Order, market_price: float) -> Order:
        """Submit an order. Returns the order with updated status.

        Must be idempotent on order_id. Must NEVER be called directly by an
        AI model — only by the trading engine after Risk Engine + approval.
        """

    @abstractmethod
    def cancel_order(self, order_id: str) -> Optional[Order]:
        """Cancel a pending order; returns the updated order or None."""

    @abstractmethod
    def get_order(self, order_id: str) -> Optional[Order]:
        """Fetch one order by id."""

    def supports_symbol(self, symbol: str) -> bool:  # noqa: ARG002 - default
        return True

    @staticmethod
    def _terminal(status: OrderStatus) -> bool:
        return status in (OrderStatus.FILLED, OrderStatus.CANCELLED, OrderStatus.REJECTED)
