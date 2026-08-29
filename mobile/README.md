# Trader Copilot — Mobile App (Flutter)

**Status: scaffolded and building.** Flutter SDK 3.47.2 stable at `C:\Users\tumma\flutter`.

Created with:

```
flutter create --org com.tradercopilot --project-name trader_copilot . --platforms android,web
flutter pub add flutter_riverpod
```

- Package: `com.tradercopilot.trader_copilot`
- State management: flutter_riverpod ^3.4.2
- Targets: Android (primary) + Web (test drive)
- ✅ `flutter test` passing, ✅ `flutter build web` succeeds

## Running

```bash
cd mobile
flutter run -d chrome      # test drive on web (hot reload works via VS Code F5)
flutter devices            # list available devices
```

## Planned structure (to be filled in as we build)

```
lib/
  main.dart                  — app entry, Paper/Live mode bootstrap
  core/
    models/                  — TradeProposal, Order, Position, RiskVerdict (mirror of backend)
    risk/                    — on-device mirror of the backend Risk Engine rules
    market/indicators.dart   — RSI, MACD, EMA/SMA, VWAP, ATR, Bollinger (computed OUTSIDE the LLM)
  ai/
    runtime/                 — llama.cpp FFI / MLC bindings, model loading
    model_hub/               — device capability probe + model recommendations
    model_registry.dart      — remote JSON manifest discovery ("new model available")
    router.dart              — fast model / reasoning model / chat model routing
    memory/trading_profile.dart — explicit user preferences (no silent learning)
  trading/
    paper_engine.dart        — on-device paper portfolio
    broker/                  — UTA-style BrokerClient interface + adapter packs
    journal/                 — trade journal + post-trade analysis
  ui/
    screens/                 — dashboard, copilot chat, portfolio, journal, settings
    widgets/proposal_card.dart — "AI wants to BUY 10 @ ₹2,450 ... [Approve] [Reject]"
```

Sync with the FastAPI backend (`../backend`) happens over HTTPS/WebSockets for
market data and journal backup only — AI conversations stay on-device.

## Environment notes

- Flutter SDK: `C:\Users\tumma\flutter` (on user PATH)
- Stale `android-studio-dir` was removed from `%APPDATA%\.flutter_settings`
- Android toolchain: SDK 34 present; Flutter 3.47 wants SDK 36 + license acceptance
  (`flutter doctor --android-licenses`) before Android device builds work
- Web (`Chrome`) is fully working today — use it for development until the Android
  SDK is updated

