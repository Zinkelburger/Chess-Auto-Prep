# chessautoprep.com — frontend

Static Astro site deployed to Cloudflare Pages. Three tools, one shared shell:

| Route                 | What                                                                 | Code                                   |
| --------------------- | -------------------------------------------------------------------- | -------------------------------------- |
| `/twic-notifications` | TWIC Alerts — create alerts anonymously, or manage them signed in    | `src/lib/alerts-page.ts` + `src/lib/*` |
| `/tactics`            | Tactics Trainer — Stockfish in the browser mines puzzles from games  | `src/tactics/*`                        |
| `/charles-clock`      | Charles Clock — a full-screen phone clock with its own `<html>`      | `src/pages/charles-clock.astro`        |

`/dashboard` forwards to `/twic-notifications` (with the query string, so old
login emails keep working); `/verify` and `/unsubscribe` are one-shot token
pages; `/book` is an unlisted booking page.

```sh
npm install
npm run dev        # http://localhost:4321 — set PUBLIC_API_URL to point at a local server.py
npm run build      # → dist/
npx astro check    # type-check .ts and .astro (the clock's script is untyped JS and reports errors; everything else is clean)
```

Environment (build-time): `PUBLIC_API_URL` (default `https://api.chessautoprep.com`),
`PUBLIC_TURNSTILE_SITE_KEY` (empty disables the CAPTCHA widget).

## Layout

- `src/layouts/Base.astro` — tokens (shared with `docs/design/wireframe-style.css`
  and the clock), nav, footer, and the primitive vocabulary: `.btn*`, inputs,
  `.card`, `.alert-*`, `.choice` chips, `.badge`, `.modal*`, `.status-panel`.
  Page-specific CSS lives with the page (`<style>`) or in `src/styles/`.
- `src/lib/` — the alerts feature. `api.ts` is the only place that talks to
  `server.py` (typed endpoints, `ApiError`); `alert-form.ts` owns one form
  (used for anonymous subscribe, create and edit); `alerts-list.ts` renders
  the signed-in cards; `filters.ts`/`eco-picker.ts`/`autocomplete.ts` are
  the filter builder; `board-preview.ts` is the dependency-free FEN renderer
  and the floating `HoverBoard`.
- `src/tactics/` — see below.
- `public/stockfish/` — stockfish.js 18 single-threaded build (`stockfish.js` +
  `stockfish.wasm`). `public/piece/` — cburnett SVGs used by both board renderers.

## Tactics trainer

```
sources.ts      fetch games (Lichess PGN with evals=true; Chess.com monthly archives)
pgn.ts          split/parse PGN, keep [%eval] comments
miner.ts        replay a game → user-move sites → fan out to the engine pool → Puzzle[]
engine/         UciWorker (one Stockfish worker, promise API) and EnginePool (N workers, one queue)
store.ts        IndexedDB: puzzles per game+depth, opening evals by FEN+depth
board.ts        Chessground wrapper (legal moves from chess.js, arrows, review)
app.ts          page controller: setup → analysing → train
settings.ts     localStorage settings
```

Speed comes from the same tricks as the Dart app's tactics import:

1. **A pool of single-threaded engines, not one multi-threaded engine.** Every
   position of a game is submitted at once; the pool keeps every core busy.
   (The multi-threaded build needed `SharedArrayBuffer`, hence COOP/COEP headers,
   and shipped without its own `.wasm`, so it always failed and fell back after a
   10 s timeout. It is gone, and so are the headers.)
2. **Best-move skip.** If the user played the engine's first PV move, the
   position after it is not searched.
3. **Lichess server evals.** With `evals=true` the PGN carries `[%eval]` on every
   ply of analysed games; those decide the verdict without an engine, and only
   real candidates are searched (for the best line).
4. **Caches.** Opening positions (fullmove ≤ 12) are memoised across games and
   persisted; a game analysed once at a depth is never analysed again.
5. **Training starts before analysis ends.** Puzzles stream into the session;
   the banner shows the count until the run finishes.

Verdicts use lila's winning-chances model and thresholds (`win-chances.ts`),
so this trainer, the Dart app, and Lichess agree on what a mistake is.

## Smoke-testing

There is no unit-test harness; `astro check` + `npm run build` gate the code,
and a headless Chrome run (`puppeteer-core` is a dev dependency, Chrome must be
installed) exercises the real pages. Lichess answers non-browser user agents
with 404, so a headless run needs `page.setUserAgent(...)`.
