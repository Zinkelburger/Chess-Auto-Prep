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
for checking the harness without an engine). An engine spec is
`[KIND,]key=value,...`; `nodes=` or `movetime=` set the search, `name=` labels
the side, and any other `Option=value` is sent with `setoption`.

| Kind | Engine | Files |
|---|---|---|
| `hivemind` (or no kind) | the engine the app ships, found as the bughouse MCP server finds it (`HIVEMIND_BIN`/`HIVEMIND_MODEL`, the app's unpacked bundle, or `assets/bughouse`) | `bin=`, `model=`, `lib=` (the ONNX Runtime directory); `--engine PATH` sets `bin=` |
| `hypebeast` | the HypeBeast Fairy-Stockfish fork, sent `HypeBeast=true`; `Coordination=false` gives the ablation (default `true`) | `bin=` (default `$HYPEBEAST_HOME/bin/hypebeast`), `net=` |
| `fsf` | **unmodified FSF bughouse via UCI snapshot adapter** | `bin=` (default `$HYPEBEAST_HOME/bin/fsf-ref`), `net=` |

`model=` and `lib=` apply only to Hivemind. `net=` is sent as `EvalFile`
(default `$HYPEBEAST_HOME/nets/bughouse-cd8cceab93fe.nnue`;
`HYPEBEAST_HOME` defaults to `~/Projects/HypeBeast`) and both
Fairy-Stockfish kinds get `UCI_Variant=bughouse`; they need `nodes=` or
`movetime=`. The arena sets `UCI_Variant`, `EvalFile`, `HypeBeast`, `Seat`,
`Clocks`, `Team` and `TimeAdvantage` itself, so a spec cannot.

The three measured comparisons (PLAN rev 7 section 8), with the movetime the
preflight below recommends in place of `T`:

```bash
O=bughouse_arena/opening_sets/screen20.txt   # heldout200.txt for the 200-pair runs
python3 -m bughouse_arena --fixed-sample --openings $O --pairs 20 \
    --contender hypebeast,movetime=T,name=hb-on --baseline fsf,movetime=T,name=fsf
python3 -m bughouse_arena --fixed-sample --openings $O --pairs 20 \
    --contender hypebeast,movetime=T,name=hb-on --baseline hivemind,nodes=400,name=hm-n400
python3 -m bughouse_arena --fixed-sample --openings $O --pairs 20 \
    --contender hypebeast,movetime=T,name=hb-on \
    --baseline hypebeast,movetime=T,Coordination=false,name=hb-off
```

Run them, like every long job, through `scripts/ci.sh with -- ...` from the
repository root (prefix `cd tools &&`), at the default `--concurrency 1`.

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

* A sitting HypeBeast seat may ask to be woken: if its search answered
  `pass` and printed `info string hb_wake_after_ms=N`, the arena asks it
  again N virtual ms later, or earlier on the react-cost wake or an advantage
  flip. Intervening wakes keep that first deadline, and each board turn gets
  at most one, so the wait cannot be renewed indefinitely. Other engines never
  print it and see no change.

## Engines

Every seat is its own process, so a team can mix engines, and a per-seat
engine fits the `Player` interface in `sim.py`: `new_game(board, color)` and
`decide(view) -> uci | None`, where `None` sits. Hivemind and HypeBeast search
a joint action for their whole team; each seat keeps the half for its own
board, and `pass` sits.

Hivemind and HypeBeast get `Team`, `TimeAdvantage` and the dual-FEN position
(`position startpos moves 1e2e4 2d2d4 ...` or `position fen A|B moves ...`).
`Seat` (`Awhite`/`Ablack`/`Bwhite`/`Bblack`, once per game) and `Clocks`
(`aW,aB,bW,bB`, the virtual clocks in ms, before every `go`) are sent only
to engines whose `uci` output advertises them, so Hivemind never receives
them. The `hypebeast` kind refuses an engine that does not advertise
`HypeBeast`, `Coordination`, `Seat`, `Team` and `TimeAdvantage`.

The `fsf` kind is labelled **unmodified FSF bughouse via UCI snapshot
adapter**. Each decision sends the seat's own board as one FEN with the real
pockets in bracket notation (promoted pieces marked `~`), castling, the
en-passant square and the referee's counters (`players.fsf_fen`), then `go`,
and reads an ordinary `bestmove`. It receives actual hands but no pre-root
repetition history and no CECP partner messages, so it does not measure every
native team-play feature. When the referee says play goes on but the seat has
no legal move, the adapter sits without asking the engine. A null (`(none)`,
`0000`) or illegal answer while legal moves exist goes to the referee
unchanged and loses as an illegal move; nothing is substituted. The first
search must report `NNUE evaluation using <net>`, or the seat fails rather
than play on a classical fallback.

No engine can wedge the arena. Every command is written with a deadline, and
every search has a hard wall-clock limit (`--search-timeout`, default 3x
movetime + 15 s, or 120 s for a node budget). A search that misses it, or an
engine that dies, is an engine failure: the process is killed, the game ends
with termination `error` and the message in `result.error` (never as a sit),
the worker starts fresh processes for the next game, and `fixed_sample`
reports it under `reliability`.

The `fsf` and `hypebeast` seats get fresh processes for every game. The
unmodified Fairy-Stockfish binary keeps search state across `ucinewgame`:
after one game's searches, the same `position fen` and `go nodes 20000`
gives a different move than in a fresh process, even after `Clear Hash`.
That broke pair symmetry (FSF against itself scored 0-2 pairs); with fresh
processes both games of a pair are move-for-move mirrors. Hivemind processes
persist across games as before.

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
`results.jsonl` (one game per line, with every move, sit, wake and advantage
flip and the clocks at each, the engine's own score for each move or sit as
`eval`, and each engine seat's searches, nodes, search latencies, passes,
mandatory sits and wake requests), `games.bpgn` (below), `manifest.json` and
`summary.json`: score, Elo with a 95%
CI over opening pairs, the pentanomial, SPRT state, terminations, per-side
sitting behaviour (sits, seconds sat per game, share of decisions taken up on
time, timer wakes), per-side search latency (mean/median/p95/max), and the
`fixed_sample` block below. `--engine-logs` keeps each process's UCI traffic.
Openings are random (`--opening-plies` per board) or read from `--openings`
(engine-format move lists such as `1e2e4 2d2d4`, or dual FENs). The legacy
statistics port Hivemind's `engine/src/tools/tournament.cc`, so those numbers
mean the same thing.

`games.bpgn` opens in the app (Bughouse, **Open BPGN…**): each game is
written from the start in SAN with the opening included, the four players in
`WhiteA`/`BlackA`/`WhiteB`/`BlackB`, and after each move
`{[%clk 0:01:38.6] [%eval 3.19] 45.2s}`: the mover's clock after the move, the
engine's score, and the game time the move was played at. `[%eval]` is in
pawns (`#N` for a mate) from the point of view of White on that board, as PGN
readers expect. In `results.jsonl` the same score is `{"cp": n}` or
`{"mate": n}` as the engine reported it, for the side that moved. Hivemind
reports one score for its team, so it speaks for both boards. HypeBeast's is
its main search of its own board, even when the coordinator played another
move.

`manifest.json` pins the run: each side's kind, settings and the SHA-256 of
its binary, model, ONNX Runtime and net, the engine's own `uci` description
(id, advertised options and defaults, startup info strings, the options the
arena sent, and for the Fairy-Stockfish kinds one probe search confirming
NNUE), the opening file and its hash, clock model, seed, statistics mode,
arena source hashes and git HEAD, the host (CPU, cores, memory, cgroup CPU
quota, thread-related environment) and the command line. `--resume` refuses
to continue if any pin changed. Games voided by an engine crash or timeout
are moved to `replayed_errors.jsonl` before being replayed, and counted.

## Fixed-sample statistics

The ported SPRT scores each pair by total points rather than by the
distribution of pair outcomes, so `--fixed-sample` disables it (it refuses
`--sprt-*`) and plays exactly `--pairs` pairs, one opening each. The
`fixed_sample` block reports W/D/L, score, the pentanomial (`0-2` ... `2-0`
pair outcomes), and a 95% interval with opening pairs as the sampling unit:
the Wilson score interval for the mean pair score with effective sample size
`pairs / phi`, where `phi` (the variance over its maximum `p(1-p)`) comes from
the pentanomial with 0.5 pseudocounts per outcome. The pseudocounts touch only
the dispersion, so the interval always contains the observed score. Unlike
the paired normal approximation it never has zero width: all pairs won gives
`[L, 100%]`, all pairs drawn 1-1 a narrow band around 50%. Elo is secondary;
it is `null` at 0% or 100%, and an interval end at 0% or 100% is unbounded.
Crashes, timeouts and illegal moves are listed under `reliability`, never
dropped silently.

## Openings

`opening_sets/` holds pinned sets cut from real FICS games by
`python3 -m bughouse_arena.openings` (each file's header has the command): the
first 16 half-moves of a rated game whose four players are all 1800+, in the
order they were played, so the pockets are the real ones. Positions where a
side to move is in check, has no legal move, or the game is decided are
skipped, and at least one pocket must be non-empty. Every second opening has
its boards swapped, so board roles are balanced across a set; within a match
each opening is played twice with teams swapped and the same seeded move
costs per seat.

| File | Use |
|---|---|
| `debug.txt` | debugging and tuning only; never report results on it |
| `preflight.txt` | middlegame positions (32 half-moves) for the latency preflight |
| `screen20.txt` | 20-pair screening matches |
| `heldout200.txt` | the fresh 200-pair strength matches; do not inspect or tune on it |

Each comes from a different archive year and no position appears in two sets.
"Held out" means held out from our own tuning and screening; what Hivemind
was trained on is not known.

## Hivemind latency preflight

```bash
python3 -m bughouse_arena.preflight --output ~/.local/share/chess-prep/bughouse-arena/preflight.json
```

Each search has a hard limit (`--search-timeout`, default 60 s); a miss is
recorded as a failed search and an overrun, the engine is killed and
restarted, and the run goes on. No search starts after `--max-minutes`
(default 20); the report then says `complete: false`. The JSON is rewritten
after every phase and the UCI traffic goes to `<output>.uci.log`, so a killed
run still leaves its data.

Searches every `preflight.txt` seat on turn with Hivemind at `nodes=400`
and at `go movetime` 100/250/500/1000 ms, after discarded warm-up searches,
in one process. It reports mean, median, p95, max and total latency, nodes,
overruns, whether movetime is honoured (median at least 0.8 M, p95 at most
M + max(10%, 25 ms)), the host, cgroup CPU quota, the engine's threads,
backend and hash as it reports them, file hashes, and the local Hivemind
checkout. Its recommendation: if movetime is honoured, one movetime for every
arm; otherwise Hivemind keeps `nodes=400` and the Fairy-Stockfish arms get its
mean latency as total movetime ("matched mean compute"). Run it under the same
`scripts/ci.sh with` limits as the matches, since the job's CPU quota changes
the latency.

## Pinned Hivemind

The arena's `hivemind` is whatever `tools/mcp/bughouse/paths.py` finds; on
the measuring machine that is the app's unpacked bundle in
`~/.local/share/com.example.chess_auto_prep/bughouse/`, which matches
`tools/assets.lock.json` (release `engine-v0.2.0`):

| File | SHA-256 | Lock entry |
|---|---|---|
| `hivemind-linux` (3,721,512 bytes) | `2d8c6cdb1183c0ef0105368524bea98e03cace3dd5df0a6a1f0f0a4efa97cfe5` | `bughouse-linux:engine` payload |
| `hivemind.onnx` (54,415,625 bytes) | `61f74ba7d9a79868b565d51ece450519a4dc6b38d697aabd117fc5b843281a2f` | `bughouse-network` payload (fp32) |
| `libonnxruntime.so.1` | `5715f06d8992ca8eeeddcce43df3a7d38f97d537052126f558e912cb312460ca` | `bughouse-linux:runtime` payload |

It reports `Hivemind 1.0`, backend ONNX Runtime (CPU), batch 8, 4 search
workers and intra-op threads = cores / 4. It has no `PermanentBrain` option
(the arena sends `stop` after each `bestmove`) and ignores
`HIVEMIND_ORT_THREADS`. Every run's manifest records these hashes again.

The source checkout at `~/Projects/hivemind` is not that build: on
2026-11-06 it was branch `portable-desktop-builds` at `5508ba9` (tag
`engine-v0.1.0`), one commit behind `engine-v0.2.0` (`0b02588`, MultiPV while
searching and `go infinite`), with uncommitted edits adding `PermanentBrain`
and `HIVEMIND_ORT_THREADS`. Its `dist/` and `engine/build-ort/` binaries hash
differently from the installed one, and its `engine/models/hivemind.onnx`
(`a0ec548c...`) is not the installed network (its `hivemind-fp32.onnx` is).
The preflight report records the checkout's state each time it runs.
