# Game review: one pass, one button — Design Note

**Status:** implemented (2026-07-30). Amends
[`HOME_REVIEW_RUN.md`](HOME_REVIEW_RUN.md): the shared games window and the
"nothing starts on its own" rule stand; the four-stage pipeline, the Start/Stop
button, the games table, the engine-settings gear and the repertoire-check
dialog are all replaced by what is below.

## What was wrong

Six complaints, one theme — the screen was assembled from the *implementation's*
parts instead of the user's:

1. **Two engine passes over the same positions.** A full-game analysis wrote
   `[%eval]` comments so the list could count blunders, and then mining searched
   the same moves again to build puzzles from them. Both classify a move by the
   same winning-chance swing. The machine did the work twice.
2. **Start/Stop, not play/pause.** "Stop" reads as *abandon*. The run was
   resumable in fact — nothing was thrown away — but nothing said so.
3. **Cores and depth behind a gear.** The two knobs whose cost you feel
   immediately (how much of the laptop goes away, how long the wait is) were
   fields inside a dialog behind an icon, two clicks from the button that spends
   them.
4. **A table of games nobody could recognise.** Seven narrow columns, every cell
   ellipsized, no board. A list of `3+0 · me/opp · 1-0` rows is not a list of
   *your games*.
5. **Twenty rows at once.** Nobody reviews twenty games in a sitting.
6. **Dialogs where the viewer already existed.** "Check this game against my
   repertoire" opened a popup that opened a second popup with a small board —
   re-creating, badly, what the PGN viewer *is*.

## One pass

`_analyzeGameParallel` already evaluated the position before and after every
move the user played. Those two numbers *are* the mistake classification
(`0.10 / 0.20 / 0.30` winning-chance swing — the same thresholds
`classifyMove` uses). So the miner always knew each game's counts; it just had
nowhere to put them.

It does now: `GameReviewStore`
(`services/games_library/game_review_store.dart`), a persisted
`dedupKey → ReviewCounts` map.

- The miner reports every reviewed game through `GameReviewedCallback`,
  including **clean** ones — "reviewed, nothing wrong" has to be tellable from
  "not reviewed yet", which is exactly what a missing entry used to mean.
- `TacticsImportCoordinator` files them, so *every* mining path records counts,
  not just the review button's.
- `RecentGamesController` listens to the store, so rows fill in as the pass
  goes without the list knowing a review is happening.
- Counts still fall back to `summarizeGameReview` (parsed `[%eval]`s) for games
  analyzed in the viewer.
- Consequence: `GameAutoAnalysisService` is **deleted**, along with its
  viewer-collision guard. There is no second annotator to collide with. Opening
  a game and pressing analyze still does a full-game pass — that is where the
  eval graph is, and it is on demand.

## One download

The review also fetched every game twice: once into the games-library cache for
the list, and again into `imported_games.pgn` for the engine pass. Same API,
same window, two round trips — and two slices that could disagree about which
games "recent" meant.

`TacticsImportService.reviewFetchedGames` takes the PGNs the list already holds
(`HomeReviewRunner._fetchedPgnsFor`), saves them through the same `_savePgns`
path (GameId headers, resume queue, source-game store) and analyzes those. An
empty list falls back to fetching, so a failed list load still leaves the review
working. This closes the follow-up
[`UNIFIED_HOME.md`](UNIFIED_HOME.md) left open ("pointing mining at the
games-library corpus itself"), and with it the shared-`EvalCache` handshake that
existed to make the second pass cheaper — the second pass is gone.

## One button

`HomeReviewRunner` is now a transport: `idle → fetching → openings → reviewing
→ done`, with `paused` reachable from any busy stage.

- **Starts paused.** The job is on screen from the moment the pane opens, at
  `idle`, with a play button. `recent_games.auto_run` (default off) remains the
  single opt-in for starting on launch — the tactics *auto-fetch* pref is gone,
  because two "start automatically" toggles for one job is one too many.
- **Pause is the same button.** `pause()` cancels the engine pass and holds the
  stage at `paused`; pressing play calls the same `start()`. Resuming is free
  rather than clever: the fetch is cached, the book check is instant, and the
  engine pass already skips games it finished.
- **Openings before the engine.** The book verdicts cost nothing and change
  whenever a chapter is edited, so they land within a second instead of behind
  minutes of Stockfish.
- **The fetch is not forced.** Pressing play twice a minute apart no longer
  re-downloads: the games cache has a TTL, and the strip's refresh button is the
  deliberate "go and look again". This also fixes the reported "Start review
  doesn't work" — `refresh()` used to *no-op* when a load was already in flight,
  so pressing play during the first-visit load reviewed an empty list. It now
  hands back the in-flight future (`_inFlight`).

## The strip says what it costs

`ReviewStrip` — play/pause, a status line, a progress bar, and steppers for
**Cores (n of m)** and **Depth**. `MiningSettings` (new) owns depth the way
`EngineSettings.workers` owns cores: one owner, edited in the one place it is
visible. `TacticsImportForm` no longer keeps a copy of either, which is how
they got out of step before.

The strip and the header are **always on screen** once an account exists; only
the list area shows loading/empty states. The play button used to be inside the
"games loaded" branch — missing exactly when it was needed.

## Cards, not columns

`GameCard` replaces the table: the **final position** as a board (from my side),
players with ratings and score, speed · time control · date, the **ECO and
opening name**, and the first moves. Lichess solves this problem this way and it
is worth copying; `opening=true` was added to the Lichess fetch to get the
headers, and Chess.com's `ECOUrl` slug supplies the name where it doesn't.

- `StaticBoardThumbnail` (already used by tactics browse) got a `flipped`
  override, so the preview is oriented the way you played it.
- Final positions come from `finalFensBatch` in the same `compute` batch as the
  SAN extraction — never on the frame that builds the list.
- **Five cards**, then a footer that either reveals the rest or says there is no
  rest. A list that silently stops at five looks like a bug.
- Three click targets, each opening the game *at the thing clicked*: the card →
  Game tab, the mistake counts → Analysis tab (with the engine), the book
  verdict → Line tab.

### The moments strip

On a card wide enough (board + 300px of text + one moment, see
`GameCard.stripFits`) the empty right half holds a **strip of moments**: one
small board per thing worth a second look, in game order — the position where
the game left the book (played move drawn red when mine, book move green) and
each of my classified mistakes (played move in the mistake's hue, engine move
green when a `[%pv]` was stored). `buildGameMoments` in
`features/games/services/game_moments.dart` derives them from the deviation
report and the review summary; `RecentGame.moments` memoises the result until
either input is reassigned. Clicking a moment hands the viewer a `ply` along
with the tab (`OpenPgnViewer.ply` → `PgnViewerController.goToPly`, applied one
frame after the game is selected so the widget has taken the new game).

The strip scrolls sideways on its own with an always-visible scrollbar; the
board and the text never move, and a plain wheel over it still scrolls the
games list. No cap, no "+N".

For the mistakes to exist the summary has to come from the eval series, not
the count store: `GameReviewSummary.moments` is filled by `summaryFromEvals`,
`RecentGamesController._mergeSummary` prefers the parsed summary whenever its
counts agree with the store's, and `applyAnnotatedMovetext` reads a game's
series the moment the engine pass reports it, so the strip fills in during a
run rather than on the next load.

### Lines behind the scores

Every place a mistake is shown — the Analysis tab's cards, the inline
`Blunder +0.3 → +2.1  Best: …` mark in the movetext, the moments strip's
green arrow — offers the engine's line from the position before it, read
from a `[%pv]` beside the `[%eval]`. Two passes write them, one convention
(the line from *before* the move, what to have played instead):

- The review pass keeps the PV of every position it searched
  (`annotateMovetextWithEvals(plyPvs:)`), so a game reviewed from the home
  opens with clickable lines on its mistakes. A score served from the shared
  eval cache has no line behind it, and a game annotated before lines were
  kept has none at all.
- So the viewer fills what is missing on open:
  `GameAnalysisController.fillMissingBestLines` searches just the classified
  moves with no line, at the depth the series was scored at, puts the lines
  on the loaded evals and writes them back through `persistMoveComments`,
  once. It stays silent while a full analysis runs, while generation holds
  the engine, or when no engine can be started.

Writing annotations back used to reload the widget and park the reader at
move one (and restart a solitaire game). `ViewerGameModel.adoptAnnotations`
takes the new comments and glyphs onto the loaded mainline in place when the
moves and the stored sidelines are the same game; anything else still
reloads.

## The Line tab

The PGN viewer's side panel is **Game · Line · Analysis**.

`RepertoireLinePanel` (replacing `RepertoireCheckDialog` and the viewer's use of
`OpeningReviewDetailDialog`): pick a colour, get one verdict per designated
book, and step the prepared line on the *real* board with the game one tab away.

- The tab that is on screen owns the board. Leaving Line restores the game's
  cursor (`_gamePanePosition`), so flipping between them compares one position
  rather than fighting over one board.
- Arrow keys follow the visible tab (`_lineWidgetController`).
- Tab indices are named constants: an `animateTo(1)` meaning "Analysis" is
  exactly what broke when Line was inserted before it.
- The deviation banner's action is now "Show my line" (the tab), and the
  aggregate review's detail dialog leads with "Open in viewer". "Edit in
  Builder" survives everywhere as the deliberate, differently-worded trip to
  change the book — reviewing a line and editing it are not the same verb.
- The app bar's fork-icon button is gone with the dialog, and so are the
  `_actionDivider()` hairlines: a thin vertical rule beside an icon reads as
  part of the button, not as a group boundary.

## Readability and the two play buttons (2026-07-30, later)

A second pass over the same screen, from use rather than design. Six complaints,
again with one theme — the page was legible to whoever built it.

**One column starts things; the other is what they act on.** The home had *two*
big play buttons half a window apart: Review games on the strip, and Start
Practice Session in the right pane's card. They are step one and step two of one
loop (find my mistakes → drill them), so they are now the first and second
button of one control, stacked, on the strip. The right pane's card keeps the
filters and says what is in the database ("12 of 40 puzzles ready"); it has no
button of its own.

- `TacticsSessionController` gained `sessionSettings` (+ `setSessionSettings`)
  and `onStartRequested`. The settings moved out of the panel's start card
  because two surfaces need them now: the card that edits them, and the left
  pane's button, which has to count what they queue. `onStartRequested` is the
  same sibling-panes bridge `onBackRequested` already was — the button is in the
  pane, setting a puzzle up is still the panel's job.
- The import status banner and the resume-analysis banner are **deleted**. A
  second progress readout on the opposite side of the screen, with its own pause
  button and a Dismiss that hid live progress, is what made the page read as two
  apps. The strip is the one place a run is started, reported on and paused.
  "Resume analysis" is the strip's play button: pressing it when the games are
  already downloaded skips to the ones with no counts yet.
- The strip leads with the **work waiting**, not a game count: "16 games to
  analyse", "Analysing game 4 of 16", "Paused — 16 games left", "No new games to
  analyse". There is still no cancel, only pause.

**Type sizes.** The left pane ran at 10–12px in `onSurfaceDim`/`onSurfaceMuted`
— unreadable at a glance, which is the only way anyone reads a game list. Game
cards, the header, the strip and the footer moved up 1.5–2px each and one step
brighter. The breadcrumb trail went 12.5→14px with the current crumb at full
`ink`: where you are is not a footnote.

**Copy that only made sense from inside the code.** "Which games — shared with
the list on the left" → "Which games count as recent". "Last downloaded …" is
hidden entirely when the username box is empty (an account you don't have has no
download history). "Amend game — moves, marks & comments are saved to the file
(A)" → "Amend game (A)".

## "Game 301 / 312"

Opening your most recent game from the list showed a counter nobody could read.
It was not wrong: the games cache is a *merge log* (fresh downloads append, and
the two sites' fetchers hand back their own orders), so file order is fetch
history, and the game you played five minutes ago lands wherever its batch did.

`GameSortMode.dateDesc` ("Newest first", `pgnHeaderSortKey` on `UTCDate`/
`UTCTime`) fixes the question rather than the number: `_goToGameById` sorts
before it locates, so anything opened from the recent-games list is ordered the
way that list is. The newest game is Game 1, Prev/Next walk through time, and the
counter's tooltip names the ordering it is counting in.

## Single-game focus

Arriving with one game named is a different job from opening a collection, so
the app bar's slice machinery (the `bigman as White` / `bigman as Black` preset
chips, the `+ Slice` chip, the filtered/total counter) is taken off the bar —
`_singleGameFocus`, set by a `gameId` handoff and cleared by opening any file
yourself. Filtering stays reachable from the overflow menu ("Filter these
games…"), which also clears the focus.

## Which book line, and where it splits

Every line `matchingBookLines` returns shares the deviation's matched prefix, so
they are identical up to the fork and differ at exactly one ply. The Line tab's
dropdown hid the only thing worth comparing; it is a row per line now, labelled
by **the move that line plays at the fork**, with the chapter name and how much
further it goes. Above the movetext, one line of ephemeral context — "You played
3… Nf6 — this line plays 3… cxd4" — which is a note, not a PGN comment: the
chapter's comments are the author's and get saved, this is about *your* game and
is true only while that game is on the board.

## Escape, everywhere, means "leave what I'm in"

One contract, innermost first, on every screen with a mode:

| Screen | Escape |
| --- | --- |
| PGN viewer | solitaire → amend → fullscreen → clear scratch moves |
| Tactics | PGN/Browse tab → leave the puzzle (same as the back arrow) |
| Repertoire trainer | leave the line being drilled |
| Player analysis | back to the first tab |

Solitaire also answers to **Ctrl+S** now (Shift+S kept — it is what the mode has
always answered to), and its Exit chip advertises Esc.

## Revision, July 30: the strip talks less and says more

Four things read badly once the screen was lived in.

**`Cores − 4 of 8 +   Depth − 15 +`.** Point 3 above swung too far: putting the
knobs *on screen* was right, making them four tap targets was not. Two numbers
nobody changes twice a week don't need eight pixels of plus and minus each, and
"4 of 8" took a second look to parse. The strip now states them —
"Reviewing uses 4 of 8 CPU cores, at search depth 15" — with a **Review speed…**
button next to it opening `ReviewSpeedDialog`: two textboxes, out-of-range input
clamped rather than refused. Same two owners (`EngineSettings.workers`,
`MiningSettings.depth`), same "changing it here changes it everywhere".

**No resume button.** There was one, but only for a run paused *this session*
(`HomeReviewRunner.canResume`). Close the app halfway through and come back to
twelve un-analysed games and the button said "Review games", as though nothing
had been done — so the obvious conclusion was that resuming wasn't possible.
The label is derived from the actual work now: `Resume review (12)` when some of
the window is analysed and some isn't, `Review 20 games` on a first run,
`Check for new games` when caught up. Integration tests find it by
`Key('review-transport-button')`, not by label.

**"157 of 842 puzzles ready to play".** Both numbers true, neither answerable:
842 counts positions the filters have already ruled out, so the pair reads as
"685 puzzles are being kept from you" with no clue which or why. What you want
before pressing play is what is *in* the queue, by the only property that
matters — "Ready to play: 84 blunders, 51 mistakes". Types with none are
omitted, not shown as zeroes. The old `Expires: never · All mistake types`
summary line went with it; the Filters dialog is one click away and says it in
full.

**A caption under every control.** "Which games count as recent" defines a word
the user never used → "Games to download and review". "Applied to the next game
reviewed" (deleted; it lives in the Review-speed dialog, where it is actually
load-bearing), "Shared with the accounts card on the right — one window, both
halves of this screen" (deleted; an implementation note), "Unchecked speeds are
left out of the list entirely" (deleted; that is what a checkbox means). The one
hint kept is the auto-start warning, because that box spends minutes of CPU
without being asked again.

And the gear dialog stopped being a second copy of the screen: usernames and the
games window are permanently visible on the accounts card, so
`HomeReviewSettingsDialog` is down to the two things that *aren't* — time
controls and auto-start — and is titled for them ("Which games to review").
`HomeReviewSettingsResult` no longer carries a window.

## Revision, July 30 (evening): the count that never moved

**"12 games to analyse" → press play → "you're all caught up".** The bug behind
the loudest complaint. `_processGames` skips a game when
`TacticsDatabase.isGameAnalyzed(gameId)`, and *analyzed* only ever meant "its
puzzles were mined" — a game mined by an older build, or through the tactics
import panel, was never asked for the mistake counts the recent-games list
shows. So the list counted it as unreviewed forever, the engine pass walked
straight past it, and the button's number never moved however many times it was
pressed.

The pass now takes a `forceDedupKeys` set (through
`TacticsImportCoordinator.import` → `TacticsImportService.reviewFetchedGames` →
`_processGames`) naming games to analyse *regardless* of the analyzed flag.
`HomeReviewRunner._needsCountsFor` fills it with exactly the games the strip
counts: mine, in the window, no summary. Same identity on both sides —
`dedupKeyForHeaders`, which is what `GameReviewStore` files counts under — so
the set the button counts and the set the engine looks at cannot disagree.
Games that *do* have counts keep the ordinary skip, so a run still costs only
the work it needs.

**One gear, not two.** The strip had `Icons.tune` "Which games to review…" *and*
a "Review speed…" text button, which read as two unrelated features rather than
as this screen's settings. `ReviewSpeedDialog` is deleted; cores and depth are a
"How hard it works" section inside `HomeReviewSettingsDialog`, now titled
**Review settings** and opened from a single `Icons.settings` gear. The
engine-load row still *states* both numbers — that was the point of taking them
off the steppers — and its tooltip says where to change them. Field keys
(`review-cores-field`, `review-depth-field`) survive the move.

**No "Show all 20 games (15 more)".** The list showed five and hid the rest
behind a footer button. It is a scrolling list in a scrolling pane; showing what
fits and letting the scrollbar do the rest needs no control at all.
`initialGameCount`, `_showAllGames` and `_ListFooter` are gone.

**"Open on Chess.com" → "Open in Chess.com".** The button opens the game there.

## Revision, July 30 (night): three buttons that read as one menu

**"Resume review", "Study tactics", "Opening review".** Three controls on the
same strip, all a verb-plus-noun of the same length, two of them containing the
word *review*, and the only thing separating the one that spends ten minutes of
CPU from the two that open instantly was a fill colour. The fix is in the
vocabulary and in the grouping, not in more prose:

- **The job says "analysis", never "review".** `Resume engine analysis (12)`,
  `Start engine analysis (20)`, `Check for new games`. *Review* now names
  exactly one thing on this screen, and it is the button about openings. The
  strip's failure headline ("Analysis failed"), the engine-load row ("Analysis
  uses 4 of 8 CPU cores…"), the refresh tooltip and the gear (now **Analysis
  settings**, matching the dialog title) follow the same rule.
- **One column, one rule.** The engine job on top; a hairline `Divider`; then
  Study tactics and Opening review under it. Above the line, the thing that
  runs; below it, the two ways to spend what it produced. Opening review used
  to be a `TextButton` in the icon row on the far right of the strip, which is
  why it read as a footnote rather than as half of what this screen is for.
- **Two sizes, not three styles.** The job is filled, green, 15pt semibold with
  a 22px glyph. The two below share `_SecondaryButton`: outlined, 13.5pt, 18px
  glyph, identical to each other and distinguished only by icon
  (`Icons.extension` / `Icons.menu_book`) — peers, and visibly lighter than the
  thing above the rule.
- **All three carry their count.** `Opening review (4)` is the number of
  distinct leaks `aggregateOpeningReview` finds across the window (mistakes +
  book ends), recomputed per build so it fills in while the analysis runs. It
  stays *pressable* at zero, unlike Study tactics, because "no leaks" and "no
  book designated for these games" look identical from outside the dialog.

Button width went 210 → 250 so `Resume engine analysis (12)` fits without an
ellipsis. New keys for the tests: `study-tactics-button`,
`opening-review-button` (the transport button keeps
`review-transport-button` — integration tests find it by key precisely because
its label moves).
