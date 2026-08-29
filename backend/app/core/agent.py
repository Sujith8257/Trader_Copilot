"""Agentic Copilot — an observe → think → act loop over a tool registry.

Trust rules are unchanged: the agent's ONLY output surface is a TradeProposal
DRAFT. Execution still requires the deterministic Risk Engine + user approval.

Two brains, same tools:
  * "llm"   — an OpenAI-compatible endpoint (set OPENAI_API_KEY, optionally
              OPENAI_BASE_URL / OPENAI_MODEL). The model chooses tools; the
              backend executes them and feeds results back into the loop.
  * "local" — a deterministic rule-based brain (default) with identical tool
              access, so the entire demo runs offline. Local-first, honored.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from typing import Optional

from .indicators import snapshot
from .models import Side, TradeProposal
from .risk_engine import RiskEngine


@dataclass
class TradingProfile:
    """Explicit AI memory — user-owned preferences, never silent learning."""

    risk_level: str = "moderate"      # low | moderate | aggressive
    max_position: float = 25_000.0    # INR per position
    prefer_sectors: list[str] = field(default_factory=list)
    avoid: list[str] = field(default_factory=list)


@dataclass
class AgentStep:
    tool: str
    detail: str

    def as_dict(self) -> dict:
        return {"tool": self.tool, "detail": self.detail}


@dataclass
class AgentResult:
    reply: str = ""
    steps: list[AgentStep] = field(default_factory=list)
    proposal: Optional[dict] = None
    verdict: Optional[dict] = None
    opportunities: list[dict] = field(default_factory=list)


_RISK_FRACTION = {"low": 0.4, "moderate": 0.7, "aggressive": 1.0}

SCAN_KEYWORDS = ("scan", "find", "opportunit", "momentum", "idea", "suggest",
                 "low risk", "low-risk", "watchlist")
ACCOUNT_KEYWORDS = ("portfolio", "position", "cash", "equity", "account",
                    "how much", "net worth")
ANALYZE_KEYWORDS = ("analyze", "analyse", "what about", "review", "check",
                    "outlook", "tell me about")
GREET_KEYWORDS = ("hi", "hello", "hey", "help", "what can you")


class AgentEngine:
    def __init__(self, market, risk: RiskEngine, paper,
                 profile: Optional[TradingProfile] = None) -> None:
        self.market = market
        self.risk = risk
        self.paper = paper
        self.profile = profile or TradingProfile()
        self.brain = "llm" if os.getenv("OPENAI_API_KEY") else "local"

    # ------------------------------------------------------------------ #
    # Tool: scan_market — rank the whole universe on trend + momentum     #
    # ------------------------------------------------------------------ #
    def _tool_scan(self, res: AgentResult, top_n: int = 3) -> list[dict]:
        res.steps.append(AgentStep(
            "scan_market",
            f"Scoring {len(self.market.symbols())} symbols on trend, RSI and MACD…",
        ))
        opps = self._score_all()
        opps.sort(key=lambda o: o["score"], reverse=True)
        opps = opps[:top_n]
        res.opportunities = opps
        for o in opps:
            res.steps.append(AgentStep(
                "indicators",
                f"{o['symbol']}: ₹{o['last']:,.0f} · RSI {o['rsi']} · "
                f"trend {o['trend']} · score {o['score']:.2f}",
            ))
        return opps

    def _score_all(self) -> list[dict]:
        out: list[dict] = []
        for sym in self.market.symbols():
            s = snapshot(self.market.bars(sym))
            score, reasons = self._score_one(sym, s)
            out.append({
                "symbol": sym,
                "last": s["last"],
                "change_pct": s["change_pct"],
                "rsi": s["rsi"],
                "trend": s["trend"],
                "score": round(score, 2),
                "reasons": reasons,
                "stop": s["stop"],
                "target": s["target"],
            })
        return out

    def _score_one(self, sym: str, s: dict) -> tuple[float, list[str]]:
        score, reasons = 0.0, []
        if s["trend"] == "UP":
            score += 1.0
            reasons.append("price above key EMAs")
        if s["macd_hist"] is not None and s["macd_hist"] > 0:
            score += 0.75
            reasons.append("MACD bullish crossover")
        r = s["rsi"]
        if r is not None:
            if 50 <= r <= 68:
                score += 0.75
                reasons.append(f"healthy momentum (RSI {r})")
            elif r > 72:
                score -= 0.5
                reasons.append(f"overbought (RSI {r})")
            elif r < 35:
                score -= 0.25
                reasons.append(f"weak momentum (RSI {r})")
        if s["change_pct"] and s["change_pct"] > 0:
            score += 0.25
            reasons.append("up on the day")
        if self.profile.avoid and any(
            "penny" in a.lower() and s["last"] < 100 for a in self.profile.avoid
        ):
            score -= 1.0
            reasons.append("matches your 'avoid' rules")
        return score, reasons

    # ------------------------------------------------------------------ #
    # Tool: analyze — full indicator read-out for one symbol              #
    # ------------------------------------------------------------------ #
    def _tool_analyze(self, res: AgentResult, symbol: str) -> dict:
        s = snapshot(self.market.bars(symbol))
        res.steps.append(AgentStep(
            "indicators",
            f"{symbol}: last ₹{s['last']:,.2f} ({s['change_pct']:+.2f}%) · "
            f"RSI {s['rsi']} · EMA20 ₹{s['ema20']} vs EMA50 ₹{s['ema50']} · "
            f"MACD hist {s['macd_hist']} · ATR {s['atr']}",
        ))
        return s

    # ------------------------------------------------------------------ #
    # Tool: get_account — deterministic portfolio read-out                #
    # ------------------------------------------------------------------ #
    def _tool_account(self, res: AgentResult) -> None:
        acct = self.paper.get_account()
        res.steps.append(AgentStep(
            "get_account",
            f"cash ₹{acct.cash:,.2f} · equity ₹{acct.equity:,.2f} · "
            f"{len(acct.positions)} open position(s)",
        ))
        lines = [f"Cash ₹{acct.cash:,.2f} · Equity ₹{acct.equity:,.2f}"]
        if acct.positions:
            for sym, p in acct.positions.items():
                pnl = p.unrealized_pnl
                lines.append(
                    f"• {sym}: {p.quantity:g} @ ₹{p.avg_price:,.2f} → "
                    f"₹{p.current_price:,.2f} ({'+' if pnl >= 0 else '-'}₹{abs(pnl):,.2f})"
                )
        else:
            lines.append("No open positions yet.")
        res.reply = "\n".join(lines)
    # ------------------------------------------------------------------ #
    # Tool: propose_trade — DRAFT a proposal, then run the Risk Engine    #
    # ------------------------------------------------------------------ #
    def _tool_propose(self, res: AgentResult, symbol: str, side: Side) -> None:
        s = snapshot(self.market.bars(symbol))
        price = s["last"]
        fraction = _RISK_FRACTION.get(self.profile.risk_level, 0.7)
        notional = min(self.profile.max_position, self.paper.get_account().cash * 0.9)
        qty = max(1.0, float(int((notional * fraction) / price)))
        if side == Side.SELL:
            pos = self.paper.get_account().positions.get(symbol)
            if not pos:
                res.reply = f"You don't hold {symbol}, so I can't draft a SELL. Try a BUY instead."
                return
            qty = min(qty, pos.quantity)
        tp = TradeProposal(
            symbol=symbol,
            side=side,
            quantity=qty,
            entry_price=price,
            stop_loss=s["stop"],
            take_profit=s["target"],
            rationale=(
                f"{s['trend']} trend with RSI {s['rsi']} and MACD hist "
                f"{s['macd_hist']}; stop 2×ATR ({s['stop']}), target 3×ATR "
                f"({s['target']}) → ~1.5 risk/reward. Sized to your "
                f"{self.profile.risk_level} risk profile."
            ),
            confidence=0.72,
            source="ai",
        )
        res.steps.append(AgentStep(
            "propose_trade",
            f"Draft: {side.value} {qty:g} {symbol} @ ₹{price:,.2f} · "
            f"stop ₹{tp.stop_loss} · target ₹{tp.take_profit}",
        ))
        verdict = self.risk.evaluate(tp, self.paper.get_account(), price, True)
        res.steps.append(AgentStep(
            "risk_engine",
            ("ALLOWED — " if verdict.allowed else "BLOCKED — ")
            + ("; ".join(verdict.violations) if verdict.violations else "no violations"),
        ))
        res.proposal = {
            "symbol": tp.symbol, "side": tp.side.value, "quantity": tp.quantity,
            "entry_price": tp.entry_price, "stop_loss": tp.stop_loss,
            "take_profit": tp.take_profit, "rationale": tp.rationale,
            "confidence": tp.confidence,
        }
        res.verdict = {"allowed": verdict.allowed,
                       "violations": verdict.violations,
                       "warnings": verdict.warnings}
        if verdict.allowed:
            res.reply = (f"Draft ready: {side.value} {qty:g} {symbol} @ ₹{price:,.2f}. "
                         "The Risk Engine allows it — review and approve below. "
                         "Nothing executes without you.")
        else:
            res.reply = (f"I drafted {side.value} {qty:g} {symbol}, but the Risk "
                         "Engine blocked it (see the reasons below). That's the "
                         "guard rail working as designed.")
    # ------------------------------------------------------------------ #
    # The local brain: keyword intent routing (offline, deterministic)    #
    # ------------------------------------------------------------------ #
    def _find_symbol(self, low: str) -> Optional[str]:
        for sym in self.market.symbols():
            if re.search(rf"\b{re.escape(sym.lower())}\b", low):
                return sym
        return None

    def handle(self, message: str) -> AgentResult:
        res = AgentResult()
        low = (message or "").strip().lower()
        if not low:
            res.reply = "Say something like: \"scan the market\"."
            return res
        sym = self._find_symbol(low)
        if any(k in low for k in SCAN_KEYWORDS):
            opps = self._tool_scan(res, 3)
            body = "\n".join(
                f"• {o['symbol']} — ₹{o['last']:,.0f} · {o['trend']} · "
                + "; ".join(o["reasons"][:2])
                for o in opps
            )
            res.reply = (f"Top {len(opps)} opportunities right now:\n{body}\n\n"
                         "Ask me to analyze one, or say \"buy <symbol>\" and "
                         "I'll draft a proposal for the Risk Engine.")
        elif sym and any(k in low for k in ("buy", "sell", "long", "short")):
            side = Side.SELL if ("sell" in low or "short" in low) else Side.BUY
            self._tool_propose(res, sym, side)
            if res.reply == "":
                res.reply = "Proposal drafted."
        elif sym and any(k in low for k in ANALYZE_KEYWORDS):
            s = self._tool_analyze(res, sym)
            res.reply = (f"{sym}: ₹{s['last']:,.2f} ({s['change_pct']:+.2f}% today). "
                         f"Trend {s['trend']} (EMA20 ₹{s['ema20']} vs EMA50 ₹{s['ema50']}), "
                         f"RSI {s['rsi']}, MACD hist {s['macd_hist']}, ATR {s['atr']}. "
                         "Say \"buy <symbol>\" and I'll draft a checked proposal.")
        elif any(k in low for k in ACCOUNT_KEYWORDS):
            self._tool_account(res)
        elif any(k in low for k in GREET_KEYWORDS):
            res.reply = ("I'm your trading copilot — I run on tools, not guesses:\n"
                         "• \"scan the market\" — rank opportunities by momentum\n"
                         "• \"analyze TCS\" — RSI, MACD, EMAs, ATR read-out\n"
                         "• \"buy INFY\" — draft a proposal (Risk Engine checks it, you approve)\n"
                         "• \"portfolio\" — your paper account")
        else:
            res.reply = ("I can scan the market, analyze a symbol, or draft a "
                         "checked proposal. Try: \"scan the market\", "
                         "\"analyze RELIANCE\", or \"buy INFY\".")
        return res



