# Website — Trader Copilot

**Status: live.** A polished, single-file static marketing site: `index.html`.

Open it directly in a browser, or serve it:

```bash
cd website
python -m http.server 8080
# → http://localhost:8080
```

## What's on it

- Sticky glass nav with mobile menu
- Hero: tagline, CTAs, stats, and a CSS phone mockup showing a live-looking
  Risk-Engine proposal card
- How it works — the 4-step trust pipeline (Analyze → Risk → Approve → Paper fill)
- Features grid — Model Hub, Market Intelligence, Backtesting, Risk Engine,
  AI Journal, Offline mode
- The trust boundary — "No hallucination can become an order" with the
  deterministic flow diagram
- Principles — the 5 product commitments
- Download CTA + footer
- Dark fintech theme matching the Flutter app (#0B1220 / emerald #34D399),
  scroll-reveal animations, fully responsive

No build step, no dependencies. A Next.js migration (per the original plan)
remains possible later; static was chosen for zero-dependency reliability.

