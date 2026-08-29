# Trader Copilot

> **Your personal trading AI that runs on your phone.**
> Analyze → Simulate → Learn → Approve → Trade

Trader Copilot is a local-first, **agentic** AI trading platform. Open-source
LLMs (Qwen, Llama, Gemma, Mistral) run **on your device** via llama.cpp/MLC so
your prompts and trading history never leave your phone. An agentic Copilot
reasons over real tools — market scanner, technical indicators, your account —
and a deterministic, non-AI **Risk Engine** sits between every AI trade
proposal and any order execution.

## Hackathon feature highlights

| Feature | What it does |
|---|---|
| 🤖 **Agentic Copilot chat** | Observe → think → act loop with a **visible tool trace** — every tool call (`scan_market`, `indicators`, `propose_trade`, `risk_engine`) is shown in the UI as it happens |
| 🧠 **Pluggable brain** | Set `OPENAI_API_KEY` for an OpenAI-compatible LLM — or run fully offline with the deterministic built-in brain. The demo never breaks |
| 📊 **Market Intelligence** | RSI, MACD, EMA/SMA, Bollinger, ATR computed in **plain code, outside the LLM**, then fed to the agent as structured context |
| 🔍 **Momentum scanner** | Ranks 8 symbols on trend + momentum with human-readable reasons and ATR-based stop/targets (`/agent/scan`) |
| 🛡️ **Deterministic Risk Engine** | 12 pre-trade checks (position size, daily-loss circuit breakers, duplicate orders, kill switch…). Violations are hard blocks with reasons |
| 🧪 **Paper-first trading** | ₹10,00,000 virtual cash, simulated fills — live stays locked until a broker pack exists |
| ⚡ **Kill switch** | One toggle blocks *every* proposal — AI or manual — at the engine level |
| 🧑‍💻 **AI memory** | Explicit user trading profile (risk level, max position) sizes every agent draft — no silent learning |
| 🎨 **95+ UI/UX design system** | Dark fintech identity, INR lakh/crore formatting, skeleton loaders, allocation bars, adaptive web layout |

```
Local LLM (on-device)          Deterministic Trading Core
        │                               │
        ▼                               ▼
  AI Trade Proposal  ───────►  Risk Engine  ───────►  Your Approval  ───────►  Broker
                               (pure code,
                                never the LLM)
```

## Repository layout

| Directory    | What it is                                                                 |
|--------------|----------------------------------------------------------------------------|
| `backend/`   | Python / FastAPI: Risk Engine, agentic Copilot, market sim, indicators, paper broker |
| `mobile/`    | Flutter app: Agent chat, portfolio, proposal approval flow, journal (Android + web) |
| `website/`   | Polished static marketing site (`index.html`)                              |
| `HANDOFF.md` | Full context handoff for a new model/developer                             |

## Quick start

```bash
# backend (54 tests)
cd backend && pip install -r requirements.txt && pytest
uvicorn app.main:app --reload          # http://localhost:8000/docs

# mobile (15 tests) — run against the backend on Chrome
cd mobile && flutter test
flutter run -d chrome
```

Optional LLM brain: set `OPENAI_API_KEY` (+ optional `OPENAI_BASE_URL`,
`OPENAI_MODEL`) and restart the backend — the agent chip switches to
"LLM brain". Everything else stays identical.

## Core principles

1. **Local-first** — the AI runs on the phone; the cloud is market infrastructure + sync only.
2. **Determinism where it matters** — risk checks, order routing, and fills are plain code. The LLM never executes anything directly.
3. **Paper before live** — every account starts in paper mode; live trading is a separate, explicit, approval-gated mode.
4. **Human approval by default** — an AI proposal must pass the Risk Engine *and* the user before reaching a broker.
5. **Confidence ≠ probability** — AI confidence scores are assessments, never guarantees.
6. **Visible agency** — every agent tool call is traceable in the UI. No black boxes.

## Design credits

The broker abstraction (`UTA`-style unified account surface), the approval-gated
`stage → commit → push → sync` order flow, and the broker-pack / graceful-degradation
pattern are inspired by [OpenAlice](https://github.com/TraderAlice/OpenAlice)
(AGPL-3.0). Trader Copilot is an independent implementation — no OpenAlice code is
included in this repository.

## License

TBD — with a fresh implementation (no OpenAlice code) you are free to choose.
Decide before the first public release: MIT/Apache-2.0 (permissive) vs AGPL-3.0 (copyleft).
