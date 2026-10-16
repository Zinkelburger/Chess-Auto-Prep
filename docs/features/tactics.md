# Tactics

A player gives the app their Lichess and/or Chess.com username; it downloads
their recent games, lets Stockfish judge every move they made and turns their
mistakes into puzzles. They leave having replayed their own blunders, each one
a click from the game it came from. Comparing those games with their
repertoires is [My games](my-games.md).

Code: `lib/features/tactics/` (`TacticsPanel`, `PuzzlePane`, `SourceGamePane`,
`MyGamesBlock`; owners `TacticsSet`, `PuzzleTrainer`, `MyGames`,
`SetAdditions`, `SourceGames`), composed by `TacticsView` in
`lib/app/training_views.dart` and wired in `lib/app/mode_wiring.dart`. Pure
parts in `lib/chess/tactics/`; downloads in `lib/net/recent_games.dart`; the
games cache and usernames in `lib/storage/my_games_files.dart` and
`lib/storage/my_accounts.dart`; the alternative-answer check in
`lib/engines/alternative_answer.dart`.

## Screen

Reached from the mode menu (`Tactics`, before `My games`). The shared
workspace: puzzle column left, board middle, reading card right. The mode
starts with the engine off, no card heading and no game counter.

- **Accounts block** (top of the column, shared with My games) — with no
  username: `Add your Lichess or Chess.com username to turn your mistakes into
  puzzles.` and `Add accounts`. Otherwise each username (tooltip `Lichess
  username` / `Chess.com username`) with `Change`, `Bullet` / `Blitz` /
  `Rapid` / `Classical` chips, the transport button (`Get games` / `Pause` /
  `Resume`) and one status line.
- **Play** — `Play ({n})`, `Continue session` while a sitting is parked, or
  `Show puzzle` while one is up. The only filled button in the column once
  the set has puzzles; the accounts buttons are outlined then.
- **Count line** — `{queued} of {total}`, the kinds it holds (`14 blunders,
  12 mistakes`, or `none`), and a `Filters` fold beside it.
- **Filters** (inline, saved at once) — kind chips `Blunders ??`, `Mistakes
  ?`, `Inaccuracies ?!`, `Custom`; `Order`: `Newest first`, `Least reviewed`,
  `Worst success rate`, `Random`; `Group by game`, `Unreviewed only`, `Hide
  one-star`; `Last [n] days` (tooltip `Counted from the date the game was
  played.`).
- **Search** box, then the rows: the move (`23... Nxe5??`) with the record
  (`2/3`, tooltip `Solved 2 of 3 tries`; blank for a new puzzle, or
  `solved`/`failed` in the current sitting) over `date · vs opponent`; a `⋯`
  menu (`Puzzle actions`). The puzzle on the board is highlighted.
- **Column messages** — `Reading puzzles…`; `No puzzles yet. Get your games
  above: …`; `The puzzle set could not be read: {detail}` with `Try again`;
  `No puzzles from the last {n} days.` with `Include older puzzles`; `Your
  filters rule out every puzzle you have. Open Filters to loosen them.`;
  `Nothing matches "{q}".`
- **Card tabs** — `Puzzle` (pinned), `Game` (open by default), and `Moves`,
  `Explorer` when opened. No repertoire tabs.
- **Puzzle tab, idle** — `Practice your mistakes` with `{n} puzzles ready…`,
  or `Session paused` with `End session`.
- **Puzzle tab, solving** — `White to play` (`· 2 moves` for a longer line),
  `vs opponent · date`, `You played h5 (inaccuracy)` (after the answer:
  `, allowing Be2   +0.6 → -0.1`), a fixed-height feedback line, the buttons
  (`Show solution` → `Analyze` once finished; a reset icon `Try it again from
  the start`; `Skip` → filled `Next` once scored), `Rate` with five stars after
  finishing, then `‹ Puzzle 3 of 26 · 2 solved · 1 failed` with `End session`,
  and `Go to the next puzzle after a solve`. Nothing moves as feedback changes.
- **Recap** — `Session complete`, `Solved` / `Failed` / `Skipped` figures,
  `Accuracy 78% · 4m 12s total · avg 21s per puzzle`, `Retry mistakes ({n})`
  (filled) and `Done`.
- **Game tab** — the source game: `White (Elo) – Black (Elo)`, result and date,
  the review's counts for that game, then the moves as the reading card sets
  them with the puzzle's move bold and marked, scrolled into view; `Analyze
  game`. `Play a puzzle to see its game.` / `This puzzle has no game.`

## Actions

**Add / change accounts** — `Add accounts`, `Change` or Actions `My accounts…`
→ dialog `My accounts` with `Lichess username`, `Chess.com username` and
`Only your username: your games are public. Leave one blank if you do not play
there.` → `Save` stores them; nothing downloads. A changed or cleared name
drops games a paused review left queued. Failure: `Your account names could
not be saved.` (the names are still used).

**Time-control chips** — at least one stays on; locked while a review runs →
saved in settings (`myGameSpeeds`), drops the paused queue. A game with no
readable `TimeControl` always passes; daily/correspondence counts as
`Classical`.

**Get games** — the transport button or Actions `Get my games` → one pausable
job per press. For each account: download (200 games while fewer than 200 are
saved, else 20), save into the games cache, then take the newest 20 saved
games of the chosen speeds that no review has done. Each is judged by a
Stockfish of its own (the board engine's threads and hash) at depth 15. A
move is `?!`, `?` or `??` when it drops the mover's Lichess-style winning
chance by 0.1, 0.2 or 0.3; each becomes a puzzle from the position before it,
the engine's line as the answer. Status lines: `Getting your recent games…`,
`Looking for your mistakes… 3 of 20`, `Review complete · 4 new puzzles`.
Failures: `Set a username first.`; `Analysis failed: {detail}.`; `Analysis
failed: the tactics set could not be read.`; per site `Could not reach
{site}, and no games are saved.`, `{site} is limiting requests; try again in
a few minutes.`, `{site} has no player by that username.`, `{site} could not
answer (HTTP {n}).` A site that cannot be reached is answered from its saved
games: `· Lichess not reached, using saved games`.

**Pause / Resume** — `Pause` (Actions `Pause the review`) → `Pausing…`, stops
after the game being judged → `Paused — {n} games left`; `Resume` carries on
without downloading again. A game's puzzles, its done mark and its counts are
one write, so a game cut off midway is judged again and none is mined twice.

**Play** — `Play`, or a row → the Puzzle tab comes up and the queue (exactly
the filtered, searched list, in its order) starts, from the clicked row when
one was clicked. A parked sitting continues instead of restarting.

**Solve** — play on the board. The right move: `Correct! (1/2)` and the
opponent's reply follows after 600 ms; the last one: `Correct!`. A wrong move:
`Incorrect — {san} is not it.`, the board stays at the puzzle. Only the first
attempt at a puzzle in a sitting is recorded (`ReviewCount`, `SuccessCount`,
`LastReviewed`, `TimeToSolve` in its headers); a later solve reads `Solved,
after a wrong try.` With auto-advance on (default) the next puzzle comes 3 s
after a solve. A write that fails shows `Not saved: {reason}`.

**Accept other winning moves** — Settings → Tactics, off by default. On, a
move that is not the stored answer reads `Checking…` with input locked; a
private Stockfish (1 core, 64 MiB) scores both resulting positions at depth 14
within 30 s. At most 50 cp worse passes: `Correct! {san} is just as good.` The
stored answer is not changed; `Analyze` shows the accepted move as a
temporary line. No verdict (timeout, no engine, cancelled) reads `Not checked
— {reason}` and grades nothing. Reset, navigation, leaving the mode or
closing cancels the check.

**Show solution** — the button, Space or Actions → `Solution: {moves}` and the
board steps to the next answer move. Nothing is written; the puzzle counts as
skipped in the sitting.

**Reset / Next / Previous / End** — reset icon (an attempt already made
stands); `Skip`/`Next` or ↓; ↑ or `‹` goes back; `End session` or Esc ends
the sitting and shows the recap. Leaving the mode parks the sitting with its
results; `Continue session` (column or Actions) resumes it.

**Rate** — 1–5 stars after finishing, written as `StarRating`; clicking the
current star clears it. One star means `hidden from training` (with `Hide
one-star` on); the sitting under way is not changed.

**Analyze** — after finishing, `Analyze` opens the `Moves` tab with the engine
on. The engine cannot be switched on while the answer is hidden.

**Game tab moves** — clicking a move or `Analyze game` opens the source game on
a new analysis board at that ply with the engine on.

**Row menu** — `Analyze in the game` (the source game, or the puzzle alone, on
an analysis board at the puzzle), `Copy FEN`, `Copy game PGN` (the saved game,
else the puzzle's own text), `Add game to study…` (shared study picker; also
in Actions for the puzzle up), `Delete puzzle…` → `Delete this puzzle?` /
`{label} goes, with its review history.` The replaced file version is kept
with the backups and the game stays reviewed. Failure: `Could not delete the
puzzle: {reason}` (e.g. `The puzzles changed on disk. Try again.`).

**Keys** — Space show solution, ↓/↑ next/previous puzzle, Esc end sitting,
F flip, E engine (only once the answer is shown). Actions also has `Copy FEN`
and the card's tabs.

## Data

- **Puzzle set** `Documents/tactics_sets/Default.pgn`, one game per puzzle:
  `Event`, `White`, `Black`, `Date`, `Result "*"`, `FEN`, `SetUp "1"`,
  `GameId`, `UserMove`, `MistakeType` (`??`/`?`/`?!`; anything else is
  custom), `OpponentBestResponse`, `SolutionPv`, `SourceMovetext`; the
  trainable line is the mainline, the eval note a comment. Attempts add
  `ReviewCount`, `SuccessCount`, `LastReviewed`, `TimeToSolve`, `StarRating`.
  `HintsUsed`, `FlawTags`, `CorrectLine` are kept in place but not written or
  read. A puzzle is identified by its FEN; mining skips FENs already present.
  Every header and comment must survive a round trip; edits touch only the
  puzzle's own game.
- **Heading lines** at the top of the set: `; ChessAutoPrep-Analyzed-v1: `
  (base64url JSON list of reviewed game ids; always the first line; an
  unreadable one blocks mining) and `; ChessAutoPrep-Mistakes-v1: ` (base64url
  JSON, game id → `[blunders, mistakes, inaccuracies]`; unreadable means no
  counts). Written in the same save as the game's puzzles. Ids in
  `Documents/analyzed_games.txt` also count as done (read only).
- **One writer**: while the set is the workspace document the session saves
  it; otherwise `TacticsSet`/`SetAdditions` write against the revision read
  and retry a lost race up to 3 times.
- **Games cache** `Documents/games_library/{site}_{username}.pgn` (`lichess_`,
  `chesscom_`) with a `.fetched` note (ms since epoch). Downloads merge
  without duplicates; appending new games keeps no version copy. Read by My
  games, the explorer's `My games` source and Player analysis. Lichess: one
  streamed export, standard chess, no clocks, a connected token sent as a
  bearer header and dropped if refused; 429 waits 60 s, 120 s, 240 s, then
  gives up; transport errors retry after 2 s. Chess.com: monthly archives
  newest first.
- **Settings**: `puzzles` (the filter; `days` null means every date, the
  default), `autoAdvance` (on), `acceptAlternativeAnswers` (off),
  `myGameSpeeds` (all four). Usernames and last-download dates are the shared
  preferences `lichess_username` / `chesscom_username`.
- Network and offline rules: [Architecture](../ARCHITECTURE.md).

## Owner decisions

- 2026-09-22: Tactics is "set up my accounts & play tactics" in the shared
  three-pane workspace; no repertoire-builder options, no extra views. Analyze
  opens a tab with the engine, never another mode.
- 2026-09-22: the book check, opening review and games list belong to
  [My games](my-games.md), not here.
- 2026-09-27: accepting other winning moves is opt-in; the stored answer is
  never changed by it, and an unchecked answer is never graded wrong.
- 2026-10-01: one filled button at a time — `Play` in the column, `Next` on
  the Puzzle tab; filters fold open inline under the count they change, not in
  a dialog.
- Usernames only: no password, OAuth or login to fetch games.

## Not built

- Checking for new games at launch: nothing in `MyGames` or `TacticsView`
  starts a download unprompted.
- Editing a puzzle, making a custom one, or multi-select / bulk delete: the
  row menu in `TacticsPanel._menu` has only the five entries above.
- Writing `HintsUsed` on a reveal (`PuzzleTrainer.showSolution` writes
  nothing); flaw tags are neither mined nor shown.
