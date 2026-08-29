# Trader Copilot — Full Context Handoff

> Everything a new model needs to continue work with zero further questions.
> Active task at the bottom. **Do NOT push to GitHub until the user says so.**

## 1. What this project is

**Trader Copilot = a local-first AI trading platform.** Open-source LLMs (Qwen /
Llama / Gemma / Mistral) run ON the user's phone (via llama.cpp/MLC — not yet
integrated), so prompts and trading history never leave the device. The cloud
(our FastAPI backend) is only market infrastructure, sync and account services.

Core tagline: **"Your personal trading AI that runs on your phone."**
Flow: **Analyze → Simulate → Learn → Approve → Trade.**

The **single most important design rule** (do not violate):

```
Local LLM ──► TradeProposal (structured JSON)
                   │
                   ▼
        RiskEngine.evaluate()  ← pure, deterministic, fully unit-tested
                   │
         ┌─────────┴─────────┐
         ▼                   ▼
      ALLOWED             BLOCKED
         │                   │
         ▼                   ▼
  User approval UI     "Why it was blocked"
         │
         ▼
  Broker abstraction ──► Paper fill (default) or live order (explicit mode)
```

The LLM's ONLY output surface is a validated `TradeProposal`. Everything after
that is deterministic code. Nothing executes without (a) passing the Risk
Engine AND (b) explicit user approval.

## 2. Product principles (use in all UX/UI copy)

1. **Local-first** — the AI runs on the phone.
2. **Determinism where it matters** — risk checks, order routing, fills are plain code.
3. **Paper before live** — every account starts in paper; live is a separate,
   explicit, approval-gated mode. Live is currently LOCKED (no broker pack).
4. **Human approval by default** — AI proposes, risk engine blocks/allows, user approves.
5. **Confidence ≠ probability** — AI confidence is an assessment, never a win
   guarantee. Always surface the honesty warning.
6. UX direction: do NOT market as "AI that trades stocks". Position as a private
   AI trading companion that helps the human decide.

## 3. Repository (Windows, working dir `c:\Users\tumma\OneDrive\Desktop\Trader Copilot`)

| Path | What it is | State |
|---|---|---|
| `backend/` | Python / FastAPI trading core | ✅ working + 38 tests |
| `mobile/` | Flutter app (package `trader_copilot`) | ✅ working + 8 tests, web runs |
| `website/` | marketing site | see §6 |
| `ARCHITECTURE.md` / `README.md` | docs | ✅ |

Git: 3 commits on `main` (working tree clean):
- `4b841f5` deterministic trading core (Risk Engine, paper broker, FastAPI) + docs
- `b267471` Flutter scaffold (android+web) + Riverpod
- `587d67a` app shell: dashboard, copilot proposal/approval flow, journal + CORS

## 4. Backend (FastAPI, Python) — DONE

Files: `backend/app/core/models.py`, `core/risk_engine.py`,
`core/brokers/base.py`, `core/brokers/paper.py`, `main.py`.
Tests in `backend/tests/` (api, paper_broker, risk_engine) — 38 pass.

Endpoints (run `uvicorn app.main:app --reload` from `backend/`, port 8000):
- `GET /health` → `{status, risk_engine_enabled, paper_broker}`
- `GET /account` → `{account_id, mode, cash, equity, day_start_equity,
  positions:{SYM:{qty,avg,last}}}`
- `POST /proposals/evaluate` body `{symbol, side: BUY|SELL, quantity,
  entry_price?, stop_loss?, take_profit?, rationale?, confidence? 0..1,
  source, market_price, market_open}` → `{allowed, violations[], warnings[]}`
- `POST /orders/paper?symbol&side&quantity&market_price` → `{order_id, status, filled_price}`
- CORS `allow_origins=["*"]` (dev only — restrict before any public deploy)

Risk Engine: 12 deterministic checks — kill switch, market hours, symbol/qty
validity, available cash, max position notional (₹25k), max open positions (10),
max exposure (80%), stop-loss required + sanity, duplicate-order protection,
max trades/day (20), max daily loss (5%), price deviation (2%). Violation =
hard block (red ✗), warning = pass with note (orange ⚠). Every reason is a
human-readable string. AI confidence always adds the honesty warning:
"AI confidence is an assessment, not a probability of success."

Paper broker: ₹10,00,000 virtual cash, simulated fills, position averaging,
partial sells, resting limit orders filled by `on_market_tick`, realized P&L.

## 5. Mobile app (Flutter 3.47.2 / Dart 3.13.2)

Deps: `flutter_riverpod ^3.4.2`, `http ^1.6.0`. Targets: android + web.

`lib/` layout:
- `main.dart` — shell: brand AppBar (gradient logo + ModeToggle chip),
  bottom `NavigationBar` on narrow screens, `NavigationRail` on wide (≥900px)
  for the web layout. Tabs: Portfolio / Copilot / Journal via `tabIndexProvider`.
- `core/models.dart` — Dart mirrors of backend models (`TradeProposal` has a
  `riskReward` getter; `AccountState.dayStart` from `day_start_equity`).
- `core/format.dart` — `formatINR` / `formatSignedINR` (₹, Indian grouping:
  10,00,000) used everywhere money is shown.
- `core/api_client.dart` — `ApiClient(baseUrl 'http://localhost:8000')`:
  `health()`, `fetchAccount()`, `evaluateProposal(p, marketPrice, marketOpen)`,
  `placePaperOrder(...)`. Throws `ApiError` on non-2xx.
- `state/providers.dart` — `apiClientProvider` (test-overridable),
  `tradingModeProvider` (starts paper), `tabIndexProvider`,
  `accountProvider` (FutureProvider.autoDispose), `journalProvider`.
- `ui/theme.dart` — `TC` design system: navy surfaces (#0B1220/#121A2B),
  emerald gain #34D399, loss #F97066, warn #FBBF24, info #60A5FA, hero
  gradient, accent rotation for symbols, tabular-figure typography, themed
  cards (rounded 20 + outline border), buttons, inputs, nav bar/rail, dialogs.
- `ui/widgets/common.dart` — `SectionHeader`, `StatTile`, `PnlChip`,
  `AllocationSlice`/`AllocationBar`, `EmptyState`, pulsing `Skeleton`.
- `ui/screens/dashboard_screen.dart` — hero net-worth card (gradient, equity,
  day-start delta chip, Cash/Exposure/Positions stat tiles), allocation bar
  (cash vs positions), position tiles with symbol avatars + P&L chips,
  skeleton loading, error view with Retry, empty state with CTA to Copilot.
- `ui/screens/copilot_screen.dart` — pipeline header (Idea → Risk → Approval
  → Filled), side segmented button (BUY/SELL), form, AI-confidence slider
  (0–100%), honesty caption, Run Risk Engine → `ProposalCard` verdict →
  Approve & Execute / Reject.
- `ui/widgets/proposal_card.dart` — verdict banner (Allowed/Blocked, "not an
  AI opinion"), entry/stop/target/RR/confidence rows, violations + warnings
  in tinted containers, AI rationale, Approve/Reject.
- `ui/screens/journal_screen.dart` — session stats (trades, notional) +
  trade tiles (BOUGHT/SOLD, fill, notional, time) or empty state w/ CTA.

Tests: `mobile/test/widget_test.dart` (dashboard render, live-mode gate via
dialog, journal nav — uses explicit `pump()` durations, NOT `pumpAndSettle`,
because the skeleton loader animates forever) and `api_client_test.dart`
(API parsing + `formatINR` unit tests). Pattern: `MockClient` +
`apiClientProvider.overrideWithValue`.

Environment notes:
- Flutter SDK at `C:\Users\tumma\flutter` (on user PATH). Fresh terminal needed.
- Chrome is the working device; Android needs SDK 36 + licenses.
- Repo lives under OneDrive sync — exclude from sync if builds get weird.
- Run: `cd mobile && flutter run -d chrome` (backend must be up for data).
- Checks: `flutter analyze`, `flutter test` (8 pass), `flutter build web`.

## 6. Website

`website/index.html` — a polished single-file static marketing site (embedded
CSS/JS, dark theme matching the app brand: #0B1220 / #34D399, Inter font,
scroll-reveal animations, responsive nav + mobile menu, CSS phone mockup with
a live-looking proposal card). Sections: nav, hero (tagline + CTAs + stats),
"How it works" trust-boundary steps, features grid (Model Hub, Market
Intelligence, Paper Trading, Risk Engine, Journal, Backtesting), principles,
footer. Open directly in a browser or `python -m http.server` from `website/`.
A Next.js migration remains possible later; static was chosen for reliability.

## 7. Environment / tooling facts

- Windows, cmd.exe shell in the agent, VS Code.
- Backend: `cd backend && python -m pytest -q` (38 pass);
  run: `uvicorn app.main:app --reload`.
- Mobile: `cd mobile && flutter analyze && flutter test`; `flutter build web`.
- Network: `storage.googleapis.com` was throttled earlier; mirror
  `storage.flutter-io.cn` ~20× faster if SDK/pub downloads crawl (env vars
  `FLUTTER_STORAGE_BASE_URL` / `PUB_HOSTED_URL`). Recently downloads were fast.

## 8. ACTIVE TASK

**"Complete the project on your own by improving UI/UX. I need 95+ score for
UI/UX in both web and app. Do not push to GitHub until I say so."**

Done so far (this task): backend CORS bug fix + `day_start_equity` exposed;
full design system (`TC`), Indian ₹ formatting, shared widgets (skeletons,
empty states, allocation bar, P&L chips), rebuilt dashboard (hero card +
allocation + position tiles), copilot (pipeline header, side selector,
confidence slider), journal (stats + tiles), proposal card (verdict banner,
tinted violation/warning rows), adaptive shell (NavigationBar ↔ Rail,
mode-switch dialog), static marketing website, tests updated.

Remaining ideas if score must go higher: equity history chart once the backend
tracks it, onboarding tour, more micro-animations, i18n, Android build polish.

Roadmap after UI/UX: local LLM (llama.cpp FFI), market indicators in Dart,
SQLite/Postgres persistence, backtesting, broker packs, model registry.

## 9. Conventions

- "Deterministic where it matters" is sacred — risk/execution stay in the
  Risk Engine; the UI never makes trading decisions.
- Currency is INR via `formatINR` (₹, Indian grouping).
- AI confidence ALWAYS carries the honesty framing.
- Live stays locked until a broker pack exists.
- Follow existing test patterns (MockClient overrides; python pytest).


