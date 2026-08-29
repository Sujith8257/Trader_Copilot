# Trader Copilot — Architecture

Status: living document. Last updated: 2026-08-29.

## 1. Product model

```
                    TRADER COPILOT
                          │
          ┌───────────────┴────────────────┐
          │                                │
   🌐 Next.js website                📱 Flutter app (Android)
   marketing + future dashboard      the user's private AI trading computer
          │                                │
          │                    ┌───────────┴────────────┐
          │                    │                        │
          │              Local LLM runtime        Trading UI (Riverpod + SQLite)
          │              (llama.cpp / MLC)                 │
          │                    └───────────┬────────────┘
          └──────────────┐                 │
                         ▼                 ▼
                     FastAPI backend   Trading Engine
                         │                 │
        ┌────────────────┼──────────┐      ▼
        │                │          │  Risk Engine (deterministic)
   PostgreSQL       Market data   Model        │
                    service      Registry      ▼
                                               Broker abstraction
                                        ┌──────────┴──────────┐
                                        ▼                     ▼
                                  Paper broker            Live broker
                                                        (approval-gated)
```

## 2. The trust boundary (most important design rule)

```
Local LLM ──► TradeProposal (structured JSON)
                    │
                    ▼
             RiskEngine.evaluate()      ← pure, deterministic, fully unit-tested
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
     ALLOWED                 BLOCKED
        │                       │
        ▼                       ▼
  User approval UI        "Why it was blocked"
        │
        ▼
  Broker abstraction ──► Paper fill (default) or live order (explicit mode)
```

The LLM's only output surface is a **validated, structured `TradeProposal`**.
Everything after that point is deterministic code.

## 3. Backend modules (`backend/app`)

| Module | Responsibility | Inspired by |
|---|---|---|
| `core/models.py` | Shared data model: orders, positions, account state, proposals, risk config, verdicts | — |
| `core/risk_engine.py` | Deterministic pre-trade checks. Never calls the network or the LLM | OpenAlice guards |
| `core/brokers/base.py` | `BrokerClient` protocol + `BrokerHealth`. One account surface for all brokers | OpenAlice UTA |
| `core/brokers/paper.py` | `PaperBroker`: simulated fills, virtual cash, positions | OpenAlice Mock simulator |
| `main.py` | FastAPI app exposing health + risk-check + paper-account endpoints | — |

### Risk Engine checks (Phase 1)

1. Kill switch — global `enabled` flag blocks *all* proposals
2. Market hours (injectable clock/calendar, enforced flag)
3. Symbol & quantity validity
4. Available cash (order notional ≤ cash)
5. Max single-position notional
6. Max open positions
7. Max portfolio exposure (% of equity)
8. Stop-loss required (+ entry/stop/target sanity for longs)
9. Duplicate-order protection (same symbol+side already pending)
10. Max trades per day
11. Max daily loss (absolute and % of day-start equity)
12. Entry-vs-market price deviation

Each check produces either a **violation** (hard block) or a **warning** (pass with note).
The verdict explains *why*, in user-readable strings.

### Order flow (phase ≥ 2, modeled on OpenAlice "Trading as Git")

```
stage (persist intent) → commit (validate + risk) → push request
→ human approval (default ON) → broker dispatch → sync results → journal
```

## 4. Mobile app (`mobile/`) — planned

- **Flutter + Dart + Riverpod + SQLite (drift)**
- **Local LLM runtime**: llama.cpp via FFI, or MLC LLM; models stored on-device
- **Model Hub**: device capability probe (RAM, storage, CPU/GPU, Android version)
  → recommends a model tier (small ~3B / balanced ~4B / quality ~7B)
- **Model Registry**: remote JSON manifest (name, params, quants, RAM needs, context,
  license, benchmarks, trading suitability) → "new model available" discovery
- **Market Intelligence layer**: RSI, MACD, EMA/SMA, VWAP, ATR, Bollinger Bands,
  volume, S/R — computed **in Dart, outside the LLM**, then fed to the model as
  structured context
- **Multiple-model router**: fast model for scans, reasoning model for deep analysis,
  small model for chat
- **AI memory**: explicit user trading profile (timeframe, risk level, max position,
  preferred sectors, exclusions) — no silent behavioral learning
- **Trading journal**: proposal → why AI suggested it → approve/reject → entry/exit →
  result → post-trade analysis
- **Offline mode**: local model + cached portfolio/strategies keep working without internet

> ⚠️ Flutter SDK is not installed on this machine yet. Install Flutter, then run
> `flutter create .` inside `mobile/` per the scaffold plan in `mobile/README.md`.

## 5. Backend roadmap

- **Phase 2**: persistence (SQLAlchemy + SQLite → Postgres), order staging/commit
  state machine, REST + WebSocket API, trading journal
- **Phase 3**: market-data service (delayed EOD first, then streaming), backtesting
  engine (returns, max drawdown, win rate, profit factor), model-registry endpoint
- **Phase 4**: live broker packs (Alpaca / Zerodha-style Indian brokers / CCXT for
  crypto). A missing pack degrades only accounts that need it — never the research
  or paper surfaces (OpenAlice graceful-degradation pattern)

## 6. Explicit non-goals

- No "AI that trades unsupervised". Automation rules, if ever added, are predefined
  and bound by the same Risk Engine.
- Confidence scores are never marketed as win probabilities.
- The cloud never receives the user's LLM conversations or prompts by default.
