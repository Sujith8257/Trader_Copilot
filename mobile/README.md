# Mobile app (planned — requires Flutter SDK)
#
# This machine does not have Flutter installed yet. Once installed
# (https://docs.flutter.dev/get-started/install/windows), run from this folder:
#
#   flutter create --org com.tradercopilot --project-name trader_copilot .
#   flutter pub add flutter_riverpod drift sqlite3_flutter_libs
#
# Planned structure:
#   lib/
#     main.dart                  — app entry, Paper/Live mode bootstrap
#     core/
#       models/                  — TradeProposal, Order, Position, RiskVerdict
#       risk/                    — on-device mirror of the backend Risk Engine rules
#       market/indicators.dart   — RSI, MACD, EMA/SMA, VWAP, ATR, Bollinger (computed OUTSIDE the LLM)
#     ai/
#       runtime/                 — llama.cpp FFI / MLC bindings, model loading
#       model_hub/               — device capability probe + model recommendations
#       model_registry.dart      — remote JSON manifest discovery ("new model available")
#       router.dart              — fast model / reasoning model / chat model routing
#       memory/trading_profile.dart — explicit user preferences (no silent learning)
#     trading/
#       paper_engine.dart        — on-device paper portfolio
#       broker/                  — UTA-style BrokerClient interface + adapter packs
#       journal/                 — trade journal + post-trade analysis
#     ui/
#       screens/                 — dashboard, copilot chat, portfolio, journal, settings
#       widgets/proposal_card.dart  — "AI wants to BUY 10 @ ₹2,450 ... [Approve] [Reject]"
#
# Sync with the FastAPI backend happens over HTTPS/WebSockets for market data and
# journal backup only — AI conversations stay on-device.
