# Engine tournaments

UCI engines play a position out, and the games are saved as ordinary PGN that
the PGN Viewer opens as one collection. The app, a terminal and an agent all
run the same Dart code and write to the same folder:

```
 a position ─▶ Engine tournament ─▶ Documents/engine_tournaments/match-<µs>/
                                     ├── games.pgn        ← the PGN Viewer opens this
                                     └── tournament.json  ← config + per-game results
```

Each game is saved as soon as it finishes, so a crash or a quit keeps every
finished game. The in-app screen, its controls, the defaults and the files are
specified in [Engine tournament](features/engine-tournament.md). This page
covers what lies outside the app: the agent tools, the headless runner and
where the code lives.

The settings follow [Scid vs. PC's Computer Tournament][scid] and
[cutechess-cli][cutechess], so each setting means what users of those tools
expect. An engine that crashes, hangs or plays an illegal move **loses that
game**; the tournament carries on.

Engines enter the registry only after a real check: the process must start,
complete the UCI handshake, and play a **legal** move from the start position.
The app's check lives in `Engines` → `Add UCI engine…`. The headless one is
`--verify`. A failure is reported as a sentence plus the engine's own first
output lines. A registered engine with its own binary can also be chosen as
the analysis engine in Settings.

## From an agent

The MCP server (`tools/mcp/chess_prep/`, see [OPPONENT_PREP.md](OPPONENT_PREP.md)
for setup) can run a match and then open the app on it.

```
tournament_run {fen: "3r2k1/p4p2/7p/3pB1p1/8/P3P2P/1P3PP1/6K1 b - - 0 1",
                name: "Rook vs bishop", games: 10}
tournament_status {}          # poll: games played, results so far, still running?
tournament_crosstable {}      # standings, head-to-head, rendered table
tournament_games {}           # one row per game
tournament_game_pgn {number: 3}
tournament_open {}            # app opens on it, or jumps there if already running
```

| Tool | |
|---|---|
| `tournament_run` | Start a match from a position; returns as soon as the directory exists and (by default, `open_app`) opens the app on it |
| `tournament_status` | Progress, results and endings so far, whether it is still running |
| `tournament_list` | Every saved tournament, newest first |
| `tournament_crosstable` | Standings, Elo ± interval, LOS, head-to-head grid |
| `tournament_games` | One row per game |
| `tournament_game_pgn` | One game's PGN as saved (eval comments only if the run annotated moves; the headless runner does not) |
| `tournament_stop` | Send the runner SIGINT: the games in flight end after their current move and are saved unfinished |
| `tournament_open` | Open the app on a tournament |
| `tournament_engines` | What is available to play |
| `tournament_add_engine` | Verify a UCI binary and register it |

`tournament_run` starts the games in a detached process and returns within
seconds; a ten-game match at two seconds a move takes about half an hour.
Poll `tournament_status`. The app's screen updates by itself because it
watches the folder.

Two design choices let this work without the app and the agent talking to
each other:

- **The chess is not re-implemented.** Every tool that needs the arbiter, the
  engine check or the standings maths shells out to
  `tools/run_engine_tournament.dart`, which runs the same code as the app. The
  Elo an agent quotes is the Elo on screen.
- **The hand-off is a file.** `tournament_open` writes `open_request.json`
  (`tournamentId`, `requestedAt`) into the tournaments directory. A running
  app sees it appear and switches to the tournament; a closed app opens it at
  the next launch. Requests older than a day are ignored, so a forgotten one
  cannot take over an unrelated launch.

## Headless

The runner works from a terminal too, and writes to the folder the app reads:

```
dart run tools/run_engine_tournament.dart \
  --name "Rook vs bishop" \
  --fen "3r2k1/p4p2/7p/3pB1p1/8/P3P2P/1P3PP1/6K1 b - - 0 1" \
  --games 10 --movetime 2000

dart run tools/run_engine_tournament.dart --verify /path/to/engine
dart run tools/run_engine_tournament.dart --show <tournament-id>
```

`--engine "Name=/path/to/binary"` (repeatable) replaces the default of the
bundled Stockfish playing itself. `--tc 60+0.6` (or `40/60+0.6`) sets a clock,
and `--depth N` a fixed depth, in place of a fixed think time. `--opening`
fills the PGN `Opening` tag, which the app's setup dialog does not offer.
Ctrl-C stops the run: games in flight end after their current move. A `--root`
other than `Documents/engine_tournaments` keeps its recovery records in
`<root>/.support` instead of the app's support folder (`--support` overrides).
`--help` lists every flag.

## Where the code lives

| | |
|---|---|
| `lib/chess/tournament/` | Config, time presets, schedule, results and standings (Elo, SB, LOS) |
| `lib/features/tournaments/game_runner.dart` | One game: engines, clocks, the arbiter, the PGN |
| `lib/features/tournaments/schedule.dart`, `engine_check.dart` | Runs games concurrently; the engine check |
| `lib/features/tournaments/tournament_run.dart` | The app's owner: history, runs, retries, registry |
| `lib/storage/tournaments.dart`, `tournament_inbox.dart` | `tournament.json` + `games.pgn` saved together as one recoverable save; folder watch and open requests |
| `lib/engines/tournament_launch.dart` | Starts one seat (a binary or the bundled Stockfish) |
| `tools/run_engine_tournament.dart` | The headless entry point; also `--verify` and `--show` |
| `tools/mcp/chess_prep/engine_tournament.py` | The MCP tools |

None of the runner, schedule, check, storage or launch code imports Flutter.
That is what lets one implementation serve the app, the terminal (`dart run`)
and an agent.

[scid]: https://scidvspc.sourceforge.net/doc/Tourney.htm
[cutechess]: https://github.com/cutechess/cutechess/blob/master/docs/cutechess-cli.6
