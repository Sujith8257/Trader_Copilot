"""CoinbaseBroker — the LIVE broker pack for Coinbase Advanced Trade.

Implements the same BrokerClient surface as PaperBroker, so the Risk Engine
and trading engine need zero changes. Key properties:

* Real money. place_order() submits REAL market orders to Coinbase — it is
  only reachable behind the Risk Engine + explicit user approval, exactly
  like every other execution path.
* The account is the REAL Coinbase account: fiat + crypto balances pulled
  live. Positions are marked at live Coinbase prices (INR-converted) so the
  whole app stays in one currency.
* No credentials configured -> health DISABLED and every order is rejected;
  the paper surfaces keep working untouched.
"""

from __future__ import annotations

import os
from typing import Optional

from ..coinbase import CoinbaseClient, CoinbaseError, COINBASE_PRODUCTS
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


class CoinbaseBroker(BrokerClient):
    name = "coinbase"

    def __init__(self, client: Optional[CoinbaseClient] = None,
                 market: Optional[object] = None) -> None:
        self.client = client or CoinbaseClient()
        self.market = market  # LiveCoinbaseMarket, for INR price marks
        self._account = AccountState(
            account_id="coinbase-live", mode=AccountMode.LIVE, cash=0.0
        )
        self._orders: dict[str, Order] = {}
        self._health: BrokerHealth = BrokerHealth.OFFLINE
        self.last_error: Optional[str] = None

    # -- config --------------------------------------------------------------- #
    @property
    def quote(self) -> str:
        """Quote currency for order products (USDC is the most common funding
        path for Coinbase users outside the US). Env: COINBASE_QUOTE."""
        return os.getenv("COINBASE_QUOTE", "USDC").upper()

    def product(self, symbol: str) -> str:
        return f"{symbol.strip().upper()}-{self.quote}"

    # -- BrokerClient surface -------------------------------------------------- #
    def health(self) -> BrokerHealth:
        if not self.client.configured:
            return BrokerHealth.DISABLED
        return self._health

    def get_account(self) -> AccountState:
        if not self.client.configured:
            self.last_error = "Coinbase credentials not configured."
            return self._account
        try:
            accounts = self.client.get_accounts()
            self._health = BrokerHealth.HEALTHY
            self.last_error = None
        except CoinbaseError as e:
            self._health = BrokerHealth.OFFLINE
            self.last_error = str(e)
            return self._account

        acct = AccountState(
            account_id="coinbase-live", mode=AccountMode.LIVE,
            day_start_equity=self._account.day_start_equity,
            realized_pnl_today=self._account.realized_pnl_today,
            trades_today=self._account.trades_today,
        )
        fx = None
        if self.market is not None:
            try:
                fx = self.market._usd_inr()
            except Exception:  # noqa: BLE001 - marking falls back to 0 fx
                fx = None
        for a in accounts:
            bal = float((a.get("available_balance") or {}).get("value") or 0.0)
            if bal <= 0:
                continue
            cur = (a.get("currency") or "").upper()
            if cur in ("USD", "USDC", "INR", "EUR", "GBP"):
                if fx and cur in ("USD", "USDC"):
                    acct.cash += bal * fx
                else:
                    acct.cash += bal  # native fiat needs no conversion
            else:
                sym = cur
                price = 0.0
                if sym in COINBASE_PRODUCTS and self.market is not None:
                    try:
                        price = self.market.last(sym)
                    except Exception:  # noqa: BLE001
                        price = 0.0
                acct.positions[sym] = Position(
                    symbol=sym, quantity=bal, avg_price=price, current_price=price
                )
        acct.open_orders = list(self._account.open_orders)
        self._account = acct
        return acct

    def place_order(self, order: Order, market_price: float) -> Order:
        if not self.client.configured:
            order.status = OrderStatus.REJECTED
            self._orders[order.order_id] = order
            return order
        try:
            if order.side == Side.BUY:
                # our prices are INR; quote_size must be in the quote currency
                fx = self.market._usd_inr() if self.market is not None else 1.0
                quote = order.quantity * market_price / max(fx, 1e-9)
                resp = self.client.market_order(
                    self.product(order.symbol), "BUY", quote_size=f"{quote:.2f}"
                )
            else:
                resp = self.client.market_order(
                    self.product(order.symbol), "SELL",
                    base_size=f"{order.quantity:.8f}",
                )
        except CoinbaseError as e:
            self.last_error = str(e)
            order.status = OrderStatus.REJECTED
            self._orders[order.order_id] = order
            return order

        if resp.get("success"):
            order.status = OrderStatus.FILLED
            order.filled_price = market_price
            order.filled_at = utcnow()
            order.account_id = "coinbase-live"
            if resp.get("order_id"):
                order.order_id = resp["order_id"]
        else:
            self.last_error = resp.get("failure_reason") or "order rejected by Coinbase"
            order.status = OrderStatus.REJECTED
        self._orders[order.order_id] = order
        return order

    def cancel_order(self, order_id: str) -> Optional[Order]:
        # Market IOC orders fill or die immediately; nothing to cancel.
        return self._orders.get(order_id)

    def get_order(self, order_id: str) -> Optional[Order]:
        order = self._orders.get(order_id)
        if order is not None:
            return order
        if not self.client.configured:
            return None
        try:
            body = self.client.get_order(order_id)
        except CoinbaseError:
            return None
        o = body.get("order") or {}
        return {
            "order_id": o.get("order_id"),
            "product_id": o.get("product_id"),
            "side": o.get("side"),
            "status": o.get("status"),
            "filled_size": o.get("filled_size"),
            "average_filled_price": o.get("average_filled_price"),
        }

    def supports_symbol(self, symbol: str) -> bool:
        return symbol.strip().upper() in COINBASE_PRODUCTS
