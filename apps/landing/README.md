# ChainGuard landing page

A static SvelteKit 3 / Svelte 5 site, separate from the dashboard (`apps/dashboard`).

```sh
npm ci
npm run dev        # http://localhost:4400
npm run build      # static site in build/
npm test && npm run check
```

**Live or recorded, never pretend.** On load the page looks for an engine (`?engine=` or `VITE_ENGINE_URL`, default `http://localhost:4000`).
- **Engine found:** the stat band and the "right now" terminal are live over Phoenix Channels.
- **No engine:** they play back real data and say so: a recorded mainnet run in `src/lib/data/recorded-run.json` plus the bundled incident replays.

The recorded run is generated from an ingestd capture with `node scripts/record.mjs <capture.jsonl>`. The ML histogram comes from `services/anomaly/scripts/landing_scores.py`.

Motion respects `prefers-reduced-motion`. The page is fully readable without JavaScript.
