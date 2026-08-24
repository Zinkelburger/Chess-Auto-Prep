# Engine tournaments

Put two engines in a position and let them settle it. The games are ordinary
PGN, so the whole match opens in the PGN Viewer and you click through it like
any other collection.

```
 a position ─▶ Engine Tournament ─▶ Documents/engine_tournaments/<slug>/
                                     ├── games.pgn        ← the PGN Viewer opens this
                                     └── tournament.json  ← config + per-game results
```

Everything is on disk as it happens: a match interrupted by a crash, a quit,
or a power cut keeps the games it had already played.

## In the app

**Engine Tournament** in the mode menu. New tournament asks for the engines,
the starting position (a FEN, the board's current position, or the clipboard),
the time control, the schedule, and the adjudication rules. While it runs you
get the live board and the game in progress; when it is done you get the
crosstable and one row per game. Clicking a row opens that game in the PGN
Viewer with the whole match still loaded, so Prev/Next walk the rest of it.

### History

The left rail is the record of every match ever run — including ones started
headlessly or by an agent, since they all land in the same directory. Rows are
newest first, grouped by day (Today / Yesterday / month), and each one carries
its own score (`Stockfish #1 5½–4½ Stockfish #2`), the games played, the time
control, when it started and how long it took. Past six runs a filter box
appears above the list; it matches on name, engine and opening. Nothing has to
be opened in a file manager to find out what happened.

### Move comments

The PGN is written *without* per-move engine comments by default. Tick
**Annotate every move with the engine's eval** to get cutechess's
`{+0.31/24 2.001s}` after every move — what engine-testing tools read, at the
cost of the viewer putting each move on its own line. The viewer also filters
comments in that shape out of games recorded before this was a choice, and out
of PGNs written by cutechess-cli or Arena.

### Parameters

Modelled on [Scid vs. PC's Computer Tournament][scid] and
[cutechess-cli][cutechess], so the knobs mean what someone used to those tools
expects.

| | Options | Default |
|---|---|---|
| Time control | Per move; a clock (base + increment, optionally `40/600+10`); fixed depth; fixed nodes | **2 s per move** |
| Schedule | Round robin or gauntlet; games per pairing; alternating colours | 10 games, colours alternating |
| Concurrency | Games in flight at once | 1 — concurrent games share the CPU and make every result noisier |
| Per engine | Hash, threads, permanent thinking, extra `setoption` pairs | 128 MB, 1 thread, no pondering |
| Draw adjudication | From move N, both engines within X cp for Y moves | from move 40, within 10 cp for 8 moves |
| Resign adjudication | Below −X cp for Y moves, optionally with the winner agreeing | −900 cp for 4 moves, both agreeing |
| Hard stop | Move ceiling, filed as a draw | 300 moves |

Games also end the ordinary ways: checkmate, stalemate, insufficient material,
the fifty-move rule, threefold repetition. An engine that crashes, hangs, or
plays an illegal move **loses that game** rather than aborting the tournament —
which is the whole point of running one.

The crosstable reports score, W/D/L, draw rate, Sonneborn-Berger, the rating
difference the score implies with its 95% interval, and the likelihood of
superiority. Read the interval before the estimate: `+0 ±252` after ten games
means the match has not decided anything.

### Your own engines

The rest of the app only ever runs the bundled Stockfish. **Engines…** in the
overflow menu is the one place a binary you chose gets launched, and nothing
gets into the list without passing a real check: the process must start, answer
`uci` with `uciok`, answer `isready`, and play a **legal** move from the
starting position. A wrapper script, an XBoard-only engine, or a binary for the
wrong architecture is reported as a sentence — with the engine's own output
attached — instead of turning into a match of silent forfeits.

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
| `tournament_run` | Start a match from a position; returns as soon as the directory exists and (by default) opens the app on it |
| `tournament_status` | Progress, results and endings so far, whether it is still running |
| `tournament_list` | Every saved tournament, newest first |
| `tournament_crosstable` | Standings, Elo ± interval, LOS, head-to-head grid |
| `tournament_games` | One row per game |
| `tournament_game_pgn` | One game, with the engines' evals in the move comments |
| `tournament_stop` | Stop cleanly after the game in flight |
| `tournament_open` | Open the app on a tournament |
| `tournament_engines` | What is available to play |
| `tournament_add_engine` | Verify a UCI binary and register it |

`tournament_run` leaves the games playing in a detached process and comes back
in seconds, because a ten-game match at two seconds a move takes about half an
hour. Poll `tournament_status`; the app's screen fills in on its own.

Two things make this work without the app and the agent talking to each other:

- **The chess is not re-implemented.** Every tool that needs the arbiter, the
  engine check, or the standings maths shells out to
  `tools/run_engine_tournament.dart` — the same code the app runs. The Elo an
  agent quotes is the Elo on screen.
- **The hand-off is a file.** `tournament_open` writes `open_request.json` into
  the tournaments directory. A running app sees it appear and jumps there; a
  closed one honours it on next launch. Requests older than a day are ignored,
  so a forgotten one cannot hijack an unrelated launch.

## Headless

The same runner works from a terminal, and writes into the same place the app
reads:

```
dart run tools/run_engine_tournament.dart \
  --name "Rook vs bishop" \
  --fen "3r2k1/p4p2/7p/3pB1p1/8/P3P2P/1P3PP1/6K1 b - - 0 1" \
  --games 10 --movetime 2000

dart run tools/run_engine_tournament.dart --verify /path/to/engine
dart run tools/run_engine_tournament.dart --show <tournament-id>
```

`--engine "Name=/path/to/binary"` (repeatable) replaces the default of the
bundled Stockfish playing itself. `--tc 60+0.6` takes a clock instead of a
fixed think time. Ctrl-C stops after the game in flight.

## Where the code lives

| | |
|---|---|
| `lib/features/engine_tournament/` | Models, the arbiter, the runner, the store, the crosstable, the screen |
| `tools/run_engine_tournament.dart` | The headless entry point; also `--verify` and `--show` |
| `tools/mcp/chess_prep/engine_tournament.py` | The MCP tools |

The core is Flutter-free `dart:io` on purpose — that is what lets one
implementation serve the app, the terminal, and an agent.

[scid]: https://scidvspc.sourceforge.net/doc/Tourney.htm
[cutechess]: https://github.com/cutechess/cutechess/blob/master/docs/cutechess-cli.6
