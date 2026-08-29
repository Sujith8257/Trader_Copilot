# Website (planned — Next.js)

Marketing site + future web dashboard for Trader Copilot.

Planned sitemap:

```
Home
├── Product
├── How it works        (local-first AI, risk engine, approval flow)
├── AI Models           (Model Hub + registry)
├── Paper Trading
├── Backtesting
├── Supported Brokers
├── Pricing
├── Documentation
└── Download Android App

Web dashboard (later)
├── Portfolio
├── Performance
├── Trading Journal
├── Strategies
├── Backtests
└── Model Management
```

To scaffold once decided:

```bash
npx create-next-app@latest . --typescript --tailwind --app
```

Tech: Next.js, TypeScript, Tailwind CSS. The site never receives the user's
LLM conversations — it is marketing + account services + sync only.
