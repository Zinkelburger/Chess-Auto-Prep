# Unified home — Games inside Tactics — Design Note

**Status:** implemented (2026-07-29). Supersedes the standalone Games mode
from [`RECENT_GAMES_AND_NAVIGATION.md`](RECENT_GAMES_AND_NAVIGATION.md)
(everything else in that doc — breadcrumbs, deviation, viewer handoffs —
stands and is reused here).

> **Partly amended by [`HOME_REVIEW_RUN.md`](HOME_REVIEW_RUN.md)** (same day,
> later). The layout and two-pane structure below stand. The 14-day window, the
> welcome-header copy, the "2 blunders" Review chip and the automatic analysis
> pass do **not** — they became the shared 20-game window, a labeled Elo line,
> three coloured counts, and an explicit Start button. Read that note for the
> current behaviour of those four.
>
> **Further amended by
> [`GAME_REVIEW_ONE_PASS.md`](GAME_REVIEW_ONE_PASS.md)** (2026-07-30).
> "Background auto-analysis" and "Shared evals between analysis and mining"
> below are **gone**: `GameAutoAnalysisService` is deleted, and the mining pass
> reports each game's mistake counts itself, so there is only one engine pass
> over a game's moves. That note also closes the follow-up this one left open —
> mining now reads the games-library corpus instead of downloading its own copy.

## Why

The Games mode proved the data pipeline but split the user's attention: the
first screen of the app was a table, and training lived one menu hop away.
User request: *one* home. Come home from work, open the app, and in a single
view see "how am I doing, where did I go wrong, what should I train" — then
click straight into any of those.

## User stories

1. **Welcome back.** I open the app and the first thing I read is a friendly
   header: my rating trend over the last two weeks ("Blitz 1543 · +30 over
   12 games"), how many games are new since I last reviewed, and whether I
   left my prep anywhere. Tone: encouraging, not clinical.
2. **Where did I go wrong?** Each recent game row tells me at a glance:
   result, whether I left book (and who deviated, at which move), and — once
   the background analysis has run — how messy the game was ("2 blunders" /
   "Clean"). One click opens the full review; the deviation chip deep-links
   into the repertoire at the exact line.
3. **No waiting.** Analysis ran in the background while I was reading the
   list (or before I even sat down), so opening a game shows the eval graph
   immediately. Downloaded Lichess games that already carry server evals
   never touch my CPU.
4. **Train right there.** The right half of the same screen is the tactics
   panel exactly as before. Starting a session swaps the games list for the
   board; ending it brings the list back.
5. **Recent means recent.** The list shows the last 14 days (same window
   tactics uses for pending games), so it reads as "this fortnight", not an
   archive. The window is adjustable in the gear dialog.

## Layout

`AppMode.games` is **removed**; `AppMode.tactics` is the default landing
mode. The Tactics screen keeps its two-pane layout; only the *idle* left
pane changes:

```
┌───────────────────────────────────┬──────────────────────────┐
│  Welcome back, MaouTanner!        │  [Tactic | Browse] tabs  │
│  Blitz 1543 · +30 (12 games) 🎉  │                          │
│  3 games to review · 1 left book  │  (unchanged              │
│  ─────────────────────────────    │   TacticsControlPanel)   │
│  Recent games        ⟳  ⚙        │                          │
│  ⚡3+2 me(1543)–Big(1601) 1-0 …  │                          │
│  ⚡3+0 …            2 blunders … │                          │
└───────────────────────────────────┴──────────────────────────┘
```

- Idle: left = `TacticsGamesPane` (new), flex 6 : 4 — the list is the star
  when nothing is being trained. During a session: `_TacticsBoardPane`
  unchanged, flex 5 : 5 as today. The swap is keyed on
  `TacticsSessionController.hasActivePosition`, the same signal the board
  already uses for `enableUserMoves`.
- Compact (< 960 px) stacks vertically as today; the games pane gets full
  width there.
- Row slimming for the narrower pane: no Moves column, date without year
  (everything is ≤ 14 days old), Players and Repertoire are the two flexible
  (ellipsizing) cells so the row can never overflow. The Review button cell
  doubles as the **summary chip** once the game is analyzed: worst category +
  count ("2 blunders", danger-colored; "1 mistake"; "3 inaccuracies";
  "Clean"), full breakdown in the tooltip. Row click still opens the game.
- The games-specific app-bar actions (refresh, filter gear) move into a
  small header row inside the pane; the Tactics app bar keeps
  Jobs/Settings/Mode buttons.
- `RecentGamesController` moves into `_TacticsModeView`'s `MultiProvider`
  (it must outlive pane rebuilds and mode switches, like the other tactics
  state objects).

## Welcome header

Pure computation in `lib/features/games/services/rating_trend.dart`
(unit-tested): group the (already newest-first) games by (platform, speed),
take groups with ≥ 2 rated games, delta = newest `myElo` − oldest within the
window. Headline = the group with the most games; up to two shown.
Friendly line: delta > 0 → "Congrats on +N!", delta < 0 → "Down N — review
your mistakes below", flat/unknown → neutral nudge. Also: games count,
unanalyzed count ("N to review"), count of games where *I* left book.
Static layout, usernames visible, no animation.

## Expiry

`GamesListFilters.sinceDays`, default **14**, `0` = all time (same encoding
as tactics' `TacticsSessionSettings.maxAgeDays`). Cutoff mirrors tactics'
`sinceCutoff`: start of today − (N−1) days. Applied in
`RecentGamesController` after merge; undated games are kept (tactics
exempts undated too). Display-level only — the on-disk cache keeps its
1000-game cap; the draft/repertoire flows that read the same cache are
unaffected.

## Background auto-analysis

`GameAutoAnalysisService` (`lib/features/games/services/`), singleton,
JobManager-visible (`JobType.gameAnalysis`, cancellable, engine-pool
retained like the tactics import job):

- Trigger: games pane calls `maybeRun(games)` whenever the controller
  finishes a load and the pref is on (`recent_games.auto_analyze`, default
  on, checkbox in the gear dialog). Idempotent: session-processed set +
  active-job guard.
- Work list: in-window games with a known user side that are not already
  analyzed, **newest first, capped at 20 per run** (the job label says so —
  no silent cap).
- "Already analyzed" = the mainline carries `[%eval]` on all but ≤ 2 plies
  (mating move exempt) — the same tolerance `_parseCachedEvals` uses. This
  makes Lichess server evals count, for free.
- Per game: a headless `GameAnalysisController.analyzeGame` at
  `EngineSettings.depth`, then the annotated game is **patched into the
  cache file by dedupKey** (`GamesLibraryService.patchGame`, atomic write —
  the first patch-by-dedupKey write; the viewer's whole-file rewrite is
  unchanged for now). The pane recomputes that row's summary chip.
- Collision rule: the game currently open in the PGN viewer is skipped (the
  viewer registers a `currentlyOpenGame` supplier); the viewer's own
  auto-analyze covers it.

## Shared evals between analysis and mining

Two disjoint corpora (games-library cache vs `imported_games.pgn`) make
comment-level sharing useless; the shared substrate is the existing
persistent **`EvalCache`** (SQLite, White-normalized cp + depth, no PV):

- Game analysis **writes** every ply's score into it (skipping mates —
  the cache is cp-only and its consumers assume cp semantics).
- Mining's **evalB** (position after the user's move — score-only, PV
  optional) **reads** it first (`minDepth` = run depth, sign re-normalized
  to side-to-move) and skips the engine on a hit; mining also writes its
  A/B results back. **evalA keeps the engine** — it needs a real PV for
  best-line construction and the FEN-identity skip.
- Net effect: after the nightly auto-analysis pass, mining a fresh batch
  skips roughly half its searches — the user's intuition ("we've already
  evaluated all of ours") made concrete.
- Non-goal (follow-up): pointing mining at the games-library corpus itself.

## Test impact

Boot integration test + `widget_test.dart` assert the new Tactics landing
(games empty state inside the tactics scaffold); `app_history_test.dart`
root crumb becomes Tactics; mode-menu test drops the Games entry. New unit
tests: rating trend, expiry window, summary-from-evals, `patchGame`.
