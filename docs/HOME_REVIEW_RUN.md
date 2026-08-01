# Home review run — Design Note

**Status:** partly superseded (2026-07-30) by
[`GAME_REVIEW_ONE_PASS.md`](GAME_REVIEW_ONE_PASS.md), which replaces the
four-stage pipeline, the Start/Stop button, the games table and the
engine-settings gear with a single pausable pass, game cards and a Line tab.
Still current here: the shared games window, the header, and the rule that
nothing starts on its own.

Amends [`UNIFIED_HOME.md`](UNIFIED_HOME.md): the layout and the two-pane
structure described there stand; the window, the header copy, the Review column
and *when analysis runs* are all replaced by what is below.

## What was wrong

The unified home shipped with four problems that all had the same root — it
decided things on the user's behalf:

1. **A fortnight is not "recent".** `sinceDays = 14` is hundreds of blitz games
   for anyone who plays daily. "How am I doing lately" means the last handful
   of games, not two weeks of archive.
2. **Three copies of the same setting.** The list had `sinceDays`, the tactics
   fetch had `fetchMode` + count + days, and the prune/resume cutoff had its
   own. Changing "the last two weeks" in one place left the others behind.
3. **It committed the machine without asking.** `auto_analyze` defaulted on, so
   opening the app started a 20-game Stockfish pass over every core. On a
   modest machine the whole UI is the price of a list you might only have
   wanted to read.
4. **It talked instead of reporting.** "Congrats on +30 — keep it rolling!"
   sits between the user and the thing they opened the app to do. The Review
   column, likewise, said "2 blunders" and hid the inaccuracies entirely.

## The shared window

`lib/features/games/services/games_window.dart` — one setting, read by every
surface that asks which games are recent.

```dart
GamesWindow(mode: lastGames | lastDays, games: 20, days: 2)
```

- Default **last 20 games**. The day alternative starts at **2**, not 14.
- Both operands are always carried, so flipping the mode never discards the
  number typed for the other one.
- `gameLimit` in count mode, `cutoffFrom(now)` in day mode — never both, since
  each mode *is* the limit the user asked for.
- `label` ("last 20 games") is what every surface prints, so the list, the
  opening review and the job names all describe the same slice identically.
- `GamesWindowSettings` is the persisted singleton (`games_window.*`).
  `RecentGamesController` and `TacticsImportForm` both read it and both write
  it; the home settings dialog and the tactics import card are two views of the
  one value.

Deliberately **not** folded in: **puzzle expiry** — how long a mined mistake
stays trainable. That is a different decision, it stays on
`TacticsSessionSettings.maxAgeDays`, and it now says so on screen ("Expire
puzzles after: … · How long a mined mistake stays in the queue. Separate from
which games get fetched"). A second copy of it in the home dialog would go
stale the moment either surface was used, which is why there isn't one.

Also unified: **cores**. Mining kept `tactics_import.cores` separate from
`EngineSettings.workers`, so turning the engine down in Settings didn't slow
mining. There is now one value; the tactics engine dialog and the home dialog
both edit `EngineSettings.workers`.

## Start, not auto

`HomeReviewRunner` (`features/games/services/home_review_runner.dart`) is the
Start button as a state machine. It owns no work — it sequences the four
services that already existed and forwards a cancel to whichever is live:

```
fetching  → RecentGamesController.refresh(force: true)
analyzing → GameAutoAnalysisService.maybeRun          (mistake counts)
openings  → RecentGamesController.recomputeDeviations (left-book verdicts)
mining    → TacticsImportCoordinator.import per site  (puzzles)
```

- Provided in `_TacticsModeView`, not the pane: a run must survive the pane
  being swapped out for the board when a puzzle starts mid-review.
- The stage label is the progress line, in a fixed-height strip so starting a
  run doesn't push the table down.
- Stop is the same button. It reaches both engine consumers
  (`analysis.cancel()`, `import.cancelImport()`).
- Each stage keeps its own JobManager entry, so the app-bar task button still
  itemises them; the runner adds no umbrella job that would double-count.
- `recent_games.auto_run` (default **off**) is the opt-in for starting a run on
  load, and fires at most once per app session.
- `GameAutoAnalysisService` now *releases* its per-game claim when an analysis
  fails or is cancelled. With a manual Start, "it did nothing and won't try
  again until you restart" is a dead end.

## Header and Review column

Header, in order: username, one rating line **per (platform, speed) actually
played**, a counts line, and the designated books.

- Time controls are discovered, never assumed: a bullet-only player gets one
  bullet row, and nobody sees a Rapid row they never earned.
- The rating is labeled — `Blitz Elo 1543  +30  (12 games)` — because a bare
  number beside a signed delta is ambiguous. Platform is appended only when the
  window actually spans two of them.
- No encouragement line. The counts line is `20 games · 3 not analyzed ·
  2 left book`, and drops the parts that are zero.

Review column → `MistakeCounts`: three coloured numbers, inaccuracy · mistake ·
blunder (blue · orange · red), worst on the right, zeros kept visible so the
columns line up between rows. Unanalyzed reads `— — —` with a tooltip naming
Start. Full breakdown stays in the tooltip.

## Repertoire, reachable

- `MyRepertoiresPanel` is the designation UI, body only. Settings wraps it in a
  `SettingsGroup`; `showMyRepertoiresDialog` opens the same widget from the home
  header's "My books — White: … · Black: … [Change…]" row, next to the column
  it explains.
- `GameDeviationService.analyzeGameByRepertoire` reports **one verdict per
  designated folder** instead of collapsing to the deepest match. Two books for
  one colour is a supported setup; "the deepest wins" hid what the other said.
  `analyzeGame` still returns the deepest, for the per-game chip.
- `RepertoireCheckDialog` + a PGN-viewer app-bar button (`Icons.fork_right`,
  "Check this game against my repertoire") answer the same question for *any*
  game: pick a colour (pre-filled from the headers when a username matches),
  get a verdict per book, open any of them in the Game / Your-book review.
- `OpeningReviewDetailDialog` was generalised to take `ReviewGameSource`
  records (label + PGN) instead of `RecentGame`s, which is what lets an
  arbitrary pasted game use the same two-tab review.

## Background jobs have no app-bar button

Removed 2026-07-30. A spinner plus a count badge in five app bars announced
that *something* was happening without saying what, and the menu behind it was
a list of un-clickable rows with a Cancel at the end. Progress now stays where
the work was started and where its result appears: the home review's own
Start/Stop button and status line, the tactics import panel, and the repertoire
generation status chip. `JobManager` itself is untouched — only its global
button is gone.
