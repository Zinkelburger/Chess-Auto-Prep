# Tactics

Status: draft from the old app
Old code (oracle only): `lib/features/tactics/`, `lib/features/games/`, `lib/screens/main_screen.dart`
Plan step: 9

> The book check, the opening review and the games list became their own mode on 2026-09-22:
> see [my-games.md](my-games.md).

## Purpose
Someone gives the app their Lichess or Chess.com username; it downloads their recent games, checks them
against their books and lets Stockfish grade every move they made. They leave with their own blunders as
a puzzle queue and each game one click from the viewer at the move that went wrong.

## Screen
Reached from the mode menu (`View ▾ ▸ Tactics`). Games list left, home column right; during a puzzle the
board replaces the list and the column becomes the puzzle panel. Blocks never collapse or reorder with
state. No screenshot.

- **Games header** — the username, ratings as labelled figures (`Blitz 2120`), the window (`last 20 games`)
  and a `Search games` box that narrows the loaded list only.
- **Game card** — the final position as an 18px-square board, both players with Elo, the opening, the first
  moves, the result. Three click targets, each opening the game at what was clicked: the card, the mistake
  counts (`1 blunder / 2 mistakes / 0 inaccuracies`, or `— — —` with `Not reviewed yet — press play to
  review your games`), and the book verdict (`In book · {line}`, `Different opening · {chapter}`, `You left
  book`, `Not in book`, `Book ends here`, `Checking your book…`, `No book set for this colour`).
- **Moments strip** — up to 4 small boards in move order: where the game left the book, then each of my
  mistakes, the played move as an arrow and the book's or engine's move beside it, titled with the numbered
  move (`23. Nxe5??`) over one line (`Blunder −3.2`, `You left book`). It scrolls sideways past four.
- **Play block** — `Play`, a `Filters…` button, the primary `Play tactics ({n})` button (48px, the one
  filled action on the screen), one status line, and `Browse all {n} →`.
- **Analysis block** — `Analysis`, a cores read-out (`6 cores`, tooltip `Stockfish runs on 6 of 16 cores at
  depth 15.`), a gear to shared engine settings, a transport button, headline, detail line and bar.
- **Openings block** — `Openings`, a headline, `Opening review ({n})` and a `Keeps happening` list of the
  most repeated deviations.
- **Accounts and books blocks** — the two usernames with `Save usernames` and `Last downloaded {date}` /
  `Not downloaded yet`, over the White and Black books with `Change…`. No password or login is asked for.
- **Puzzle panel** — `Puzzle` and `Game` tabs, only while a puzzle is up. Puzzle holds the mistake note, the
  played-moves trail for multi-move lines, a feedback line, an auto-advance toggle, and three buttons in
  fixed slots: `Show Solution`, `Analyze`, and a `Reset` icon disabled at the puzzle position. `Skip` reads
  `Next` once an attempt is scored; stars appear after solving. Game holds the source PGN and engine bar.
- **Browse panel** — every mined puzzle as rows over a filter bar; the count reads `{visible} / {total}
  tactics`. Empty: `No tactics to browse`, `Nothing matches the current filters`.
- **Session recap** — `Session complete` with `Solved` / `Failed` / `Skipped` figures, `Accuracy 78% · 4m
  12s total · avg 21s per puzzle`, then `Retry mistakes ({n})` and `Done`.
- **Board pane** — the shared board during a session, see `workspace.md`.

## Actions
**Set up accounts** — `Set up my accounts` or the Accounts block → usernames are saved and nothing
downloads while typing. The download needs no OAuth; a connected Lichess token is only attached as a
bearer header. Empty: `Add a username below`, `Set a username first`, `No accounts set`.
**Download and review** — the transport button (`Download and analyse` / `Check for new games` / `Analyse
{n} games` / `Resume analysis`), or automatically at launch when `Check for new games when the app starts`
is on → one pausable job in three stages: `Getting your recent games…`, `Checking your games against your
books…`, `Looking for your mistakes…`, then `Review complete`. The book check reads the last 200 games per
site, the engine pass only the review window; the engine evaluates each of my moves once at depth 15 on the
configured cores, counts the game's mistakes and mines the same numbers into puzzles — a move is `?!`, `?`
or `??` when it drops my winning chance by 0.1, 0.2 or 0.3. Failure: `Analysis failed`.
**Pause and resume** — the button reads `Pause` while running (`Stop after the game being analysed; press
again to carry on`) → `Pausing…`, then `Paused — {n} games left` and `Press Resume to carry on where it
stopped`. Nothing already analysed is repeated, and a game's puzzles are persisted before it is marked
done, so closing mid-batch never permanently skips it.
**Open a game or a moment** — the card opens the viewer on the game, the counts on its analysis tab, the
book verdict and a strip board on that moment's tab at its ply.
**Opening review** — `Opening review ({n})` → a dialog grouping every deviation by line, most repeated
first, in `Your mistakes ({n})`, `Not in your book ({n})` and `Your prep ran out ({n})`. Each entry shows
the place, the move number, `{n} games` and `Extend` / `Prepare` / `Fix`, which open the chapter in the
Builder. With no designated book, `No repertoire is designated for your games yet, so there is nothing to
compare them against.` with `Pick my repertoires`; with none found, `No deviations after entering your books
in your {window}. Games in a different opening are not counted as mistakes.`
**Start a set** — `Play tactics ({n})` → the filtered, ordered queue takes the board; it stays pressable
during a review and new puzzles arrive behind the solver. Disabled with `Nothing mined yet — analyse your
games first` or `Your filters rule out every puzzle you have; press Filters… to loosen them`; the status line
then reads `Nothing to play: your filters rule out every puzzle you have. Press Filters… to loosen them.` in
warning ink, otherwise `Ready to play: 84 blunders, 51 mistakes`.
**Solve** — play the stored answer → `Correct!`, or `Correct! (1/2)` part-way through a multi-move line, and
the opponent's reply plays on. With auto-advance the next puzzle loads 3 s later; completing the line
records the attempt, the time taken and the success against that puzzle.
**Wrong move** — `Incorrect`, the board snaps back to the puzzle position and the message stays up until
the next attempt; the attempt counts against the puzzle's success rate.
**Accept other winning moves** — off by default. On, a move that is not the stored answer stays on the
board and the panel reads `Checking…` with input locked while Stockfish scores the position at depth 14 on
one worker; within 50cp of the stored answer from the mover's side it passes with `Correct! {move} is just
as good` and finishes the puzzle on the played move. It answers no whenever it cannot ask (no engine, a build
holding the pool, an unparseable move) and drops a verdict arriving after a reset.
**Show solution (the hint)** — the button or Space → the numbered SAN line and a highlight; part-way
through a multi-move puzzle it navigates to the current position, not the end. The reveal is stored as a
hint on the puzzle and counted in the session. `No solution available` when the line is missing.
**Analyze, rate and skip** — `Analyze` opens the Game tab with the engine; 1–5 stars after solving or
revealing are stored, and 1 star drops the puzzle from the live queue at once; `Skip`/`Next` moves on;
`End session?` / `This ends the current training session.` ends it and shows the recap.
**Browse and filter** — `Browse all {n} →` → mistake-type chips (`??`, `?`, `?!`, custom), a status filter
`All` / `New` / `Struggling` (reviewed and under 50% success), a minimum-star popup (`Any star rating`,
`{n}★ and up`), searchable flaw-tag chips (`Any tags`), sort chips `Newest first` / `Oldest first` / `Worst
success` / `Least reviewed`, and a `Search by player, date or move` box. A multi-select mode adds
checkboxes, `Select All` and a batch `Delete {n} selected tactics?`; `Train these ({n})` plays what is shown.
**Edit or delete a tactic** — the row's menu: `Train this tactic`, `Edit tactic…`, `Analyze this position
in the game`, `Add game to study…`, `Copy FEN`, `Copy game PGN`, `Copy moves`, `Delete tactic`. The editor
takes `FEN (position to solve)`, `Move you played (UCI or SAN, may be empty)`, `Correct line (moves separated
by |)`, `Solution display line (optional, separated by |)`, `Analysis / note (shown after solving)` and flaw
tags, refusing with `FEN cannot be blank`, `Not a legal FEN position`, `Need at least one solution move`,
`Illegal move "{token}"`. `Delete all…` also clears imported PGNs and the analyzed-games history.
**Filters dialog** — `Filters…` opens Settings on the Tactics chapter: `Puzzle order` (`Newest first`,
`Least reviewed`, `Worst success rate`, `Random`), `Group by game` (on), mistake types to include
(`Blunders (??)`, `Mistakes (?)`, `Inaccuracies (?!)` — off by default — and `Custom puzzles`), the
practice-queue toggles `Unreviewed only`, `Hide one-star puzzles` (on) and `Accept other winning moves`
(`Stockfish checks alternative answers.`), and `Include puzzles from the last {14} days` with `Include all
dates` (`Counted from the game date.`). These save immediately. Below them, `Game downloads` — `Games to
analyse` (last 20 games or last 2 days), `Time controls`, `Games per site to check against my repertoires`
(200) and the startup check — apply together with `Save download settings` and reset the run (`Review
settings saved.` / `Could not save review settings. Please try again.`).
**Display settings** — board coordinates, legal-move hints and piece notation are the shared `Board & moves`
preferences and apply to every board in the app; this mode adds only `Auto-advance to next position` and
`Longer engine line shown with the solution`.
**Keyboard** — Space show/hide solution, ←/→ a move, ↑/↓ previous/next position, and a key each for `Toggle
auto-advance`, `Analyze (open PGN)`, `Toggle engine`, `Flip board` and `Focus move input`; Tab switches
Puzzle/Game, Escape leaves editor, then tab, then puzzle. A SAN or UCI letter focuses the move box.

## Data
- Puzzles are one multi-game PGN, `Documents/tactics_sets/Default.pgn`, one game per puzzle: `[FEN]` and
  `[SetUp "1"]`, the trainable line as the mainline, the mistake note as a comment, and headers for
  `GameId`, `UserMove`, `MistakeType`, `OpponentBestResponse`, `ReviewCount`, `SuccessCount`,
  `LastReviewed`, `TimeToSolve`, `HintsUsed`, `StarRating`, `FlawTags`, `SolutionPv` and `SourceMovetext`. A
  puzzle is identified by its FEN and all of that must survive a round trip. Legacy CSV sets convert on first
  load; a decode that would lose records refuses to save: `{n} invalid tactics records; refusing a lossy save.`
- An external PGN (a study chapter) opens as a temporary set for flashcard review, stats written back into
  its own headers; mining into it is refused (`This is a study under review — edit its content in Study mode.`).
- Downloaded games are a per-(site, username) PGN cache under the games-library directory with a
  `.fetched` sidecar, a 12-hour TTL and 1000 games per player, re-read by the PGN Viewer and Player
  analysis. Lichess is one export request with clocks (default last 20 games, or a `since` window);
  Chess.com walks its monthly archives newest-first (default last 10 games, 200-game cap on a dated
  import). The Lichess client backs off on 429 for 60 s, 120 s then 240 s, retrying transport errors
  after 2 s. A download that does not happen — no connection, a 429 that never clears, an outage —
  is answered from that cache however stale, including under a forced check for new games, and the
  header says which site could not be reached; only an account with nothing cached shows an error
  instead of games. See [Network and offline](../../ARCHITECTURE_RENEWAL.md#network-and-offline).
- `app_games.db` under app support holds the parsed rows: collection, a canonical game key, players, result,
  date, speed, Elos, ECO, the full headers, the verbatim PGN and when it was imported; a positions table maps
  each position to game and ply, a collections table records freshness, and a trash table keeps deleted games'
  PGN. `[%eval]` annotations from the review go back into the cached PGN, so the viewer's graph and this mode
  read the same evals. An analyzed-game id list stops a game being mined twice; session preferences, the games
  window, the startup check and the last fetch per site live in preferences.

## Keep / Change / Drop
Keep — Games header
Keep — Game card
Keep — Moments strip
Keep — Play block
Keep — Analysis block
Keep — Openings block
Keep — Accounts and books blocks
Keep — Puzzle panel
Keep — Browse panel
Keep — Session recap
Keep — Board pane
Keep — Set up accounts
Keep — Download and review
Keep — Pause and resume
Keep — Open a game or a moment
Keep — Opening review
Keep — Start a set
Keep — Solve
Keep — Wrong move
Keep — Accept other winning moves
Keep — Show solution (the hint)
Keep — Analyze, rate and skip
Keep — Browse and filter
Keep — Edit or delete a tactic
Keep — Filters dialog
Keep — Display settings
Keep — Keyboard

Quirks to rule on: the mode is called Tactics but the left pane is really "my games", and the list, the
opening review and the puzzle queue are three jobs on one screen; the puzzle filters live in app Settings,
not on the screen showing the count they change; puzzles auto-expire 14 days after the game date while the
browse list still shows all of them; a 1-star rating is a hide, not a rating; session order and browse sort
are separate settings with the same four choices.

## Questions for the owner
- Should "my games" (cards, moments, opening review) be its own mode, leaving Tactics as the queue?
- Is the puzzle store still a PGN file, or does it move into `app_games.db` beside the games?
- Should "Accept other winning moves" be the default, given every puzzle stores exactly one answer?
- Do stars stay 1–5 with 1 meaning "hide", or does hiding become its own action?
- Are flaw tags (impact / opportunity / phase / tempo) worth carrying, given nothing else reads them?
- Does the 14-day expiry survive, and should the browse list respect it?
