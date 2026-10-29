# chessautoprep.com — frontend

Static Astro site deployed to Cloudflare Pages. Browser preparation tools, one shared shell:

| Route                 | What                                                                 | Code                                   |
| --------------------- | -------------------------------------------------------------------- | -------------------------------------- |
| `/twic-notifications` | TWIC Alerts — create alerts anonymously, or manage them signed in    | `src/lib/alerts-page.ts` + `src/lib/*` |
| `/pgn`                | Analysis board on its PGN tab: lichess.org/analysis with Stockfish 18, PGN games, comments and variations | `src/components/AnalysisPage.astro`, `src/prep/*`, `src/analysis/*` |
| `/expectimax`         | The same board on its Expectimax tab: practical moves for both sides against Maia's replies, on this device | the same |
| `/tactics`            | Tactics Trainer — Stockfish in the browser mines puzzles from games  | `src/tactics/*`                        |
| `/bughouse`           | Bughouse — lichess.org/analysis/crazyhouse with + and − on every piece in both hands, lila's board editor and a sit panel; Lichess's crazyhouse Fairy-Stockfish in the browser | `src/analysis/*`, `../../../tools/prepare_crazyhouse_web.py` |
| `/bughouse-puzzles`   | Bughouse Puzzles — mates and tactics mined from FICS games, reserves frozen | `src/bughouse-puzzles/*`, `public/bughouse-puzzles/` |
| `/charles-clock`      | Charles Clock — a full-screen phone clock with its own `<html>`      | `src/pages/charles-clock.astro`, `src/lib/charles-clock.ts` |
| `/meow-chess/`        | Meow Chess — the Meow-Chess tournament director app, a Flutter web build copied in from its own repository | `public/meow-chess/` (built), `functions/meow-chess/fetch.js` |

`/` is the front page linking the tools. `/dashboard` forwards to
`/twic-notifications` (with the query string, so old login emails keep
working); `/verify` and `/unsubscribe` are one-shot token pages; `/book` is
an unlisted booking page. `public/_redirects` sends `/crazyhouse`,
`/bughouse-single-board` and `/bughousedb` to `/bughouse`.

```sh
npm install
npm run dev        # http://localhost:4321 — set PUBLIC_API_URL to point at a local server.py
npm run build      # → dist/ (runs the unit tests and astro check first)
npx astro check    # type-check .ts and .astro
npm run test:analysis  # the bughouse board's tree, hands, rules and judgements
npm run test:puzzles   # bughouse puzzles and the puzzle set
npm run test:prep      # PGN reading, the analysis tree, Maia input, expectimax, the tactics miner
```

Environment (build-time): `PUBLIC_API_URL` (default `https://api.chessautoprep.com`),
`PUBLIC_TURNSTILE_SITE_KEY` (empty disables the CAPTCHA widget).
`npm run dev` and `npm run build` also prepare the engines the pages
download: `tools/prepare_crazyhouse_web.py` copies Fairy-Stockfish out of
`@lichess-org/stockfish-web` and puts Lichess's crazyhouse net, pinned by
checksum, in gzipped parts under `/crazyhouse-engine/`;
`tools/bughouse_web/prepare_assets.py` copies ONNX Runtime for the
Expectimax tab's Maia under `/bughouse-engine/` (with the
[static Hivemind build](../../../tools/bughouse_web/README.md), which no page
loads now); and `tools/prepare_prep_web.py` splits Maia's model into
checksum-verified chunks. Every file fits Cloudflare Pages' 25 MiB asset limit.

## Layout

- `src/layouts/Base.astro` — the site's tokens (dark only, a muted blue
  accent; shared with the clock), nav, footer, and the primitive vocabulary: `.btn*`, inputs,
  `.card`, `.alert-*`, `.choice` chips, `.badge`, `.modal*`, `.status-panel`.
  Page-specific CSS lives with the page (`<style>`) or in `src/styles/`.
- `src/lib/` — the alerts feature and the clock. `api.ts` is the only place
  that talks to `server.py` (typed endpoints, `ApiError`); `alert-form.ts`
  owns one form (used for anonymous subscribe, create and edit);
  `alerts-list.ts` renders the signed-in cards;
  `filters.ts`/`eco-picker.ts`/`autocomplete.ts` are the filter builder;
  `board-preview.ts` is the dependency-free FEN renderer and the floating
  `HoverBoard`.
- `src/analysis/` — the bughouse board and the lila analysis pieces the PGN
  page shares with it:
  - `board.ts` the chessground board in analysis and editor modes, with the
    editor's spare-piece strips; `moves.ts` the move list (column or inline,
    folds, live ?!/?/?? marks, the right-click menu with Promote, Make main
    line, Force variation, Copy PGN, Delete); `variation-tree.ts` the
    rules-free move tree both pages extend (variations, promote, force
    variation, folds);
  - `ceval.ts` the engine panel (Show threat, progress bar, the board shown
    when hovering an engine move); `gear.ts` the engine gear's sliders;
    `shapes.ts` Lichess's arrows; `judge.ts` Lichess's winning chances, live
    marks and practice verdicts; `menu.ts` the ☰ menu (replay mode, the
    analysis switches) and the keyboard help; `settings.ts` the saved
    settings;
  - for `/bughouse` only: `tree.ts` (the crazyhouse move tree and hand edits),
    `engine.ts` (Fairy-Stockfish), `sit.ts` (the sit
    panel), `hand.ts` (a hand with + and −), `practice.ts` (Practice with
    computer) and `app.ts` (the page).
- `src/prep/` — the PGN and Expectimax tabs (below). `pgn.ts`,
  `pgn-client.ts`/`pgn.worker.ts` and `storage.ts` (IndexedDB
  `cap-preparation`) are also used by the Tactics Trainer.
- `src/tactics/`, `src/bughouse-puzzles/` — see below. `src/bughouse/` holds
  the small board, pocket, promotion and FEN helpers of the puzzle board.
- `public/stockfish/` — stockfish.js 18 single-threaded build (`stockfish.js` +
  `stockfish.wasm`). `public/piece/` — cburnett SVGs used by every board.
  `public/_headers` — caching and cross-origin isolation (below).

## Bughouse board

`/bughouse` is one board with crazyhouse rules, as Lichess's crazyhouse
analysis: a capture goes to the capturer's hand, and what a partner would
send arrives through a hand edit (`tree.ts`, pure, `npm run test:analysis`).
PGN is written with `[Variant "Crazyhouse"]`. A hand edit is
kept on its position and carried through the moves after it; the engine
always gets a bare FEN. Hands are capped at 16 of a piece and 64 pieces in
all (the crazyhouse net has 16 slots a piece). The tree is kept in
`localStorage` and comes back on a plain `/bughouse` and on reload; a `?fen=`
link opens that position unless it is the saved one. The FEN box, `?fen=`
links and PGN write the hand as Lichess does, a ninth rank
(`…/RNB1K2R/PNpnb w …`); they and the board editor read that or brackets,
and positions inside the page stay in chessops' bracket form.

`engine.ts` runs Fairy-Stockfish 14 with Lichess's crazyhouse NNUE, the
engine of lichess.org/analysis/crazyhouse (`@lichess-org/stockfish-web`),
multi-threaded on the page's main thread. One engine serves everything: the
shown position is searched first (10 seconds by default), then the sit
panel's rows (`sit.ts`: the side to move's position again with one more
pawn, knight, bishop, rook or queen, mating rows marked; 500,000 nodes a row
unless the gear's Sit search says otherwise). With ∞, the position is then
searched again without a limit; the hash keeps what the first search found,
and the panel keeps the deeper result until the new search reaches it.
Practice with computer answers after 600,000 nodes, Lichess's casual
strength.

The first download (the net, about 30 MB) shows its progress in the engine
header and is kept in the Cache API, checked against `net.json`'s checksums;
on a phone, tablet or data-saving connection the header asks first
(Download). A failed download or an engine error stops the engine with a Try
again button. The gear has sliders for Search time (2 s to ∞), Multiple
lines, Threads (1 to every thread up to 32, with a tick on the recommended
count, all but one, as lila) and Sit search; changing Threads restarts the
running search with them. The hash is 256 MB, or 64 MB on a device with
less than 8 GB of memory.

## Cross-origin isolation

Fairy-Stockfish's threads need SharedArrayBuffer, so `/bughouse`,
`/crazyhouse-engine/*` and `/bughouse-engine/*` are cross-origin isolated,
and `/_astro/*` (the bundled scripts) carries COEP too (`public/_headers`,
and the dev server in `astro.config.mjs`). Every bundled worker is then isolated, so
`/stockfish/*`, which the Expectimax tab's worker starts, is isolated as
well. The other pages are not cross-origin isolated.

## PGN and Expectimax

`/pgn` and `/expectimax` are one page (`src/components/AnalysisPage.astro`,
`src/prep/app.ts`) opened on the tab its address names; switching tabs (or E)
changes the address and the highlighted nav link without reloading. It is the
bughouse board's lila layout without the hands, built from the shared
`src/analysis/` pieces. Above the tabs is Stockfish's panel (`live-engine.ts`,
`stockfish.ts`): Stockfish 18's single-threaded build from
`public/stockfish/`, the gear's search time (2 s to ∞) and 1 to 5 lines, Show
threat, hover boards and click-to-play lines, as on Lichess.

- **PGN** (`tree.ts`, `games.ts`): a file (Open file, drag and drop), a paste
  under the board or anywhere on the page, or a `?fen=` link opens games. A
  file or paste replaces the open games; a FEN, the board editor and ☰ New
  analysis add one. A worker splits files with chessops (10 MiB, 20,000 games
  at most); a paste with nothing playable in it is refused and the open games
  stay. Several games get a list with a filter and ‹ › between them. The move
  list is lila's, with comments (clock and eval tokens hidden, kept in the
  PGN), the game's own glyphs in lila's colours, and a right-click Comment
  beside Promote, Make main line, Copy and Delete. Games, the game shown, the
  move shown and the orientation are saved in IndexedDB (`analysis-v1`) shortly
  after a change and come back on reload; an older `current` workspace is
  read when nothing newer exists. Download writes every open game; Find
  tactics hands them to the Tactics Trainer through same-tab session storage.
- **Expectimax** (`expectimax.ts`, `expectimax-runner.ts`, `expectimax-view.ts`):
  the desktop's practical search
  ([Interactive Expectimax](../../../docs/ALGORITHM.md#interactive-expectimax-search-tab)).
  One Search press runs it twice from the board, with White and then Black as
  the prepared side. Our moves are Stockfish's MultiPV shortlist (First moves
  4, Later moves 4); their replies are Maia's likeliest at the Rating until
  they cover the Reply share (90%), at most Replies (5), renormalised; a line
  met less than once in Rare lines (100) games keeps its engine score. Breadth
  first, one ply at a time; positions are searched once at the Engine depth
  (12). Leaves score 1 / (1 + e^(−0.00368208·cp)); checkmate and the rules'
  draws are exact; threefold repetition is not known from a FEN. Rating
  (600–2600, default 1600) and Depth (1–8 plies, default 4) sit on the bar as
  − box + steppers; the rest is in its gear. A side holds at most 8,000
  positions.
  The table at the board's position shows Move, Played (Maia's share),
  White, Black (each side's value, as an engine score from White's side) and
  Engine; clicking a row plays it, hovering draws it. Browsing never
  searches: a position no search reached says so. Searches are found again by
  position, kept in IndexedDB (`expectimax-v1`, the last 16), saved after each
  complete ply, and a search the page closed on comes back as stopped.
  Stockfish runs on a pool of workers (cores − 1, at most 6; 2 on a device
  with 4 GB or less) started one at a time; a worker that fails hands its job
  to another. Maia runs in its own worker on ONNX Runtime Web's WASM build
  (one thread, `maia.worker.ts`), its chunks kept in the Cache API once
  verified. A failed download says so on the status line; the next Search
  tries again. These are model estimates, not measured win probabilities, and
  closing the tab ends a search.

## Tactics trainer

```
sources.ts      fetch games (Lichess PGN with evals=true; Chess.com monthly archives)
pgn.ts          split/parse PGN, keep [%eval] comments
miner.ts        replay a game → user-move sites → fan out to the engine pool → Puzzle[]
engine/         UciWorker (one Stockfish worker, promise API) and EnginePool (N workers, one queue)
store.ts        IndexedDB: puzzles per game+depth, opening evals by FEN+depth
win-chances.ts  lila's thresholds over the shared winning-chances formula (src/analysis/judge.ts)
board.ts        Chessground wrapper (legal moves from chess.js, arrows, review)
app.ts          page controller: setup → analysing → train
settings.ts     localStorage settings
```

Besides account downloads, the trainer accepts local PGNs (choose White or
Black), including custom starts, and the games the PGN page sends it.
Uploaded PGNs stay on the device. The puzzle set, outcomes and the selected
puzzle save in IndexedDB and can be resumed; the current puzzle restarts
rather than restoring a half-played solution.

Speed comes from the same tricks as the Dart app's tactics import:

1. **A pool of single-threaded engines, not one multi-threaded engine.** Every
   position of a game is submitted at once; the pool keeps every core busy.
2. **Best-move skip.** If the user played the engine's first PV move, the
   position after it is not searched.
3. **Lichess server evals.** With `evals=true` the PGN carries `[%eval]` on every
   ply of analysed games; those decide the verdict without an engine, and only
   real candidates are searched (for the best line).
4. **Caches.** Opening positions (fullmove ≤ 12) are memoised across games and
   persisted; a game analysed once at a depth is never analysed again.
5. **Training starts before analysis ends.** Puzzles stream into the session;
   the banner shows the count until the run finishes.

Verdicts use lila's winning-chances model and thresholds, so this trainer,
the Dart app, and Lichess agree on what a mistake is.

## Bughouse puzzles

`public/bughouse-puzzles/` is generated, not hand-edited:
`python3 -m bughouse_db puzzles --year 2017 --games 1500 --engine PATH` from
`tools/` (Fairy-Stockfish binary; see `tools/bughouse_db/puzzles.py`). Each
puzzle is one board of a real game with the reserves frozen: captures go to the
partner and nothing arrives. The engine plays that rule through
`tools/bughouse_db/frozenhouse.ini` (crazyhouse with `capturesToHand = false`);
Fairy-Stockfish's own `bughouse` variant also searches drops of pieces a
partner might send, which made most early tactics wrong.

Two kinds. A **mate** puzzle is a forced mate: every solver move but the last
is check and the only move that keeps the mate, and the last accepts any mate.
A check a dropped piece could block is not mate, as on FICS. A **tactic** wins
material and keeps the initiative:

- the first move is the only one worth the name (lila's win-chance gap, or
  `--unique-cp`, 300 in the published set, over the second best);
- every solver move before the last is a check or a capture (`--forcing`), so
  the defender never gets a quiet moment to sit and wait for their partner;
- where several moves would follow, the line takes one more step only if its
  best move takes something, accepting any capture or check that wins nearly
  as much (`--collect-cp`), so a fork is played out to the capture;
- at least `--min-gain` (3) material is won, counted a few moves into the
  engine's line and against the board before the opponent's last move, so a
  recapture or a piece taken straight back wins nothing;
- the solver is still at least 2 pawns ahead when the defender is handed a
  pawn, then a knight (`--sit`), as a partner might.

`--candidates-out` keeps a scan and `--from-candidates` verifies it again under
other rules; every run prints why candidates were turned down. Themes use
lila's camelCase vocabulary (including `fork`) and a static difficulty 1–3
(Easy / Medium / Hard).

The set is served as a small index plus immutable shards (`public/_headers`
caches `index.json` for ten minutes and `s*.json` for a year):

```
index.json          {version: 2, source, generated, count, shards: [...],
                     puzzles: [{id, kind, mate, moves, themes, difficulty, side, board, found, shard}]}
s00-<10 hex>.json   {puzzles: [full records]}, 50 per shard, named by content hash
```

A full record carries the FEN with reserves (`fen`), the board before the
opponent's last move (`prev`, animated in at the start when present), both
boards as the archive recorded them (`dual`), the UCI and SAN line, the legal
moves at each solver step (the page has no move generator), `mates` at the
last step of a mate puzzle, `cp` for an advantage puzzle, and the game
context (players, ratings, FICS game number, date, time control, what was
played and whether the player found it).

```
set.ts          index/shard types, pure filtering + facet counts, theme/difficulty labels,
                deep-link hash parsing, PuzzleStore (index once, shards on demand, prefetch of the next)
puzzle.ts       data types, frozen-reserve moves, one Attempt (pure, tested in tests/puzzles.ts)
board.ts        one chessground board with each side's frozen reserve above and below it
app.ts          page controller: play, reply, Solution, Retry, #<id> deep links, results in
                localStorage (bughouse-puzzles-v2); a Settings sheet holds the filters (kind,
                length, level, theme, missed in the game), progress and the notes on the set
../bughouse/    the reserve as lila's crazyhouse pocket, the promotion picker, FEN reading
```

Solving shows only the board, its two pockets, one feedback box in lila's
words ("Black to move", then "Best move!" or "Solved!"; no mate count and no
icon), the moves and four buttons; who played the game and whether they found
the move stay out of the way. Once a puzzle is over, **Analyse this board**
opens its position on `/bughouse`.

Styles: the shared trainer vocabulary (`src/styles/trainer.css`, also used by
the Tactics Trainer), the board and pocket in `src/styles/bughouse-board.css`
(Lichess's default brown at full brightness, lila's pocket; also used by the
analysis boards), plus `src/styles/bughouse-puzzles.css`.

## Meow Chess

`public/meow-chess/` is the browser build of
[Meow-Chess](https://github.com/Zinkelburger/Meow-Chess), a separate Flutter app,
committed here as built files because Pages cannot build Flutter. **It does not
update itself.** When Meow-Chess gains a feature or fix worth having on the
site, rebuild and replace it from the Meow-Chess checkout:

```sh
python3 scripts/build_web.py --site ../Chess-Auto-Prep   # in Meow-Chess
```

then commit `public/meow-chess/` here. `public/meow-chess/meow-build.json`
names the Meow-Chess commit it came from. Meow-Chess's `docs/WEB.md` describes
what differs from the desktop app.

`functions/meow-chess/fetch.js` is a Cloudflare Pages Function, the site's only
server-side code apart from `server.py`: Pages runs every file under
`functions/` at its path. It fetches pages for the app at
`/meow-chess/fetch?url=…`, because US Chess, FIDE and club websites send no CORS
headers and a page cannot read them itself. It fetches only HTTPS URLs on its
host allowlist; add a host there when Meow-Chess learns to read a new site.
`npx wrangler pages dev dist` runs it locally after a build.

## Checks

`npm run test:analysis`, `test:puzzles` and `test:prep` bundle the focused
TypeScript tests in `tests/` with esbuild and run them in Node (`npm run
build` runs all three and `astro check` first). Lichess answers non-browser
user agents with 404, so a headless run that reaches it needs
`page.setUserAgent(...)`.

Two browser checks drive the built site in headless Chrome (`puppeteer-core`
is a dev dependency; Chrome must be installed, `CHROME_BIN` overrides
`/usr/bin/google-chrome`). Both serve `dist/` on loopback with
`public/_headers` applied (`scripts/static-server.mjs`), so an isolation
mistake fails locally. From the repository root:

```sh
scripts/ci.sh with -- npm --prefix python/twic-position-finder/frontend run build
scripts/ci.sh with -- npm --prefix python/twic-position-finder/frontend run test:prep:browser
scripts/ci.sh with -- npm --prefix python/twic-position-finder/frontend run test:bughouse:browser
```

- `test:prep:browser` uses a fresh profile, blocks external requests, and
  exercises the PGN tab (games list, comments, variations, an engine line's
  move, reload, a refused paste, the `?fen=` handoff, Download), real
  Stockfish and Maia expectimax for both sides (table, following a move,
  reload, Stop, a search offline) and uploaded PGN tactics. Screenshots go to
  `build/prep-web/`.
- `test:bughouse:browser` drives `/bughouse` with the real engine at desktop,
  1366×768 and phone sizes, through a failed download and a phone's first
  visit, and writes screenshots to `build/bughouse-web/`.
