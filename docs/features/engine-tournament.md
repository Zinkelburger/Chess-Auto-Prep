# Engine tournament

Settles a position or an engine question by letting UCI engines play it out.
The user registers engine binaries, starts a run from a FEN with a time control
and a schedule, and leaves with a crosstable and an ordinary `games.pgn` that
opens in the PGN Viewer. Runs started headlessly or by an agent land in the
same folder and appear here.

Code: `lib/features/tournaments/` (screen, history, standings table, setup and
engine dialogs, `TournamentRun` owner, `TournamentGameRunner`, schedule, engine
check), plus `lib/chess/tournament/` (config, presets, schedule, results,
standings), `lib/storage/tournaments.dart` (`FileTournaments`),
`lib/storage/tournament_inbox.dart` (folder watch, open requests),
`lib/engines/tournament_launch.dart`, `lib/workspace/engine_jobs.dart`,
`lib/app/tournament_view.dart`. Headless: `tools/run_engine_tournament.dart`;
agent tools: `tools/mcp/chess_prep/engine_tournament.py`. Both run the same
Dart code; see [Engine tournaments](../ENGINE_TOURNAMENT.md).

## Screen

Reached from the mode menu (`Data & engines` → `Engine tournament`), from the
running-task button while a tournament holds the engine job, and from an open
request. Without tournament storage the screen reads `Tournament storage is
unavailable.`

- **Top row**: `Engine tournament`, `New tournament` (filled), `Engines`, a
  refresh icon (`Refresh tournaments`), and while a run plays `Stop` (`Stopping
  after this move…` once pressed). After a failed save, `Retry save`.
  `New tournament` is disabled while a run plays or a save waits for retry.
- **Problem line**: selectable error text for the last failure, then one line
  per unreadable tournament (`Cannot read tournament <id>: …`).
- **History** (left, 280 px): a search box (`Name, engine or opening`) that
  matches name, opening label and engine names; no match reads `No tournament
  matches "<query>".` Rows are newest first under `Today`, `Yesterday`, a
  month (`September 2026`) or `Unknown date`. Each row: name, `<status> ·
  4/10 games`, then each engine's points (`Stockfish A 5.5 · Stockfish B
  4.5`). A `running` row has a progress bar. Status is the stored word:
  `pending`, `running`, `completed`, `stopped`.
- **Detail** (right): `No tournaments yet` when nothing is selected. Otherwise
  the name with `Run again` and a trash icon (`Move tournament to trash`),
  `<status> · 4/10 games`, the time label and format label (`Blitz · 60 s +
  0.6 s`, `Round robin · 10 games per pairing`), and any stored error.
- **Live game** (selected tournament running): `Game 3 · 41 plies · Nf6` above
  a 280 px board. With several games at once it shows whichever moved last.
- **Crosstable**: `Show rating statistics` checkbox; columns `#`, `Engine`,
  `Score`, `W`, `D`, `L`, optionally `Draw %`, `Elo ±`, `LOS`, `SB` (each with
  an explaining tooltip), then one `vs <name>` column per entrant showing the
  score over `4 W · 4 D · 2 L`. Before any result: `No games yet — the
  crosstable fills in as they finish.` Only finished games count.
- **Below the crosstable**: `Show final positions` (a saved setting), `Browse
  games`, and the full `games.pgn` path in small type.
- **Games list**: one row per saved game, `3. Stockfish A — Stockfish B`,
  then `1-0 · Checkmate` (plus any detail). With final positions on, each row
  has a 92 px board of the game's last main-line position; a game whose PGN
  does not replay cleanly gets none.

## Actions

**Register an engine** — `Engines` → `Tournament engines` dialog: a fixed
`Bundled Stockfish` entry (`Always available; add named settings below.`), one
row per registered engine (`<cores> cores · <MB> MB · <path or Bundled
Stockfish>`) with edit and remove icons, `Add UCI engine…`, `Close`. Add and
edit open an editor: `Name`, `Executable path (empty = bundled Stockfish)` with
`Choose file…`, `Cores` (1–1024), `Hash (MB)` (1–65536), `Arguments (one per
line)`, `UCI options (name=value, one per line)`, then `Test and save`
(`Testing…`). A new engine's name follows the picked file's name, then the
engine's own `id name` once tested, until the user types one. Refusals: `Write
each UCI option as name=value.`, `Name the engine.`, `Engine options must be
single lines.`
**Engine test** — every save first starts the engine and asks for one move
from the start position (depth 1, 20 s deadline). Passing reads `<name>: UCI
ready; legal move verified.` Failing shows the start failure, `<name> played an
illegal move: <uci>`, `<name> crashed while searching`, or `<name> sent no
bestmove within 20 s`, above the first 40 lines the process printed. Edits are
refused while a run plays (`Wait for the tournament to finish.`).
**Remove an engine** — confirm `Remove <name> from the registry? Saved runs
retain their engine settings.`
**Set up a run** — `New tournament` (or `Run again`, titled `Configure next
run` and prefilled from that run) opens one dialog: `Name`; `Engines` (two
seats default, `Stockfish A` and `Stockfish B`; each a typeable choice of the
bundled Stockfish and the registry; `Add engine`; remove disabled at two);
`Starting FEN` beside a preview board greyed while illegal (`Use a legal
starting FEN.`), with `Start position`, `Current board` (the workspace board)
and `Edit position…` (the shared board editor); `Format` (`Round robin` /
`Gauntlet`); `Games per pairing` (10, 1–1000); `Simultaneous games` (1, 1–64);
`Alternate colors` (on); time presets `1 s / move`, `2 s / move`, `5 s / move`,
`Bullet`, `Blitz`, `Rapid`, `Classical`, `Depth 12`, `1M nodes`, a preset lit
while the fields still match it; `Time control` (`Time per move`, `Clock +
increment`, `Fixed depth`, `Fixed nodes`) with its own number fields; `Annotate
evaluations` (off); an `Adjudication` fold. Footer `Cancel` / `Start new run`.
**Validation** — `Name the tournament.`, `Pick 2–32 engines.`, `Use 1–1000
games per pairing.`, `Limit a run to 100000 games.`, `Use 1–64 simultaneous
games.`, `Use 1–10000 moves per game.`, `Use 1–1024 cores and 1–65536 MB per
engine.`, `Choose a supported time control.`, `Time and search limits must be
positive.`, `Use a legal starting FEN.`
**Start** — takes the machine's one engine job; if a search, audit, review or
solitaire holds it, the problem line says `<job> is running. Use the
running-task button at the top to return to it.` Creates the tournament
folder, then plays the schedule round-major (every pairing once per round, so
a stopped run stays balanced), `Simultaneous games` at a time, saving after
every game. Board engines are paused while it runs.
**Stop** — games in flight end after their current move and are saved as
unfinished (`Stopped`); the run is filed `stopped`. Unfinished games score for
nobody.
**Failed save** — a checkpoint that cannot be written stops new games and shows
the error with `Retry save`, which replays the exact save; nothing else may
start until it succeeds.
**Open games** — a game row, or `Browse games` (game 1), opens `games.pgn` in
the PGN Viewer at that game, so Prev/Next walk the whole run.
**Delete** — trash icon → `Move <name> and its games to the tournament trash?`
→ the folder moves to `.trash/`. Disabled while a run plays or awaits retry;
refused with `The tournament changed. Refresh before deleting it.` if the files
changed.
**Outside work** — the tournaments folder and each run folder are watched;
changes reload the history after 600 ms. If watching fails: `Tournament updates
are unavailable. Use Refresh.`
**Open request** — an `open_request.json` naming a tournament switches to this
mode and selects it, at launch or while running. Unknown id: `No tournament
called "<id>" under Documents/engine_tournaments.`

## Data

- `Documents/engine_tournaments/match-<microseconds>/tournament.json` —
  `version` 1, `id`, `createdAt`, `status`, `finishedAt`, `config` (engines
  copied in, never referenced), `games` (index, round, seats, names, result
  `whiteWins`/`blackWins`/`draw`/`unfinished`, termination, detail, plies,
  start time, duration), plus `timeLabel` written for tools that cannot run
  Dart. Unknown keys are kept. An unreadable file hides that tournament only.
- `games.pgn` beside it — every saved game in schedule order, written with the
  metadata as one recoverable save (`.v2-pending.json` journal; a conflict is
  set aside for inspection, never overwritten). Headers: Event, Site, Date,
  Round, White, Black, Result, Opening, Termination, PlyCount,
  WhiteType/BlackType `program`, GameStartTime, GameDuration, TimeControl
  (`*2` per move, `60+0.6`, `40/600+10`, `?` for depth/nodes), FEN/SetUp off
  the standard start. The termination word is the game's root comment.
  `Annotate evaluations` adds `{+0.31/24 2.001s}` after each move.
- Terminations: `checkmate`, `stalemate`, `insufficientMaterial`,
  `fiftyMoveRule`, `threefoldRepetition` (both rules can be switched off),
  `drawAdjudication` (from move 40, both scores within 10 cp for 8 moves),
  `resignAdjudication` (4 moves at −900 cp, both engines agreeing), `maxMoves`
  (300, a draw), `timeForfeit`, `illegalMove`, `engineFailure`, `aborted`.
  A search is cut off at 175% of a fixed move time plus 2 s, or at the
  remaining clock plus 5 s under a clock.
- `engines.json` — the registry, a JSON list of engine objects (`id`, `name`,
  `executablePath` or none for bundled Stockfish, `arguments`, `options`,
  `threads`, `hashMb`, `ponder` false). Saves refuse if the file changed since
  it was read.
- `open_request.json` — `{tournamentId, requestedAt}` from the MCP tools; moved
  to a private name before reading, deleted after, ignored after 24 hours.
- Registered engines with an executable also appear in Settings as the analysis
  engine (`lib/engines/analysis_launch.dart`).

## Owner decisions

- The mode was authorized by the owner on 2026-09-27. Part of that scope
  (built 2026-09-28): a native file picker for engines, the name following the
  file then `id name`, specific test failures with the engine's first 40 output
  lines, one-click time presets above the custom fields, and the run header's
  time control and format.
- Games stay plain PGN that the PGN Viewer opens; the app, the headless runner
  and the MCP tools share one implementation and one folder.
- Unsettled (no ruling yet): whether fields above two engines keep both
  formats, whether rating statistics should always show, and whether stopped
  runs should resume.
