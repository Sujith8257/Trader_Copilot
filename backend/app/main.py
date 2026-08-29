"""Trader Copilot backend API.

The API exposes the deterministic trading core. Note the layering:
an AI model may only ever submit a TradeProposal to /proposals/evaluate —
the Risk Engine decides what happens next, never the model itself.
"""

from __future__ import annotations

import asyncio
import json
import os
from typing import Optional

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from .core.agent import AgentEngine, AgentResult, TradingProfile
from .core.brokers.coinbase import CoinbaseBroker
from .core.brokers.paper import PaperBroker
from .core.coinbase import CoinbaseError, LiveCoinbaseMarket
from .core.indicators import snapshot
from .core.market import CRYPTO_UNIVERSE, MarketSim, SlicedMarket
from .core.models import (
        AccountMode,
    Order,
    OrderStatus,
    OrderType,
    RiskConfig,
    Side,
    TradeProposal,
    utcnow,
)
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

# Crypto paper account: 24/7 market riding the SAME BrokerClient interface.
# Market data is LIVE from Coinbase (no simulated data); set
# TRADER_CRYPTO_SOURCE=sim to fall back to the seeded simulator (used by the
# offline test suite).
if os.getenv("TRADER_CRYPTO_SOURCE", "live") == "sim":
    crypto_market = MarketSim(universe=CRYPTO_UNIVERSE, seed=11)
    crypto_source = "simulated"
else:
    crypto_market = LiveCoinbaseMarket()
    crypto_source = "coinbase-live"
crypto_paper = PaperBroker(account_id="crypto-paper", initial_cash=1_000_000.0)
crypto_agent = AgentEngine(crypto_market, engine, crypto_paper, profile)

# LIVE trading (real money): Coinbase Advanced Trade broker pack.
coinbase_live = CoinbaseBroker(market=crypto_market)


def _resolve(market_name: str) -> tuple:
    """Return the (broker, agent, market) for a market name: stocks | crypto."""
    if market_name == "crypto":
        return crypto_paper, crypto_agent, crypto_market
    return paper, agent, market


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
    market: str = "stocks"
    market_price: float = Field(gt=0)
    market_open: bool = True


@app.get("/health")
def health() -> dict:
    broker = paper.health()
    return {
        "status": "ok",
        "risk_engine_enabled": engine.config.enabled,
        "paper_broker": broker.value,
        "crypto_data_source": crypto_source,
        "crypto_market_status": (
            crypto_market.status()
            if hasattr(crypto_market, "status") else None
        ),
        "coinbase_live": {
            "configured": coinbase_live.client.configured,
            "health": coinbase_live.health().value,
            "quote": coinbase_live.quote,
            "last_error": coinbase_live.last_error,
        },
    }


@app.get("/account")
def account(market: str = Query("stocks"), mode: str = Query("paper")) -> dict:
    if market == "crypto" and mode == "live":
        acct = coinbase_live.get_account()
        return {
            "account_id": acct.account_id,
            "market": market,
            "mode": "LIVE",
            "cash": acct.cash,
            "equity": acct.equity,
            "day_start_equity": acct.day_start_equity,
            "broker_health": coinbase_live.health().value,
            "broker_error": coinbase_live.last_error,
            "quote": coinbase_live.quote,
            "positions": {
                s: {"qty": p.quantity, "avg": p.avg_price, "last": p.current_price}
                for s, p in acct.positions.items()
            },
        }
    acct = _resolve(market)[0].get_account()
    return {
        "account_id": acct.account_id,
        "market": market,
        "mode": acct.mode.value if isinstance(acct.mode, AccountMode) else acct.mode,
        "cash": acct.cash,
        "equity": acct.equity,
        "day_start_equity": acct.day_start_equity,
        "positions": {
            s: {"qty": p.quantity, "avg": p.avg_price, "last": p.current_price}
            for s, p in acct.positions.items()
        },
    }


@app.get("/account/history")
def account_history(market: str = Query("stocks")) -> dict:
    """Equity curve (one point per fill + starting point) for charts."""
    broker = _resolve(market)[0]
    points = broker.get_history()
    # Append the live equity so the chart reflects mark-to-market now.
    acct = broker.get_account()
    points = points + [{"t": utcnow().isoformat(), "equity": acct.equity}]
    return {"points": points}


@app.post("/proposals/evaluate")
def evaluate_proposal(proposal: ProposalIn) -> dict:
    """Run a trade proposal (from the on-device AI or the user) through the
    deterministic Risk Engine. Nothing is executed here — evaluation only.
    Crypto proposals are always market-open (crypto trades 24/7)."""
    broker = _resolve(proposal.market)[0]
    market_open = True if proposal.market == "crypto" else proposal.market_open
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
    verdict = engine.evaluate(tp, broker.get_account(), proposal.market_price, market_open)
    return {
        "allowed": verdict.allowed,
        "violations": verdict.violations,
        "warnings": verdict.warnings,
    }


@app.post("/orders/paper")
def place_paper_order(symbol: str, side: Side, quantity: float, market_price: float,
                      market: str = Query("stocks"),
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
    result = _resolve(market)[0].place_order(order, market_price)
    return {
        "order_id": result.order_id,
        "status": result.status.value,
        "filled_price": result.filled_price,
    }


class LiveOrderIn(BaseModel):
    symbol: str
    side: Side
    quantity: float = Field(gt=0)
    market_price: float = Field(gt=0)
    market: str = "crypto"
    stop_loss: Optional[float] = None
    take_profit: Optional[float] = None
    rationale: str = "user-approved live order"


@app.post("/orders/live")
def place_live_order(body: LiveOrderIn) -> dict:
    """REAL MONEY: place a market order on Coinbase after Risk Engine checks.

    The Risk Engine gates this exactly like a paper order — same limits, same
    kill switch. Crypto trades 24/7 so the market-hours rule never blocks it.
    Requires Coinbase credentials; the broker rejects if unfunded/offline."""
    if body.market != "crypto":
        return {"error": "Live orders are crypto-only right now: Coinbase does "
                         "not offer NSE stocks. Use /orders/paper for stocks."}
    market_open = True  # crypto is always open
    tp = TradeProposal(
        symbol=body.symbol.upper(), side=body.side, quantity=body.quantity,
        entry_price=body.market_price, stop_loss=body.stop_loss,
        take_profit=body.take_profit, rationale=body.rationale, source="manual",
    )
    verdict = engine.evaluate(
        tp, coinbase_live.get_account(), body.market_price, market_open
    )
    if not verdict.allowed:
        return {"executed": False, "risk": {
            "allowed": False, "violations": verdict.violations,
            "warnings": verdict.warnings}}
    order = Order(
        symbol=body.symbol.upper(), side=body.side, quantity=body.quantity,
        order_type=OrderType.MARKET, stop_loss=body.stop_loss,
        take_profit=body.take_profit,
    )
    result = coinbase_live.place_order(order, body.market_price)
    return {
        "executed": result.status == OrderStatus.FILLED,
        "order_id": result.order_id,
        "status": result.status.value,
        "filled_price": result.filled_price,
        "broker_error": coinbase_live.last_error,
        "risk": {"allowed": True, "violations": [], "warnings": verdict.warnings},
    }


# -- Agentic Copilot + Market Intelligence ----------------------------------- #

class ChatIn(BaseModel):
    message: str
    market: str = "stocks"


class ScanIn(BaseModel):
    top_n: int = Field(default=3, ge=1, le=8)
    market: str = "stocks"


class KillIn(BaseModel):
    enabled: bool


class ProfileIn(BaseModel):
    risk_level: Optional[str] = None
    max_position: Optional[float] = None


@app.get("/market/overview")
def market_overview(market: str = Query("stocks")) -> dict:
    """Compact indicator read-out for the whole universe (the AI Radar)."""
    sim = _resolve(market)[2]
    rows = []
    for sym in sim.symbols():
        s = snapshot(sim.bars(sym))
        rows.append({"symbol": sym, "last": s["last"],
                     "change_pct": s["change_pct"], "rsi": s["rsi"],
                     "trend": s["trend"]})
    return {"rows": rows}


@app.get("/market/indicators/{symbol}")
def market_indicators(symbol: str, market: str = Query("stocks")) -> dict:
    sim = _resolve(market)[2]
    return {
        "symbol": symbol.upper(),
        **snapshot(sim.bars(symbol)),
        "closes": sim.prices(symbol),  # full series for client charts
    }


@app.get("/market/candles/{symbol}")
def market_candles(symbol: str, market: str = Query("stocks"),
                   limit: int = Query(90, ge=10, le=350)) -> dict:
    """OHLCV bars for candlestick charts. LIVE Coinbase candles for crypto."""
    sim = _resolve(market)[2]
    bars = list(sim.bars(symbol))[-limit:]
    return {
        "symbol": symbol.upper(),
        "market": market,
        "source": getattr(sim, "status", lambda: {"source": "simulated"})()["source"],
        "bars": bars,
    }


@app.post("/agent/chat")
def agent_chat(body: ChatIn) -> dict:
    """Agentic endpoint: the copilot reasons over tools (scan, indicators,
    account, propose+risk-check) and returns a visible trace plus — at most —
    a proposal DRAFT. Nothing executes here."""
    ag = _resolve(body.market)[1]
    r = ag.handle(body.message)
    return {
        "brain": ag.brain,
        "reply": r.reply,
        "steps": [s.as_dict() for s in r.steps],
        "proposal": r.proposal,
        "verdict": r.verdict,
        "opportunities": r.opportunities,
    }


@app.post("/agent/scan")
def agent_scan(body: ScanIn) -> dict:
    r = AgentResult()
    _resolve(body.market)[1]._tool_scan(r, body.top_n)  # same scoring tool
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


# -- Agentic streaming -------------------------------------------------------- #


@app.websocket("/ws/agent")
async def ws_agent(ws: WebSocket) -> None:
    """Live, server-sent streaming of the agent's tool trace.

    The on-device Copilot listens here when `streaming` is enabled (Model Hub).
    The local brain computes a full AgentResult first, then ships each step in
    rapid sequence so the UI animates reasoning in real time; with an LLM brain
    the same channel carries tool calls back and forth. Proposal DRAFT only — the
    Risk Engine verdict still gates, and the user still approves, execution."""
    await ws.accept()
    await ws.send_json({"type": "ready", "brain": agent.brain})
    try:
        while True:
            raw = await ws.receive_text()
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                await ws.send_json({"type": "error", "error": "invalid JSON"})
                continue
            text = (msg.get("message") or "").strip()
            if not text:
                continue
            ag = _resolve(msg.get("market", "stocks"))[1]
            r = ag.handle(text)
            for st in r.steps:
                await ws.send_json({"type": "step", "step": st.as_dict()})
                await asyncio.sleep(0.05)  # "thinking in progress" feel
            if r.opportunities:
                await ws.send_json(
                    {"type": "opportunities", "opportunities": r.opportunities}
                )
            await ws.send_json({"type": "reply", "reply": r.reply})
            await ws.send_json({
                "type": "done",
                "brain": ag.brain,
                "reply": r.reply,
                "steps": [s.as_dict() for s in r.steps],
                "proposal": r.proposal,
                "verdict": r.verdict,
                "opportunities": r.opportunities,
            })
    except WebSocketDisconnect:
        pass


@app.get("/agent/probe")
def agent_probe() -> dict:
    """Model Hub info: which brain is active, LLM env, and the local LLM
    candidates the device can pull. RAM/CPU capability probing is done on the
    phone itself; the backend advertises the manifest + current wiring."""
    local_models = [
        {"id": "gemma3", "label": "Gemma 3 1B", "params": "1.0B", "ram": "1.2 GB"},
        {"id": "qwen2.5", "label": "Qwen2.5 0.5B", "params": "0.5B", "ram": "0.9 GB"},
        {"id": "phi3", "label": "Phi-3 mini 4K", "params": "3.8B", "ram": "4.0 GB"},
    ]
    return {
        "brain": agent.brain,
        "openai_configured": bool(os.getenv("OPENAI_API_KEY")),
        "model": (
            os.getenv("OPENAI_MODEL", "gpt-4o-mini")
            if agent.brain == "llm"
            else None
        ),
                "local_models": local_models,
    }


# -- Backtesting --------------------------------------------------------------- #


class BacktestIn(BaseModel):
    steps: int = Field(default=30, ge=5, le=60)
    capital: float = Field(default=1_000_000.0, gt=0)
    warmup: int = Field(default=50, ge=26)
    min_score: float = Field(default=1.0, ge=0)


@app.post("/backtest")
def backtest_run(body: BacktestIn) -> dict:
    """Backtest the Copilot's signal-following strategy against the seeded
    market. A fresh throwaway broker is used so the live paper account is never
    touched. Each day the agent only sees bars up to the warmup cutoff
    (SlicedMarket - no look-ahead), drafts a proposal for the top opportunity,
    and the Risk Engine gates it before a paper fill."""
    src = MarketSim()
    days = len(src.prices(next(iter(src.symbols()))))
    warmup = min(body.warmup, max(26, days - body.steps))
    bt_paper = PaperBroker(account_id="backtest", initial_cash=body.capital)
    bt_engine = RiskEngine(RiskConfig(stop_loss_required=False))
    prof = TradingProfile(risk_level="moderate", max_position=25_000.0)
    bt = AgentEngine(src, bt_engine, bt_paper, prof)

    curve: list[dict] = []
    trades: list[dict] = []
    for i in range(body.steps):
        cutoff = warmup + i
        bt.market = SlicedMarket(src, cutoff)  # hide the future from the agent
        opps = bt._score_all()
        opps.sort(key=lambda o: o["score"], reverse=True)
        if opps and opps[0]["score"] >= body.min_score:
            top = opps[0]
            sym = top["symbol"]
            res = AgentResult()
            bt._tool_propose(res, sym, Side.BUY)
            approved = (
                res.proposal is not None
                and res.verdict is not None
                and res.verdict["allowed"]
            )
            if approved:
                price = top["last"]
                qty = res.proposal["quantity"]
                result = bt_paper.place_order(
                    Order(symbol=sym, side=Side.BUY, quantity=qty,
                          order_type=OrderType.MARKET),
                    price,
                )
                if result.status == OrderStatus.FILLED:
                    trades.append({
                        "symbol": sym, "qty": qty, "entry": price,
                        "stop": res.proposal["stop_loss"],
                        "target": res.proposal["take_profit"],
                        "score": top["score"], "step": cutoff,
                    })
        curve.append({"t": cutoff, "equity": bt_paper.get_account().equity})

    # Mark-to-market + close-out at the final prices for realized stats.
    final_prices = {s: src.last(s) for s in src.symbols()}
    bt_paper.mark_all(final_prices)
    acct = bt_paper.get_account()
    for sym, pos in list(acct.positions.items()):
        bt_paper.place_order(
            Order(symbol=sym, side=Side.SELL, quantity=pos.quantity,
                  order_type=OrderType.MARKET),
            pos.current_price,
        )
    wins = sum(1 for t in trades if src.last(t["symbol"]) > t["entry"])
    equity = [c["equity"] for c in curve] or [0.0]
    peak = equity[0]
    max_dd = 0.0
    for e in equity[1:]:
        if e > peak:
            peak = e
        dd = (peak - e) / peak if peak else 0.0
        if dd > max_dd:
            max_dd = dd
    total_return = (equity[-1] - equity[0]) / equity[0] if equity[0] else 0.0
    return {
        "capital": body.capital,
        "steps": body.steps,
        "warmup": warmup,
        "final_equity": acct.equity,
        "total_return_pct": round(total_return * 100, 2),
        "max_drawdown_pct": round(max_dd * 100, 2),
        "win_rate_pct": round((wins / len(trades) * 100) if trades else 0.0, 2),
        "trades": len(trades),
        "equity_curve": [
            {"t": c["t"], "equity": round(c["equity"], 2)} for c in curve
        ],
    }
