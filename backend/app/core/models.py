"""Shared data models for the Trader Copilot trading core.

All models are plain dataclasses (no framework coupling) so the Risk Engine and
brokers stay pure and unit-testable. FastAPI adapters live in `app.api`.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Optional


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


class Side(str, Enum):
    BUY = "BUY"
    SELL = "SELL"


class OrderType(str, Enum):
    MARKET = "MARKET"
    LIMIT = "LIMIT"


class OrderStatus(str, Enum):
    PENDING = "PENDING"
    FILLED = "FILLED"
    CANCELLED = "CANCELLED"
    REJECTED = "REJECTED"


class AccountMode(str, Enum):
    PAPER = "PAPER"
    LIVE = "LIVE"


class BrokerHealth(str, Enum):
    """Broker connection health, modeled on OpenAlice UTA states."""

    HEALTHY = "HEALTHY"
    DEGRADED = "DEGRADED"
    OFFLINE = "OFFLINE"
    DISABLED = "DISABLED"


@dataclass
class Position:
    symbol: str
    quantity: float
    avg_price: float
    current_price: float = 0.0

    @property
    def market_value(self) -> float:
        return self.quantity * self.current_price

    @property
    def unrealized_pnl(self) -> float:
        return (self.current_price - self.avg_price) * self.quantity


@dataclass
class Order:
    symbol: str
    side: Side
    quantity: float
    order_type: OrderType = OrderType.MARKET
    limit_price: Optional[float] = None
    stop_loss: Optional[float] = None
    take_profit: Optional[float] = None
    status: OrderStatus = OrderStatus.PENDING
    order_id: str = field(default_factory=lambda: new_id("ord"))
    account_id: str = ""
    created_at: datetime = field(default_factory=utcnow)
    filled_price: Optional[float] = None
    filled_at: Optional[datetime] = None

    @property
    def notional(self) -> float:
        """Rough order value used for cash/exposure checks."""
        price = self.limit_price if self.limit_price is not None else 0.0
        return self.quantity * price


@dataclass
class AccountState:
    """Snapshot of one trading account (a UTA-style unified surface)."""

    account_id: str
    mode: AccountMode = AccountMode.PAPER
    cash: float = 0.0
    day_start_equity: float = 0.0
    realized_pnl_today: float = 0.0
    trades_today: int = 0
    positions: dict[str, Position] = field(default_factory=dict)
    open_orders: list[Order] = field(default_factory=list)

    @property
    def equity(self) -> float:
        return self.cash + sum(p.market_value for p in self.positions.values())

    @property
    def gross_exposure(self) -> float:
        return sum(p.market_value for p in self.positions.values())


@dataclass
class TradeProposal:
    """The ONLY output surface an AI model is allowed to produce.

    A proposal is an intent — it never executes anything by itself.
    """

    symbol: str
    side: Side
    quantity: float
    entry_price: Optional[float] = None
    stop_loss: Optional[float] = None
    take_profit: Optional[float] = None
    rationale: str = ""
    confidence: Optional[float] = None  # 0..1, an assessment — never a guarantee
    source: str = "ai"  # "ai" | "manual"
    created_at: datetime = field(default_factory=utcnow)


@dataclass
class RiskConfig:
    """Deterministic risk limits. Owned by the user, applied by code — never by the LLM."""

    enabled: bool = True  # global kill switch: False blocks every proposal
    enforce_market_hours: bool = True
    max_position_notional: float = 25_000.0
    max_open_positions: int = 10
    max_portfolio_exposure_pct: float = 0.80  # of equity
    stop_loss_required: bool = True
    max_trades_per_day: int = 20
    max_daily_loss_pct: float = 0.05  # of day-start equity
    max_daily_loss_abs: Optional[float] = None  # absolute floor, if set
    max_price_deviation_pct: float = 0.02  # proposal entry vs market price


@dataclass
class RiskVerdict:
    """Result of a deterministic risk evaluation, with user-readable reasons."""

    allowed: bool
    violations: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def block(self, reason: str) -> None:
        self.allowed = False
        self.violations.append(reason)

    def warn(self, message: str) -> None:
        self.warnings.append(message)
