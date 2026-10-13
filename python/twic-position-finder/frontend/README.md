# chessautoprep.com — frontend

Static Astro site deployed to Cloudflare Pages. Browser preparation tools, one shared shell:

| Route                 | What                                                                 | Code                                   |
| --------------------- | -------------------------------------------------------------------- | -------------------------------------- |
| `/twic-notifications` | TWIC Alerts — create alerts anonymously, or manage them signed in    | `src/lib/alerts-page.ts` + `src/lib/*` |
| `/pgn`               | PGN viewer, variations, comments, move entry, local save and export     | `src/prep/*` |
| `/expectimax`        | Stockfish + Maia expectimax computed on this device                    | `src/prep/*` |
| `/tactics`            | Tactics Trainer — Stockfish in the browser mines puzzles from games  | `src/tactics/*`                        |
| `/bughouse`           | Two linked boards and Hivemind running entirely in the browser | `src/bughouse/*`, `../../../tools/bughouse_web/` |
| `/bughouse-puzzles`   | Bughouse Puzzles — mates and tactics mined from FICS games, reserves frozen | `src/bughouse-puzzles/*`, `public/bughouse-puzzles/` |
| `/bughousedb`         | BughouseDB — the shared Hivemind book; missing positions analysed in the browser | `src/bughousedb/*`, `src/bughouse/boards.ts` |
| `/crazyhouse`         | Crazyhouse Analysis — lichess.org/analysis/crazyhouse on one board, with + and − on every piece in both hands and lila's board editor; Fairy-Stockfish in the browser | `src/crazyhouse/*`, `../../../tools/prepare_crazyhouse_web.py` |
| `/charles-clock`      | Charles Clock — a full-screen phone clock with its own `<html>`      | `src/pages/charles-clock.astro`        |

`/dashboard` forwards to `/twic-notifications` (with the query string, so old
login emails keep working); `/verify` and `/unsubscribe` are one-shot token
pages; `/book` is an unlisted booking page.

```sh
npm install
npm run dev        # http://localhost:4321 — set PUBLIC_API_URL to point at a local server.py
npm run build      # → dist/
npx astro check    # type-check .ts and .astro
npm run test:bughouse  # state, export, persistence and worker lifecycle regressions
```

Environment (build-time): `PUBLIC_API_URL` (default `https://api.chessautoprep.com`),
`PUBLIC_TURNSTILE_SITE_KEY` (empty disables the CAPTCHA widget).
Bughouse inference needs no server; shared evaluations use PUBLIC_API_URL. Its C++ engine runs as
WebAssembly in a browser worker and ONNX Runtime Web runs the neural network
locally. `npm run build` prepares checksum-pinned model chunks and the ONNX
runtime automatically; all files fit Cloudflare Pages' 25 MiB asset limit.
The compiled Hivemind module is committed, so Pages needs only the normal
Node/Python build environment, not Emscripten. See the
[static Bughouse guide](../../../tools/bughouse_web/README.md).

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
- `src/crazyhouse/` — Crazyhouse Analysis. `tree.ts` is the move tree and
  the hand edits (pure, `npm run test:crazyhouse`); `engine.ts` runs Lichess's
  Fairy-Stockfish 14 build (`@lichess-org/stockfish-web`) with Lichess's
  crazyhouse NNUE, downloaded once in parts and kept in the browser cache;
  `board.ts` is the chessground board in analysis and editor modes; `hand.ts`
  draws a hand with its − and + buttons; `app.ts` is the page. A hand edit is
  kept on its position and carried through the moves after it; the engine
  always gets a bare FEN. Hands are capped at 16 of a piece (the NNUE's slots)
  and 64 pieces in all. The engine is multi-threaded, so `/crazyhouse` and
  `/crazyhouse-engine/*` alone are cross-origin isolated (COOP/COEP in
  `public/_headers` and the dev server in `astro.config.mjs`). After
  `npm run build`, `npm run test:crazyhouse:browser` drives the page in
  headless Chrome with the real engine and writes screenshots to
  `build/crazyhouse-web/`.
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

## Bughouse puzzles

`public/bughouse-puzzles/` is generated, not hand-edited:
`python3 -m bughouse_db puzzles --year 2017 --games 1500 --engine PATH` from
`tools/` (Fairy-Stockfish binary; see `tools/bughouse_db/puzzles.py`). Each
puzzle is one board of a real game with the reserves frozen: captures go to the
partner and nothing arrives. Two kinds: a **mate** puzzle is a forced mate
(every solver move but the last is check and the only move that keeps the mate;
the last accepts any mate) and an **advantage** puzzle is a lila-style tactic
(one best move at each step, the engine's reply for the defender, the last move
of the line is the only accepted one). Themes use lila's camelCase vocabulary
and a static difficulty 1–3 (Easy / Medium / Hard).

The set is served as a small index plus immutable shards (`public/_headers`
caches `index.json` for ten minutes and `s*.json` for a year):

```
index.json          {version: 2, source, generated, count, shards: [...],
                     puzzles: [{id, kind, mate, moves, themes, difficulty, side, board, found, shard}]}
s00-<10 hex>.json   {puzzles: [full records]}, 50 per shard, named by content hash
```

A full record carries the FEN with reserves (`fen`), the board before the
opponent's last move (`prev`, animated in at the start when present), both
boards (`dual`, for **Both boards in Bughouse Lab**), the UCI and SAN line, the
legal moves at each solver step (the page has no move generator), `mates` at
the last step of a mate puzzle, `cp` for an advantage puzzle, and the game
context (players, ratings, FICS game number, date, time control, what was
played and whether the player found it).

```
set.ts          index/shard types, pure filtering + facet counts, theme/difficulty labels,
                deep-link hash parsing, PuzzleStore (index once, shards on demand, prefetch of the next)
puzzle.ts       data types, frozen-reserve moves, one Attempt (pure, tested in tests/bughouse-state.ts)
board.ts        one chessground board with each side's frozen reserve above and below it
app.ts          page controller: play, reply, Solution, Retry, #<id> deep links, results in
                localStorage (bughouse-puzzles-v2); a Settings sheet holds the filters (kind,
                length, level, theme, missed in the game), progress and the notes on the set
../bughouse/pocket.ts  a reserve as lila's crazyhouse pocket, shared with Bughouse Lab
```

Solving shows only the board, its two pockets, one feedback box in lila's
words ("Black to move", then "Best move!" or "Solved!"; no mate count and no icon), the moves and four buttons; who
played the game and whether they found the move stay out of the way. The link
to both boards in Bughouse Lab appears once a puzzle is over.

Styles: the shared trainer vocabulary (`src/styles/trainer.css`, also used by
the Tactics Trainer), the board and pocket in `src/styles/bughouse-board.css`
(Lichess's default brown at full brightness, lila's pocket), plus
`src/styles/bughouse-puzzles.css`.

## Smoke-testing

`npm run test:bughouse` bundles the focused TypeScript state tests with esbuild
and runs them in Node. `astro check` + `npm run build` check the site,
and a headless Chrome run (`puppeteer-core` is a dev dependency, Chrome must be
installed) exercises the real pages. Lichess answers non-browser user agents
with 404, so a headless run needs `page.setUserAgent(...)`.

The Bughouse Lab stores the accepted session locally and supports Copy moves,
BPGN download and Copy link. Its worker retains Hivemind between analyses and
Stop; model chunks survive reload when browser storage is available. See the
[static Bughouse guide](../../../tools/bughouse_web/README.md) for the export
format, cache boundaries and real-engine browser verification command.

## Bughouse expectimax

The lab and BughouseDB display saved `Exp White` and `Exp Black` tables from
`GET /api/bughousedb/expectimax?fen=<dual FEN>` (also included in `/position`).
Both are White's perspective on the selected board. CrazyAra probabilities are
an FICS-calibrated proxy for human moves, not a human-trained model. Each tree
retains Hivemind's best move plus the top four probabilities strictly above 1%.
No clocks or sitting enter the tree; captures still transfer to the partner.

The shared desktop builder lives in `tools/bughouse_db/expectimax.py`; see
[the algorithm](../../../docs/ALGORITHM.md#bughouse-expectimax). The API reads
`BUGHOUSE_EXPECTIMAX_PATH` (default `bughouse_expectimax.db` beside the server).
The builder's `run --publish-to SSH_HOST --publish-path /absolute/book.db`
publishes completed snapshots every five minutes by transactional SQLite merge.
An interrupted build preserves each engine evaluation locally. Only completed
trees are published, and old profiles remain available. `publish` also runs one
sync immediately. Alternatively, POST batches of up to 20 `{fen,board,data}`
records to `/api/bughousedb/expectimax/import` with the existing admin API key.

Saved expectimax requires the API; the existing in-browser Hivemind analysis
continues to work without it. Set `PUBLIC_API_URL=https://api.chessautoprep.com`
when building for the public site.

## Shared analysis and manual overnight population

Both browser entry points and desktop bulk analysis default to 800 Hivemind
nodes. Lab Analyze submits raw two-seat searches to `/api/bughousedb/evaluation`
using `/evaluation/ticket`; the server derives the calibrated value, validates
legal moves and budget completion, and preserves a deeper result. Exact
position/team/required-board/clock profiles stay separate. Saved results load
on navigation. A single position evaluation is not an expectimax tree.
BughouseDB's move-table upload returns the stored position, which renders
immediately; a failed upload keeps its payload for Retry save.

From the repository root, manually start a resumable, eight-core overnight run:

```sh
python3 tools/bughouse_db/overnight.py start --hours 8 --cores 8
python3 tools/bughouse_db/overnight.py status
python3 tools/bughouse_db/overnight.py stop
```

This creates one bounded systemd user service, not a timer. It queues up to
10,000 popular FICS positions, prioritizes positions contributed from the Lab,
then runs the existing clock-free two-ply builder at 800 nodes. It retains
Hivemind's best move plus the top four CrazyAra probabilities above 1%, saves
both colour columns, reuses deeper compatible evaluations, and publishes
completed tables every five minutes. Interrupted work resumes on the next
start; failed jobs are retried once per new run. Defaults use the owner's
`twic-vps` SSH alias and existing website database paths; `--local-only`
disables remote reads/writes. `--help` lists path, worker and budget overrides.
No population job starts merely by updating or opening the app.

## PGN workspace and browser expectimax

`/pgn` and `/expectimax` share `PrepWorkspace.astro`. PGN parsing runs in a
worker; 10 MiB / 40,000-move limits bound imports. Variations, comments, NAGs,
headers and custom FEN starts survive PGN export. Illegal imports leave the
accepted workspace intact. Board moves extend the current variation, including
underpromotions through SAN/UCI entry. The workspace saves to IndexedDB after
transactions commit; the cursor is a move path so export ordering cannot change
its meaning. Opening a tactics FEN adds an analysis game while preserving the
existing workspace, and consumes the URL parameter so reload retains edits.
Save failures remain visible. This is device-local storage: export
PGN for backups and desktop interchange; it is not account sync.

The search worker owns one Stockfish worker and one lazy ONNX Runtime Web Maia
session. `tools/prepare_prep_web.py` compresses the committed Maia model into
three checksum-verified chunks below Pages' 25 MiB limit (about 40 MiB total).
Maia uses the desktop encoder, mirrored black positions, rating inputs and
legal-move softmax. It runs with one WASM thread using the runtime already
prepared for bughouse, without cross-origin-isolation headers. Failed downloads
can be retried; verified chunks are cached when browser storage allows it.

Search expands breadth first. Every legal own move is retained; opponent
replies are ranked by Maia, cut to the configured coverage and count, and
renormalized. Leaves use Stockfish at the requested depth, converted to the
prepared side and the desktop logistic expected-score scale. Own turns take a
maximum; opponent turns take a weighted average. Engine scores shown in the
table also use the prepared side. These values are estimates, not empirical
win probabilities. Checkmate, stalemate, insufficient material and the 50-move
rule terminate search; threefold repetition is not inferred from FEN-only nodes.
The browser search does not claim identical trees or performance to desktop.

Expansions commit atomically. Stop/budget results are explicitly partial and
save along with the PGN; Resume accepts the same settings and an increased
position budget. Following a searched line displays its saved subtree. Export
JSON preserves the tree and search configuration.
Stockfish's in-memory evaluation cache survives repeated searches in the tab;
full result snapshots survive reload. Closing the tab ends computation. There
is no service worker: an already-loaded worker can analyse offline, but reopening
the website offline is not promised.

Tactics accepts local PGNs (choose White or Black), including custom starts,
as well as the existing account downloads. Uploaded PGNs stay on the device.
The viewer sends its PGN to Tactics through same-tab session storage. Puzzle
sets, outcomes and the selected puzzle save in IndexedDB and can be resumed;
the current puzzle restarts rather than restoring a half-played solution.

Focused checks from the repository root:

```sh
scripts/ci.sh with -- npm --prefix python/twic-position-finder/frontend run test:prep
scripts/ci.sh with -- npm --prefix python/twic-position-finder/frontend run build
scripts/ci.sh with -- npm --prefix python/twic-position-finder/frontend run test:prep:browser
```

The browser check serves the static build on loopback, uses a fresh headless
Chrome profile, blocks external requests, and exercises actual Stockfish/Maia,
PGN export/reload, cancellation, budgets/resume, offline inference and uploaded
PGN tactics. Desktop/phone screenshots are under `build/prep-web/`. It does not
access personal files or public shared analysis. The existing bughouse browser
suite uses its own isolated API database; see the static Bughouse guide above.
