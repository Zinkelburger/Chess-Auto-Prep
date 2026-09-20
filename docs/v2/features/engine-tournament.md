# Engine tournament

Status: draft from the old app
Old code (oracle only): `lib/features/engine_tournament/`, `lib/widgets/crosstable_view.dart`,
`lib/widgets/match_games_table.dart`
Plan step: 12

## Purpose
Someone wants a position or a build settled by engines rather than by opinion: they register a UCI
binary, put two of them (or a field) on a start position with a clock, and let it run. They leave
with a crosstable, a score they can quote, and a plain PGN of every game.

## Screen
Reached from the mode switcher (`Lab` group → `Engine tournament`), from a breadcrumb back into a
named tournament, and from an agent's open request written while the app was closed or running.
No screenshot.

- **Title bar** — breadcrumb trail, an overflow menu (`Tournament ▸ New tournament`, `Refresh`,
  both disabled while a match runs), the mode switcher, and a settings gear that opens the engine
  manager inline.
- **Tabs** — `Results` and `Engine controls`. The second tab holds the same setup panel as the new
  tournament dialog, headed `Configure next run` with a `Start new run` button.
- **History rail** (left, 3:7 split) — `History` with the run count and a `+` (`New tournament`).
  A filter box `Filter by name, engine or opening` appears at 6 runs or more and matches name,
  opening label and engine names; no match reads `No tournament matches "…".`
- **History row** — name, status word (`Not started`, `Running`, `Completed`, `Stopped`, `Failed`;
  only `Failed` is coloured), `Alpha vs Beta`, the score line (`Alpha 5½–4½ Beta`, `Alpha leads on
  7/12`, `Alpha, Beta tied on 6/12`, `won with` once finished), then `4/10 games · 2.0s/move ·
  14:32 · 3m`. Rows are grouped under `TODAY`, `YESTERDAY` or `SEPTEMBER 2026`, newest first, and
  a running row carries a 3px progress bar.
- **Empty state** — a start-position board, `No tournaments yet`, `Put two engines in a position
  and let them settle it. Games are saved as ordinary PGN, so the whole match opens in the PGN
  Viewer when it is done.`, and `New tournament`.
- **Detail header** — a 92px thumbnail of the start position (click copies the FEN), the name and
  status, meta chips (time control, `4/10 games`, format when there are more than two engines,
  `3 at once` when concurrent, `Standard start` / the opening label / `From position`, and
  `Adjudicated` whose tooltip spells the rules out), then `Edit & run again` (or `Stop` while
  running), `Browse games`, `Delete`, and the full `games.pgn` path in small type.
- **Now playing** (while running) — a 160px board, `Game 3 of 10 — Stockfish #1 vs Stockfish #2`,
  `+1 more running alongside this one` when concurrent, the last move as `14... Nf6  +0.31/24`,
  `Copy FEN`, and the progress bar. Before the first move: `Starting…` / `Waiting for the first
  move…`.
- **Error banner** — selectable text carrying whatever the run failed with.
- **Crosstable** — a `Show rating statistics` checkbox, then `#`, `Engine`, `Score`, `W`, `D`, `L`,
  optionally `Draw %`, `Elo ±`, `LOS`, `SB` (each with an explaining tooltip), then one `vs <name>`
  column per opponent showing `6/10` over `4 W · 4 D · 2 L`. Empty: `No games yet — the crosstable
  fills in as they finish.`
- **Games table** — a persisted `Show final positions` checkbox, then `Final position`, `Game`,
  `Rd`, `White`, `Black`, `Result`, `Ended`, `Moves`, `Time`. The winner's name is highlighted, and
  an ending that was not the game's own (adjudication, forfeit, crash) is written in warning colour.
  `Open in PGN Viewer` sits in the panel header. Empty: `No games played yet.`
- **Engine manager** — `Engines`, `The bundled Stockfish is what the rest of the app uses. Anything
  you add here competes in tournaments only.`, one row per engine (name; path or `Bundled with the
  app` · `128 MB` · `1 CPU core`) with `Test engine`, `Edit`, `Remove`, then `Add UCI engine…` and
  the last report sentence. The bundled entry has no `Remove`.
- **New tournament dialog** — the start-position board (click to edit), `Name`, `Start position`
  (`Standard start — paste a FEN to change`), `Edit board…` / `Use the board position`, `Games`,
  `Time` presets, and an `Engine controls` disclosure holding `Engines`, `Time control`, `Games`
  and `Adjudication`. The footer reads `Stockfish #1 vs Stockfish #2 · 10 games · 2.0s/move ·
  ≈ 5 min` and offers `Cancel` / `Start`.

## Actions
**Add an engine binary** — `Add UCI engine…` picks any file, which is then started and made to
answer `uci` → `uciok`, `isready` → `readyok`, and play a *legal* move from the standard position
before it joins the list. It is named after the engine's own `id name`, else the file name. The
report reads `Engine added: Verified — answered "uci", "isready", and played a legal move.` or
`Could not add engine:` plus one of `No such file.`, `That is a folder, not an engine binary.`,
`The file is not executable. Run \`chmod +x\` on it and try again.`, `It started, but never
answered "uci" with "uciok" — so it is not a UCI engine.`, `"<name>" did not answer "isready".`,
`"<name>" never produced a move from the starting position.`, or `"<name>" answered "e2e5" from
the starting position, which is not a legal move. It speaks UCI but is not playing chess.` The
first 40 lines the process printed are kept with the failure. Handshake waits 15 s, the move 20 s.
**Test engine** — re-runs that check on an engine already listed, reporting `<name>: <sentence>`.
**Edit an engine** — an inline form: `Name` (`How it appears in the crosstable and the PGN.`),
`Memory (MB)`, `CPU cores`, `Think during opponent's turn` (off), and `Extra UCI options`
(`One per line, as Name=Value.`). Refused with `Enter memory from 1–65536 MB and CPU cores from
1–1024.` or `Enter each extra option as Name=Value.`; a failed write says `Could not save engine
settings. Try again.` The bundled engine stores only its settings — its path is resolved at launch.
**Remove an engine** — asks `Remove <name>?` / `The binary stays where it is — this only takes it
off the list.`
**Set up a run** — name (default `Engine match`), a start FEN typed, pasted, taken from the app's
board or drawn in the board editor (`Use this position`); a bad FEN shows `Could not read that
FEN.` or `That FEN parses but is not a legal position (…).` and greys the preview. `Games` per
pairing (10, 1–1000). Time presets: `1 s / move`, `2 s / move (default)`, `5 s / move`,
`Bullet — 10 s + 0.1 s`, `Blitz — 60 s + 0.6 s`, `Rapid — 300 s + 3 s`, `Classical — 40/600 s +
10 s`, `Fixed depth 12`, `Fixed 1M nodes`, each openable into its own numbers (`Moves/session`
`0 = sudden death`). Participants: at least two, the same binary may appear twice (repeats become
`Stockfish #1`/`#2`), each with its own cores and memory; three or more offer `Round robin` /
`Gauntlet`. `Games at once` (default 1, `One is fairest`, capped at the machine's logical cores),
an `Opening label` written to the PGN `Opening` tag, `Alternate colours` (on), and `Annotate every
move with the engine's eval` (off — `Writes {+0.31/24 2.001s} after each move`). Adjudication,
cutechess-shaped: `Call level games a draw` (on; from move 40, for 8 moves, within 10 cp),
`Resign lost games` (on; 4 moves below 900 cp, `Both agree`), and `Stop after N moves` (300,
`Filed as a draw.`). Blocked with `Pick at least two engines.` or `Wait for the current tournament
to finish before starting another.`
**Start** — `Start` creates `Documents/engine_tournaments/<slug>/` (suffixed `-2`, `-3` on a name
clash), plays the schedule round-major so a half-finished match is still balanced, and saves after
every single game. It ends with `<name>: 10 games played.`, `<name> stopped after 6 games.`, or
`<name> failed: <error>`; `Could not create the tournament: <error>` when the directory cannot be
made, and `A tournament needs at least two engines.` / `The schedule is empty — nothing to play.`
from the runner itself.
**Stop** — `Stop` shows `Stopping…` and lets the games in flight finish their current move; the
run is filed as `Stopped` with everything played so far intact.
**Watch a live game** — the running game's board, move and score update as the engines move. With
several games at once only the oldest-started one is on the board and the rest run quietly.
**How a game ends** — checkmate, stalemate, insufficient material, fifty-move rule or threefold
repetition; or `Adjudicated draw`, `Adjudicated win`, `Move limit`; or a loss by `Time forfeit`
(`Alpha used 3.2s with 0.4s left`), `Illegal move` (`Alpha played "e2e5" in <fen>`) or `Engine
failure` (the engine's own message). Each reason is the game's first PGN comment and its
`Termination` tag. A hung engine is cut off at 175% of its nominal think time plus 2 s.
**Open a finished game** — a row in the games table, `Browse games` or `Open in PGN Viewer` hands
`games.pgn` to the PGN Viewer, parked on that game number, so its Prev/Next walks the whole match.
**Edit & run again** — reopens the setup with the finished tournament's config, as a new run.
**Delete** — asks `Delete "<name>"?` / `The games and crosstable will be moved together to Chess
Auto Prep recovery trash.`; refused while that tournament is running.
**See outside work** — the tournaments directory is watched, so a match started by an agent or a
second window fills in without pressing `Refresh` (one reload per 600 ms). Where the directory
cannot be watched, `Refresh` is the only route.
**Open request from an agent** — a request file naming a tournament selects it on the next launch
or immediately if the app is open; it is read and cleared in one step, and ignored after 24 hours.
An unknown id says `No tournament called "<id>" under Documents/engine_tournaments.`

## Data
- `Documents/engine_tournaments/<slug>/tournament.json` — config snapshot (engines *copied*, not
  referenced, so renaming an engine never rewrites an old crosstable), status, and one record per
  game (round, seats, result, termination, detail, plies, start time, duration). Must survive a
  round trip; a corrupt file hides one tournament, not the list.
- `Documents/engine_tournaments/<slug>/games.pgn` — every game in schedule order, rewritten whole
  after each result so a row's game number is its number in the viewer. Headers: Event, Site, Date,
  Round, White, Black, Result, Opening, TimeControl, Termination, PlyCount, WhiteType/BlackType
  `program`, GameStartTime, GameDuration, plus FEN/SetUp off the standard start.
- `Documents/engine_tournaments/engines.json` — the registry. The bundled Stockfish is always first
  and its path is never stored; its settings are. Deleted tournaments go to `.trash/` beside them.
- `Documents/engine_tournaments/open_request.json` — the cross-process "open the app on this
  tournament" file, written by the MCP tools and consumed by the app.
- The PGN Viewer opens `games.pgn` as an ordinary collection; the headless runner and the MCP
  tools write the same tree through the same code. Final positions shown is a shared preference.

## Keep / Change / Drop
Keep — Title bar
Keep — Tabs
Keep — History rail
Keep — History row
Keep — Empty state
Keep — Detail header
Keep — Now playing
Keep — Error banner
Keep — Crosstable
Keep — Games table
Keep — Engine manager
Keep — New tournament dialog
Keep — Add an engine binary
Keep — Test engine
Keep — Edit an engine
Keep — Remove an engine
Keep — Set up a run
Keep — Start
Keep — Stop
Keep — Watch a live game
Keep — How a game ends
Keep — Open a finished game
Keep — Edit & run again
Keep — Delete
Keep — See outside work
Keep — Open request from an agent

Quirks to rule on: the same setup panel exists twice, as the `Engine controls` tab and as the new
tournament dialog, with different button wording; a running match blocks `New tournament` and
`Refresh` outright rather than queueing; only one game is ever on the live board however many run
at once; a match interrupted by a crash or a quit is read back as `Stopped`; the games PGN is
rewritten whole after every game; the start position is a single FEN, so there is no opening book.

## Questions for the owner
- Should a field larger than two engines keep both `Round robin` and `Gauntlet`, given that almost
  every run is a two-engine match?
- Are `Elo ±`, `LOS` and `SB` worth a checkbox, or should they always be visible?
- Should a stopped or crashed run be resumable from where it left off, instead of only re-run?
- Should engines registered here be usable elsewhere in the app (analysis, review), or stay
  tournament-only?
