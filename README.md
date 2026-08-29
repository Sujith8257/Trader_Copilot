# Trader Copilot

> **Your personal agentic crypto trading AI — 100% on your phone.**
> Scan → Analyze → Strategize → Propose → Risk-check → You approve

Trader Copilot is a fully **agentic** trading app that runs entirely on your
Android phone — no backend server, no laptop, no hosting. A multi-agent crew
(Scanner → Analyst → Strategist → Drafter) reasons over **live Coinbase market
data**, drafts trade proposals, and a deterministic, non-AI **Risk Engine**
sits between every AI proposal and any order execution. Connect an LLM brain
(your Termux llama-server, Groq, or the built-in rule brain) and the whole
crew comes alive.

## Feature highlights

| Feature | What it does |
|---|---|
| 🤖 **Agentic crew (on-phone)** | An orchestrator runs Scanner → Analyst → Strategist → Drafter with a **visible tool trace** — every step (`scan_market`, `indicators`, `web_search`, `get_account`, `risk_engine`, `proposal`) is shown in the UI as it happens |
| 🧠 **Pluggable brain** | Termux llama-server (e.g. Qwen on the same phone), Groq cloud, or the deterministic built-in rule brain — the app never breaks when a brain is offline |
| 📊 **100% live market data** | Candles, spot prices, charts, and AI Radar come straight from Coinbase — no simulated or seeded data anywhere. Paper trading fills at **real live prices** too |
| 📈 **Candlestick charts** | Daily OHLCV with volume, live-price marker, and RSI/MACD/EMA/Bollinger/ATR computed in **plain Dart, outside the LLM** |
| 🛡️ **Deterministic Risk Engine** | 12 pre-trade checks (position size, daily-loss circuit breakers, duplicate orders, kill switch…). Violations are hard blocks with reasons |
| 🧪 **Paper-first trading** | ₹10,00,000 virtual cash, fills at live Coinbase prices. Live trading (real orders via Coinbase Advanced Trade) is a separate, explicit, key-gated mode |
| ⚡ **Kill switch** | One toggle blocks *every* proposal — AI or manual — at the engine level |
| 🎨 **Polished fintech UI/UX** | Dark identity, INR lakh/crore formatting, skeleton loaders, allocation bars, onboarding flow |

```
Your LLM brain (Termux Qwen / Groq)     Deterministic Trading Core (Dart)
        │                                        │
        ▼                                        ▼
  AI Trade Proposal  ───────►  Risk Engine  ───────►  Your Approval  ───────►  Coinbase
                               (pure code,                                        (paper or live)
                                never the LLM)
```

## Repository layout

| Directory | What it is |
|-----------|------------|
| `mobile/` | The entire product — a Flutter app with everything inside |
| `mobile/lib/core/engine/` | `coinbase_client` (live data + JWT auth), `indicators`, `risk_engine`, `paper_broker`, `trading_service` |
| `mobile/lib/core/agent/` | `agent_engine` (the crew + orchestrator) and `llm_client` (OpenAI-compatible brains) |
| `mobile/lib/ui/` | Dashboard, Agent chat, Copilot approval flow, charts, journal, settings |
| `website/` | Static marketing site (`index.html`) |

## Quick start

```bash
cd mobile
flutter pub get
flutter test        # 22 tests
flutter run         # on your Android device/emulator
```

### Brains
- **Termux (on the same phone):** run `llama-server` in Termux with your Qwen
  model (default port 8080), then pick *Termux* in Settings — the app talks to
  `http://127.0.0.1:8080/v1` locally, no network needed.
- **Groq:** paste an API key in Settings (fast + free tier).
- **Rule brain:** no setup — the deterministic brain always works offline
  (market data still live whenever the internet is available).

### Live trading (optional, real money)
Enter a Coinbase Advanced Trade API key (key ID + private key) in Settings.
Keys are stored on-device. Live orders stay approval-gated and Risk-Engine-checked.

## Core principles

1. **Phone-first, serverless** — the whole product runs on the device; only Coinbase is remote.
2. **Determinism where it matters** — risk checks, sizing, and fills are plain code. The LLM never executes anything directly.
3. **Real data only** — every price, candle, and fill comes from live Coinbase; simulation is only ever the *paper wallet*, never the market.
4. **Human approval by default** — an AI proposal must pass the Risk Engine *and* the user before reaching the broker.
5. **Confidence ≠ probability** — AI confidence scores are assessments, never guarantees.
6. **Visible agency** — every crew step and tool call is traceable in the UI. No black boxes.

## Design credits

The broker abstraction and the approval-gated
`stage → commit → push → sync` order flow pattern are inspired by
[OpenAlice](https://github.com/TraderAlice/OpenAlice) (AGPL-3.0). Trader
Copilot is an independent implementation — no OpenAlice code is included in
this repository.

## License

TBD — with a fresh implementation (no OpenAlice code) you are free to choose.
Decide before the first public release: MIT/Apache-2.0 (permissive) vs AGPL-3.0 (copyleft).