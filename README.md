# Trader Copilot

> **Your personal trading AI that runs on your phone.**
> Analyze → Simulate → Learn → Approve → Trade

Trader Copilot is a local-first AI trading platform. Open-source LLMs (Qwen, Llama,
Gemma, Mistral) run **on your device** via llama.cpp/MLC so your prompts and trading
history never have to leave your phone. A deterministic, non-AI **Risk Engine** sits
between every AI trade proposal and any order execution.

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
| `backend/`   | Python / FastAPI trading core: Risk Engine, broker abstraction, paper engine |
| `mobile/`    | Flutter app (Android): local LLM hub, trading UI, journal (needs Flutter SDK) |
| `website/`   | Next.js marketing site + future web dashboard                                |
| `docs/`      | Architecture decisions and roadmap                                          |

## Quick start (backend)

```bash
cd backend
python -m venv .venv
.venv\Scripts\activate          # Windows
pip install -r requirements.txt
pytest                          # run the deterministic-core test suite
uvicorn app.main:app --reload   # start the API
```

## Core principles

1. **Local-first** — the AI runs on the phone; the cloud is market infrastructure + sync only.
2. **Determinism where it matters** — risk checks, order routing, and fills are plain code. The LLM never executes anything directly.
3. **Paper before live** — every account starts in paper mode; live trading is a separate, explicit, approval-gated mode.
4. **Human approval by default** — an AI proposal must pass the Risk Engine *and* the user before reaching a broker.
5. **Confidence ≠ probability** — AI confidence scores are assessments, never guarantees.

## Design credits

The broker abstraction (`UTA`-style unified account surface), the approval-gated
`stage → commit → push → sync` order flow, and the broker-pack / graceful-degradation
pattern are inspired by [OpenAlice](https://github.com/TraderAlice/OpenAlice)
(AGPL-3.0). Trader Copilot is an independent implementation — no OpenAlice code is
included in this repository.

## License

TBD — with a fresh implementation (no OpenAlice code) you are free to choose.
Decide before the first public release: MIT/Apache-2.0 (permissive) vs AGPL-3.0 (copyleft).
