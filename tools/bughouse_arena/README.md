# Bughouse arena: engine-vs-engine matches on simulated clocks

Plays real bughouse between engines: both boards running at once, four clocks,
captured pieces going to the partner, sitting allowed and paid for. Time is
virtual, so a 100 ms search can be charged 2 s of clock and results stay
reproducible across machines. The question it answers is whether a contender
beats a baseline, usually the Hivemind the app ships (see
[Hivemind, end to end](../../docs/HIVEMIND.md)).

Hivemind's own `tournament` command has no clock (teams alternate turns and
`TimeAdvantage` flips every turn, so sitting is free), and
`bughouse_nnue match` pits two Fairy-Stockfish evals against each other with no
sitting at all. This is the one that plays with clocks and can seat Hivemind.

From `tools/`:

```bash
python3 -m bughouse_arena \
    --contender hivemind,nodes=400,name=n400 \
    --baseline  hivemind,nodes=100,name=n100 \
    --pairs 50 --sprt-elo0 0 --sprt-elo1 20
```

A side is an engine spec, or `random` / `random,sit=0.2` (random legal moves,
for checking the harness without an engine). In a spec, `hivemind` is the
engine the app ships, found as the bughouse MCP server finds it
(`HIVEMIND_BIN`/`HIVEMIND_MODEL`, the app's unpacked bundle, or
`assets/bughouse`). `bin=`, `model=` and `lib=` (the directory holding ONNX
Runtime) point at another build or network, `nodes=` or `movetime=` set the
search, `name=` labels the side, and any other `Option=value` is sent with
`setoption`. `--engine PATH` sets `bin=` for both sides.

## Time model

| Setting | Default | Meaning |
|---|---|---|
| `--clock` | 120 | seconds per seat, no increment |
| `--move-cost` | `1.5:2.5` | virtual seconds a move costs, fixed (`2`) or uniform `LOW:HIGH` |
| `--react-cost` | 0.5 | seconds a sitting seat takes to react to a move on the other board |

* Exactly one seat per board is on turn and its clock runs, whether it is
  thinking or sitting. Sitting burns **your own** clock; your partner's board
  carries on.
* A seat comes on turn, thinks for `move-cost`, then decides with what is on
  the boards *at that moment*, so pieces the partner captured meanwhile count.
* A sitting seat is asked again `react-cost` after any move on the other board,
  or the instant its team's time advantage flips. A clock at zero loses.
* Time advantage is Hivemind's training definition: a team is up when its
  board-A seat has more time than the same-colour seat on board B. It is
  computed from the clocks and sent as `TimeAdvantage`.

The default cost is jittered because a flat cost stalls the clock signal: with
a fixed 2 s and nobody sitting, the diagonal clocks stay exactly tied, so
neither team is ever up on time and the engine's sitting logic never comes
into play. With 1.5–2.5 s about a third of decisions are taken up on time.

## Rules

`referee.py` uses python-chess, not Fairy-Stockfish, so a rules bug on either
side shows up as a disagreement instead of being shared. Its terminal rules
port Hivemind's `engine/src/environment/board.cc` (unpack
`tools/bughouse_windows/hivemind-source.tar.gz` to read it):

* **Mate** is `Board::is_checkmate`: no escape, *and* the partner cannot supply
  a blocking piece (now if on turn, or after any opponent reply when up on
  time). A team with no legal move anywhere it is on turn loses unless it is up
  on time. The tests port the engine's mate tests case by case.
* **Draws** are fifty moves or threefold repetition of the on-board position
  (pockets ignored) on either board.
* An illegal move loses for its team; an engine crash voids the game, and
  `--resume` replays it.

## Engines

Every seat is its own process, so a team can mix engines, and a per-seat
engine fits the `Player` interface in `sim.py`: `new_game(board, color)` and
`decide(view) -> uci | None`, where `None` sits. Hivemind searches a joint
action for its whole team; each seat keeps the half for its own board, and
`pass` sits.

An idle seat must not search on another seat's time. Builds that advertise
`PermanentBrain` get it turned off; older ones, including the shipped release,
get `stop` after every `bestmove`, which ends the background search within
milliseconds. `--concurrency N` plays N games at once and sets
`HIVEMIND_ORT_THREADS` to split the cores between them; builds that predate
that variable use every core per search, so keep `--concurrency 1` with the
shipped engine.

## Output

The match directory (default
`~/.local/share/chess-prep/bughouse-arena/<contender>-vs-<baseline>`) holds
`results.jsonl` (one game per line, with every move, sit and advantage flip
and the clocks at each), `games.bpgn` (moves with time stamps), and
`summary.json`: score, Elo with a 95% CI over opening pairs, the pentanomial,
SPRT state, terminations, and per-side sitting behaviour (sits, seconds sat
per game, share of decisions taken up on time). Openings are random
(`--opening-plies` per board) or read from `--openings` (engine-format move
lists such as `1e2e4 2d2d4`, or dual FENs). The statistics port Hivemind's
`engine/src/tools/tournament.cc`, so the numbers mean the same thing.
