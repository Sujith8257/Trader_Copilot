"""Trader Copilot backend API.

The API exposes the deterministic trading core. Note the layering:
an AI model may only ever submit a TradeProposal to /proposals/evaluate —
the Risk Engine decides what happens next, never the model itself.
"""

from __future__ import annotations

from typing import Optional

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from .core.agent import AgentEngine, AgentResult, TradingProfile
from .core.brokers.paper import PaperBroker
from .core.indicators import snapshot
from .core.market import MarketSim
from .core.models import AccountMode, Order, OrderType, RiskConfig, Side, TradeProposal
from .core.risk_engine import RiskEngine

app = FastAPI(
    title="Trader Copilot API",
    version="0.1.0",
    description="Deterministic trading core: risk engine + paper broker.",
)

# The Flutter app (web) runs on a different origin during development.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # dev only; restrict before any public deployment
    allow_methods=["*"],
    allow_headers=["*"],
)

# -- Session state (in-memory for Phase 1; persistence arrives in Phase 2) ---- #
engine = RiskEngine(RiskConfig())
paper = PaperBroker(account_id="paper-primary", initial_cash=1_000_000.0)
market = MarketSim()
profile = TradingProfile()
agent = AgentEngine(market, engine, paper, profile)


class ProposalIn(BaseModel):
    symbol: str
    side: Side
    quantity: float = Field(gt=0)
    entry_price: Optional[float] = None
    stop_loss: Optional[float] = None
    take_profit: Optional[float] = None
    rationale: str = ""
    confidence: Optional[float] = Field(default=None, ge=0, le=1)
    source: str = "ai"
    market_price: float = Field(gt=0)
    market_open: bool = True


@app.get("/health")
def health() -> dict:
    broker = paper.health()
    return {
        "status": "ok",
        "risk_engine_enabled": engine.config.enabled,
        "paper_broker": broker.value,
    }


@app.get("/account")
def account() -> dict:
    acct = paper.get_account()
    return {
        "account_id": acct.account_id,
        "mode": acct.mode.value if isinstance(acct.mode, AccountMode) else acct.mode,
        "cash": acct.cash,
        "equity": acct.equity,
        "day_start_equity": acct.day_start_equity,
        "positions": {
            s: {"qty": p.quantity, "avg": p.avg_price, "last": p.current_price}
            for s, p in acct.positions.items()
        },
    }


@app.post("/proposals/evaluate")
def evaluate_proposal(proposal: ProposalIn) -> dict:
    """Run a trade proposal (from the on-device AI or the user) through the
    deterministic Risk Engine. Nothing is executed here — evaluation only."""
    tp = TradeProposal(
        symbol=proposal.symbol,
        side=proposal.side,
        quantity=proposal.quantity,
        entry_price=proposal.entry_price,
        stop_loss=proposal.stop_loss,
        take_profit=proposal.take_profit,
        rationale=proposal.rationale,
        confidence=proposal.confidence,
        source=proposal.source,
    )
    verdict = engine.evaluate(tp, paper.get_account(), proposal.market_price, proposal.market_open)
    return {
        "allowed": verdict.allowed,
        "violations": verdict.violations,
        "warnings": verdict.warnings,
    }


@app.post("/orders/paper")
def place_paper_order(symbol: str, side: Side, quantity: float, market_price: float,
                      order_type: OrderType = OrderType.MARKET,
                      limit_price: Optional[float] = None) -> dict:
    """Place an order on the paper broker (simulated execution only)."""
    order = Order(
        symbol=symbol.upper(),
        side=side,
        quantity=quantity,
        order_type=order_type,
        limit_price=limit_price,
    )
    result = paper.place_order(order, market_price)
    return {
        "order_id": result.order_id,
        "status": result.status.value,
        "filled_price": result.filled_price,
    }


# -- Agentic Copilot + Market Intelligence ----------------------------------- #

class ChatIn(BaseModel):
    message: str


class ScanIn(BaseModel):
    top_n: int = Field(default=3, ge=1, le=8)


class KillIn(BaseModel):
    enabled: bool


class ProfileIn(BaseModel):
    risk_level: Optional[str] = None
    max_position: Optional[float] = None


@app.get("/market/overview")
def market_overview() -> dict:
    """Compact indicator read-out for the whole universe (the AI Radar)."""
    rows = []
    for sym in market.symbols():
        s = snapshot(market.bars(sym))
        rows.append({"symbol": sym, "last": s["last"],
                     "change_pct": s["change_pct"], "rsi": s["rsi"],
                     "trend": s["trend"]})
    return {"rows": rows}


@app.get("/market/indicators/{symbol}")
def market_indicators(symbol: str) -> dict:
    return {"symbol": symbol.upper(), **snapshot(market.bars(symbol))}


@app.post("/agent/chat")
def agent_chat(body: ChatIn) -> dict:
    """Agentic endpoint: the copilot reasons over tools (scan, indicators,
    account, propose+risk-check) and returns a visible trace plus — at most —
    a proposal DRAFT. Nothing executes here."""
    r = agent.handle(body.message)
    return {
        "brain": agent.brain,
        "reply": r.reply,
        "steps": [s.as_dict() for s in r.steps],
        "proposal": r.proposal,
        "verdict": r.verdict,
        "opportunities": r.opportunities,
    }


@app.post("/agent/scan")
def agent_scan(body: ScanIn) -> dict:
    r = AgentResult()
    agent._tool_scan(r, body.top_n)  # reuse the same scoring tool directly
    return {"opportunities": r.opportunities}


@app.post("/config/kill")
def kill_switch(body: KillIn) -> dict:
    """Global kill switch: disabled = every proposal is blocked, AI or manual."""
    engine.config.enabled = body.enabled
    return {"trading_enabled": engine.config.enabled}


@app.post("/profile")
def update_profile(body: ProfileIn) -> dict:
    """Explicit AI memory — the user owns these limits."""
    if body.risk_level in ("low", "moderate", "aggressive"):
        profile.risk_level = body.risk_level
    if body.max_position is not None and body.max_position > 0:
        profile.max_position = body.max_position
    return {"risk_level": profile.risk_level, "max_position": profile.max_position}
