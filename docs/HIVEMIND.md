# Hivemind, end to end

The bughouse engine behind Bughouse Lab, the `bughouse` MCP server, the
`/bughouse` and `/bughousedb` web pages and every engine match. This document
is the one place that explains *how it works* rather than how to call it:
what the network sees, what the search does with it, and — the question that
sends everyone here — **why the evaluation sits near 0.00 when one side is
clearly up material.** That last part is measured on this machine; the
numbers are in [Why everything reads 0.00](#why-everything-reads-000).

Calling the thing is documented elsewhere: [`bughouse-mcp`
skill](../.agents/skills/bughouse-mcp/SKILL.md) for the MCP tools,
[Bughouse matches](BUGHOUSE_MATCHES.md) for engine-vs-engine games,
[Component map](COMPONENT_MAP.md) for the Flutter surfaces.

## What it is

Hivemind is an **AlphaZero-lineage engine adapted to two boards**: a
convolution-plus-attention network with value, policy, WDL and moves-left
heads, driven by a Monte-Carlo *graph* search. Its DNA is Leela — the
centipawn transform `180·tan(1.56·Q)` is Lc0's `90·tan(1.5637·Q)` with the
scale doubled — and if you know Lc0 you already know most of the machinery.
Three things are genuinely different, and all three matter more than the
resemblance:

1. **One network sees both boards.** The input is 74 planes of 8×8: 37 per
   board, stacked. There is no separate partner evaluation to combine.
2. **The action is joint.** Two policy heads, one per board, and the search
   picks a *pair* — `(d2d4,pass)`. `pass` (sitting) is a first-class action,
   with index 0 reserved for it in both heads.
3. **The clock is an input bit, not a statistic.** One plane says "our team
   may sit". It is the single most influential number in the whole
   evaluation — worth about 1.2 of the 2.0-wide value range, which is
   roughly five and a half pawns-in-hand. Everything confusing about
   Hivemind's scores follows from this one fact.

| | |
|---|---|
| Upstream | `github.com/Zinkelburger/hivemind`, pinned at `5508ba9daf4164e48a8a8a9b39e101efdc60e97a` |
| Language | C++23, CMake + Ninja; embeds a stripped Fairy-Stockfish for move generation |
| Licence | Hivemind MIT; the bundled Fairy-Stockfish is GPL-3.0 |
| Backends | `tensorrt` (FP16, default upstream) or `onnxruntime` (FP32, portable) — **we ship ORT** |
| Corresponding source, vendored | `tools/bughouse_windows/hivemind-source.tar.gz` and `python/twic-position-finder/frontend/public/bughouse-engine/hivemind-source.tar.gz` |

There is no Hivemind checkout on this machine. When you need to read the
engine's own code, unpack one of those two tarballs; when you need to
*change* it, clone upstream at that revision and rebuild with
`--hivemind <checkout>` (see [Rebuilding](#rebuilding-and-repackaging)).

## The path a position takes

```
  a dual FEN                       two crazyhouse FENs, pipe-separated
  "rnbq…/RNBQ… w KQkq - 0 1|rnbq…/RNBQ… w KQkq - 0 1"
        │
        │  uci.cc: position fen <A>|<B> [moves 1e2e4 2d7d5 …]
        ▼
  DualBoard                        Fairy-Stockfish ×2, plus the cross-board
        │                          capture rule and the reserves
        │  planes.cc: board_to_planes(board, obs, teamSide, hasTimeAdvantage)
        ▼
  [batch, 74, 8, 8] float32        37 planes per board, always from the seat
        │                          our team occupies on that board
        │  ONNX Runtime CPU, batch 8, one worker per search thread
        ▼
  value  pi_a  pi_b  wdl  moves_left
   [1]  [4672][4672]  [3]    [1]
        │
        │  agent.cc: MCGS — PUCT over joint actions, progressive widening,
        │            transpositions, virtual loss, MCTS solver
        ▼
  bestmove (d2d4,pass) ponder (d7d5,d2d4)
  info depth 12 score cp -230 nodes 1500 nps 350 … pv (d2d4,pass) …
        │
        ├── Bughouse Lab            lib/features/bughouse/
        ├── bughouse MCP server     tools/mcp/bughouse/
        ├── the browser (WASM)      python/twic-position-finder/frontend/
        └── engine matches          BUGHOUSE_MATCHES.md
```

## What the network sees

**74 = 2 × 37.** Board A is channels 0–36, board B is 37–73, each channel 64
contiguous floats in Stockfish bitboard order (A1 first). Per board, in order:

| Channels | n | Content |
|---|---|---|
| 0–11 | 12 | pieces: `{first, second}` colour × `{P,N,B,R,Q,K}` |
| 12–21 | 10 | **reserves**: `count_in_hand(colour, type) / 16` broadcast over all 64 squares, `{first, second}` × `{P,N,B,R,Q}` |
| 22–23 | 2 | promoted-piece mask, one per colour |
| 24 | 1 | en-passant square |
| 25 | 1 | 1.0 iff the side to move on this board is the expected one |
| 26 | 1 | constant plane, all 1.0 |
| 27–30 | 4 | castling: our O-O, our O-O-O, their O-O, their O-O-O |
| **31** | **1** | **`hasTimeAdvantage`** — may our team sit? |
| 32–33 | 2 | last move: from-square, then to-square (from is blank for a drop) |
| 34 | 1 | `min(rule50, 50) / 50` |
| 35–36 | 2 | repetition ≥ 2, repetition ≥ 3 |

Two details that are easy to get wrong if you write your own encoder:

- **Perspective.** Each board is presented from the seat *our team* occupies
  on it, so the planes are vertically flipped when `boardIdx == 0 && teamSide
  == BLACK`, or `boardIdx == 1 && teamSide == WHITE`. Board B is the
  partner's board, and the partner holds the other colour — hence the
  asymmetric condition.
- **`first` / `second` colour order** is `first = (boardIdx == 0) ? teamSide
  : ~teamSide`. There is no absolute white/black; there is only ours and
  theirs.

Plane 31 is one bit, held constant across all 64 squares of both boards, and
it is the plane that dominates the output. Keep it in mind for the whole rest
of this document.

### The heads

| Output | Shape | What it is |
|---|---|---|
| `value` | `[batch, 1]` | scalar Q ∈ [−1, 1], expected score from our team's seat |
| `pi_a` | `[batch, 4672]` | board-A policy **logits**, 73 × 64 AlphaZero encoding |
| `pi_b` | `[batch, 4672]` | board-B policy logits, same encoding |
| `wdl_out` | `[batch, 3]` | win / draw / loss **logits**, softmaxed by the caller |
| `moves_left` | `[batch, 1]` | plies to the end ÷ 100 |

Policy index 0 is reserved for `pass` in both heads. Priors are a softmax
over *only the legal indices*, so the raw head is logits despite the
`Softmax` nodes elsewhere in the graph. Rook and bishop underpromotion are
not representable — `get_fast_policy_index` returns −1 and the prior becomes
−∞. The search mixes `value` with `wdl_out` at `WDL_VALUE_WEIGHT = 0.25`.

The ORT backend also *looks* for `jointfactors_a` / `jointfactors_b` heads —
a low-rank factorisation of the joint action distribution. **The shipped
network does not have them**, so `jointFactorRank == 0` and the search treats
the two boards' policies as independent when it forms joint priors. That is a
real modelling gap and a clear place to improve the engine; see [Where to
push](#where-to-push).

### The shipped network, by the numbers

Parsed from `~/.local/share/chess-prep/bughouse/hivemind.onnx`:

| | |
|---|---|
| File | 54,415,625 B raw / 31,699,868 B gzipped |
| Producer | PyTorch 2.9.1, IR 8, opset `ai.onnx` 18 only |
| Parameters | **13,574,808**, all FP32 — no quantisation anywhere |
| Nodes / initializers | 392 / 199 |
| Trunk | width 384, ≥16 `body_spatial` blocks with squeeze-excite |
| Ops | 25 distinct; `Conv 59, Add 53, Reshape 49, Relu 37, Transpose 36, MatMul 28, LayerNormalization 12, Erf 4 …` |

The `Transpose`/`MatMul`/`LayerNormalization`/`Erf` cluster means this is a
**hybrid conv + attention trunk**, not a pure ResNet. Weights are 99.8% of
the file, and they are concentrated oddly:

| Group | Bytes | Share |
|---|---:|---:|
| convolutions | 36,078,912 | 66.4% |
| **squeeze-excite** — 5 tensors, all `[384, 384, 5]` | **14,753,280** | **27.1%** |
| MatMul | 2,064,384 | 3.8% |
| policy heads | 1,009,152 | 1.9% |
| cross-board | 310,272 | 0.6% |
| everything else (position, value, pocket, context, scalar) | ~82,000 | 0.2% |

Five SE tensors carrying 27% of the network is worth a look on its own. A
squeeze-excite gate is normally a pair of tiny bottleneck matrices; a
`[384, 384, 5]` conv inside one, in 5 of 16 blocks, is either a deliberate
wide channel-mixer or an export artifact. Either way it is the single biggest
per-tensor lever on download size, and the first thing to ask upstream about.

## What the search does

Monte-Carlo **graph** search (`ENABLE_MCGS = true`) — transpositions are
merged rather than duplicated, with a 100 k → 1 M-entry table.

| Knob | Default |
|---|---|
| `CPUCT_INIT` / `CPUCT_BASE` | 2.5 / 19652 |
| FPU | dynamic, `FPU_REDUCTION 1.0`, `Q_INIT −1.0` |
| Progressive widening | `PW_COEFFICIENT` / `ROOT_PW_COEFFICIENT` 4.0 |
| Batch / search threads | 8 / 4 (ORT: intra-op = cores ÷ threads, inter-op 1) |
| Tree reuse | up to 3 joint plies |
| Solver | MCTS solver plus a dedicated root mate search (≤100 k nodes or 20% of time) |
| Permanent brain | 500 k nodes / 60 s cap, runs *between* your commands |
| Optional | Gumbel root search, draw contempt, moves-left discount |

Two consequences you will actually feel:

**The permanent brain will starve your next search.** After `bestmove`, the
engine keeps all four workers busy until the next `position`, `go` or `stop`.
Both clients send `stop` after every search for exactly this reason
(`tools/mcp/bughouse/engine.py`); if you drive the binary yourself, do the
same.

**The joint action space is enormous, and progressive widening is why the
engine works at all.** Measured with python-chess on this machine:

| Position | legal on A | on B | joint pairs |
|---|---:|---:|---:|
| opening, empty reserves | 20 | 20 | 441 |
| symmetric Italian, empty reserves | 36 | 36 | 1,369 |
| same, five pieces in each hand | 190 | 190 | **36,481** |

At the 350 nodes/second this ORT-on-CPU build manages, a 1,500-node search is
seven seconds and visits **4% of the root's children** in a piece-rich
middlegame. Progressive widening means it only ever generates a slowly
growing subset, so it is not as hopeless as the raw ratio suggests — but it
does mean the root Q you read is an average over a *narrow, prior-selected*
slice of the position, and it is why MultiPV rank 3 routinely scores better
than rank 2 (Hivemind ranks MultiPV by *visit count*, not by score —
`analysis.by_strength` re-sorts for this reason).

## Why everything reads 0.00

This is the question the engine gets asked most, and the answer has three
layers. All the numbers below were measured on this machine with the shipped
FP32 ORT build, on a **symmetric Italian on both boards** (identical FEN, so
the true advantage is 0 by construction), our team white on A.

### Layer 1 — the raw score is not an evaluation at all

The number in `info … score cp` is `180·tan(1.56·Q)` of an MCTS Q that
carries a large offset, and the offset is mostly the network reading plane 31.
With neither team allowed to sit, a dead-equal position reads **cp −230 from
both seats**. That is not a bug, and it is not a bias you can subtract once:
it is the network saying *"a team that can never sit is losing"*, and how
much it is losing by depends on the position.

The `policy` UCI command prints the network's opinion with no search at all,
which separates the network from the MCTS. Raw value, our seat, no sitting
rights for anyone:

| Position (all genuinely equal) | raw `value` | W | D | L | Δvalue if we may sit |
|---|---:|---:|---:|---:|---:|
| the opening | −0.559 | 0.210 | 0.021 | 0.769 | **+1.197** |
| symmetric Italian | −0.597 | 0.191 | 0.022 | 0.788 | **+1.361** |
| mirrored king-and-pawn ending (per the calibration notes) | — | — | — | — | smaller |

Read that last column again. **Flipping one input bit moves the network's
value by 1.2–1.4 on a scale whose entire width is 2.0.** The right to sit is
worth ~60–70% of the whole evaluation range. Nothing else in bughouse comes
close, and that is the engine's considered opinion, not an artifact — sitting
is how you convert a clock lead into a mate.

Note also the draw column: **D ≈ 0.02**. This is *not* a draw-heavy network
squashing everything toward the middle, which is the usual explanation for
flat evals. Rule that one out.

### Layer 2 — the calibration is correct, and it leaves a small number behind

Because the offset is position-dependent, both the app and the MCP server
measure it instead of assuming it: search the same position from both seats,
and since `q = ±advantage + offset`,

```
offset    = (q_ours + q_theirs) / 2
advantage = (q_ours − q_theirs) / 2
```

This works. On the symmetric Italian the measured offset is −0.710 and the
advantage comes out at **+0.0007** — level, to four decimal places, as it
must be. The machinery is sound.

But notice what it implies. If ~0.6 of Q is spent on the clock term before
any material is counted, the *residual* that material can occupy is small by
construction. So a correct calibration necessarily produces small numbers.

### Layer 3 — the engine does see material, and it is right that a piece "just gone" is worth much less

Here is the measurement that actually answers the question. Calibrated
advantage, 1,500 nodes, two searches each. Two versions of "up a piece":

- **vanished** — the piece is simply removed from board A. This is what a
  chess player sees when they glance at one board.
- **to partner** — removed from board A *and* added to our partner's reserve
  on board B. This is what actually happens when you capture: the piece
  crosses boards, keeps its colour, and lands in your partner's hand.

| | advantage (Q) | prints as | win% | pawns-in-hand |
|---|---:|---:|---:|---:|
| equal | +0.0007 | +0.00 | 50.0 | 0.0 |
| +pawn, vanished | +0.079 | +0.22 | 54.0 | 0.8 |
| +knight, vanished | +0.105 | +0.30 | 55.2 | 1.0 |
| +rook, vanished | +0.051 | +0.14 | 52.6 | 0.5 |
| +queen, vanished | +0.147 | +0.42 | 57.4 | 1.4 |
| **+pawn, to partner** | **+0.104** | +0.29 | 55.2 | 1.0 |
| **+knight, to partner** | **+0.177** | +0.51 | 58.8 | 1.7 |
| **+rook, to partner** | **+0.155** | +0.44 | 57.8 | 1.5 |
| **+queen, to partner** | **+0.426** | +1.41 | 71.3 | 4.1 |
| their queen gone from board B | +0.126 | +0.36 | 56.3 | 1.2 |

Raw network value, no search, confirms the same ordering and is cleanly
monotone: pawn +0.099, knight +0.219, queen +0.489, two pieces +0.620, and
being a queen *down* reads −0.312.

Four conclusions:

1. **It sees material fine.** A queen in your partner's hand is +0.43 of Q
   and 71% — that is a big, confident, correctly-signed number.
2. **A piece that merely left the board is worth about a third as much as a
   piece in your partner's hand.** Compare the queen rows: +0.147 vanished
   against +0.426 delivered. The engine is right and the chess eye is wrong.
   "He's up a knight" is not a bughouse fact until you say *whose hand the
   knight is in*. Most reports of "the eval ignores material" are this: a
   position typed in with the material deleted rather than transferred.
3. **The vanished column is not monotone** (rook +0.051 below pawn +0.079)
   and shouldn't be — an a8 rook doing nothing is worth less off the board
   than a centre pawn is, once you are no longer counting points.
4. **It is not noise.** The same position at 400 / 1,500 / 6,000 nodes gives
   +0.436 / +0.426 / +0.406. Converged, and stable to a percent.

### So the real culprit is the printed scale

Near zero, `score = 180·tan(1.56·advantage)/100 ≈ **2.81 × advantage**`. The
printed number looks like pawns, is labelled like pawns, and is not pawns:

| What you have | prints as | a chess player expects |
|---|---:|---:|
| a pawn in your partner's hand | **+0.29** | +1.00 |
| a knight in your partner's hand | **+0.51** | +3.00 |
| a queen in your partner's hand | **+1.41** | +9.00 |
| the right to sit | ~+1.63 of swing | — |

**That is the answer.** A clean extra knight reads `+0.51`, which every chess
player on earth reads as "dead equal, engine noise". It is not noise — it is
58.8%, a real and substantial edge — the units are just six times smaller
than the ones the display invites you to assume.

### What to do about it

Three options, cheapest first. None requires touching the engine.

1. **Read `win%`, not the score.** It is already linear in `advantage`
   (`50·(1 + advantage)`), so gains and losses read symmetrically, and 58.8%
   is much harder to misread than +0.51. It is exposed today on
   `BughouseEval.winLabel` and as `win_percent` from the MCP server. Caveat:
   it is a re-centred engine estimate, **not** a calibrated probability, and
   it is not the network's WDL.
2. **Anchor the displayed scale on a pawn-in-hand instead of the tangent.**
   One pawn delivered to your partner is 0.104 of Q, so `pawns ≈ 9.6 ×
   advantage` gives knight 1.7, rook 1.5, queen 4.1 — a scale that is
   bughouse-native, monotone, and readable by anyone. This is a display
   change in `BughouseEval.score` / `calibration.to_score`, and it is the
   single highest-value improvement available. It needs a proper fit across
   more positions than the ten above before it ships.
3. **Surface the network's own WDL.** It exists (`wdl_out`), the engine
   already prints it under `policy`, and it is the only genuinely
   probabilistic number in the system. Nothing in the app or the MCP server
   reads it today.

And two rules that hold regardless:

- **Never compare a raw `score` across calls**, across `team`, across
  budgets, across `TimeAdvantage`, or against Stockfish. Two `advantage`
  values from calls with identical settings are comparable; two `score`
  values are not.
- **`compare` needs no calibration.** Every candidate is searched from the
  same seat under the same settings, so the offset cancels in the difference.
  The ranking is the answer.

## The protocol

UCI-shaped, but a bughouse decision is not a chess decision.

```
uci                           → option lines, then `info string backend …`, then uciok
isready                       → livenodes <N>, then readyok        (two lines, non-standard)
setoption name Team value white|black
setoption name TimeAdvantage value true|false
setoption name RequireMoveOn value none|A|B
setoption name MultiPV value N            ← not a `go` argument
position fen <fenA>|<fenB> [moves 1e2e4 2d7d5 …]
go [ponder] [movetime <ms>] [nodes <N>]   ← nodes wins if both; default 1000 ms
stop                                       ← always, to kill the permanent brain
policy                        → Value / WDL / plies, then per-board priors (debug, not UCI)
```

Move tokens are a board digit then plain UCI: `1e2e4` is e2e4 on board A,
`2P@f7` a drop on board B. Info lines:

```
info depth 12 [multipv 2] score cp -230 nodes 1500 nps 350 hashfull 3 tbhits 0 time 4283 pv (d2d4,pass) (d7d5,d2d4) …
bestmove (d2d4,pass) ponder (d7d5,d2d4)
```

`multipv` appears only when `MultiPV > 1`. PV entries are joint actions, up to
20 deep. Everything non-search goes through `info string …`, which both
parsers exclude by requiring `info ` *and* ` depth `.

Three rules the options carry that a chess engine has no place for:

| Option | Rule |
|---|---|
| `Team` | which colour we hold on board A; the partner holds the other on board B |
| `TimeAdvantage` | one bit: may our team sit? `is_double_sit_legal = teamHasTimeAdvantage && (boardAOnTurn != boardBOnTurn)` |
| `RequireMoveOn` | forbid passing on that board — use it when you want to know what to actually *play* there |

There is deliberately **no `Threads`**: `uci` never offers one, and setting it
is swallowed without changing the reported `workers N intra-op threads N`.

Two reader-side quirks worth knowing. The first `info` line of every search
reports the root's unvisited prior, `Q = −1`, which prints as cp **−16671**;
both parsers drop lines with `nodes <= 1` for this reason. And an illegal move
in a `position` command prints the FEN and the full legal-move list **to
stderr** and abandons the rest of the list — so a silently wrong position is
possible if you are not reading stderr.

## Where it runs

Four consumers, one engine, sharing only files.

| | |
|---|---|
| **Bughouse Lab** (desktop) | `lib/features/bughouse/` — `bughouse_engine.dart` owns the process, `bughouse_engine_protocol.dart` parses, `bughouse_eval.dart` calibrates, `bughouse_bundle.dart` unpacks the assets on first analysis |
| **`bughouse` MCP server** | `tools/mcp/bughouse/` — `engine.py` the UCI client, `board.py` the cross-board rule, `calibration.py` the offset, `analysis.py` the three question shapes (`analyse` / `compare` / `playout`), `tools.py` the schemas |
| **The browser** | `python/twic-position-finder/frontend/src/bughouse/` — the same C++ compiled to WASM, ORT-web for inference, one worker per core |
| **Engine matches** | [Bughouse matches](BUGHOUSE_MATCHES.md) — one process drives both teams |

`tools/mcp/bughouse/paths.py:locate()` finds the engine in this order:
`HIVEMIND_BIN`/`HIVEMIND_MODEL`/`HIVEMIND_LIB` → the desktop app's support
directory → `~/.local/share/chess-prep/bughouse/` → ungzip
`assets/bughouse/*.gz`. It never writes inside the app's directory.

On this machine, only the MCP server's copy exists — the Flutter app has never
unpacked its own:

```
~/.local/share/chess-prep/bughouse/
  hivemind-linux         3,729,088     (not stripped; RPATH from a GH Actions build)
  hivemind.onnx         54,415,625
  libonnxruntime.so.1   28,497,752
```

`assets/bughouse/` in the checkout is empty (gitignored). Refill it with
`python3 tools/fetch_assets.py --only bughouse`; checksums live in
`tools/assets.lock.json`.

### Budgets

Roughly **350 nodes/second** on this machine (ORT, CPU, FP32, batch 8, four
workers). Per search:

| nodes | time | good for |
|---|---|---|
| 500 | ~1.5 s | a smoke test |
| 1 500 | ~7 s | a calibrated reading of one position |
| 3 000 | ~9 s | a first pass over a wide candidate list |
| 8 000 | ~23 s | separating plausible candidates |
| 30 000 | ~90 s | deciding between the top two or three |

`analyse` runs **two** searches (both seats) unless you pass
`calibrate=false`; `compare` runs one *per candidate*. Nodes are reproducible
and are what to use for research; the search is not bit-exact, so the same
node count can still flip a move at low budgets.

## The two books

Two different databases, confusingly both called "the bughouse DB". They
share one thing: the position key, FNV-1a over the canonical dual FEN
truncated to four FEN fields per board (`tools/bughouse_db/poskey.py`,
mirrored in `bughouse_book.dart`).

**The FICS book** — statistics from real games. `tools/bughouse_db/fetch.py`
scrapes `bughouse-db.org/dl/export<year>.bpgn.bz2` (2005→present, ~2.1 GB,
kept compressed), `index.py` replays every game with `DualBoard` and
aggregates `edge` / `node` / `meta` tables into a ~177 MB SQLite
`bughouse_book.db`, which the **Flutter app** reads directly. Default depth is
16 half-moves across both boards, pruned at 2 games. BPGN gotchas worth
remembering: CRLF, and **Latin-1, not UTF-8**.

**The Hivemind eval book** — engine evaluations, modelled on chessdb.cn.
`tools/bughouse_db/hivemind_book.py` is the local producer: a resumable work
queue that searches positions with the real engine and, via `expand_fics()`,
follows the FICS book's *popularity* so the most-played lines get evaluated
first. `python/twic-position-finder/bughousedb.py` is the FastAPI server
behind `/api/bughousedb/*`, and the `/bughousedb` web page is a
**crowd-sourced front end for it**: a visitor's browser searches missing
positions with the WASM engine and uploads the result against a Turnstile-
gated ticket. The server runs no engine and rebuilds all move text from its
own move generation. Stored values are calibrated Q; served as
`cp = 543.17·atanh(Q)`.

### What exists on this machine: nothing

Both pipelines are code-complete and **no data has been generated here**:

| Artifact | Path | Status |
|---|---|---|
| data home | `~/.local/share/chess-prep/bughouse-db/` | does not exist |
| BPGN corpus (~2.1 GB) | `…/bughouse-db/corpus/export*.bpgn.bz2` | absent — no `*.bpgn*` anywhere on disk |
| FICS book (~177 MB built) | `…/bughouse-db/bughouse_book.db` | absent |
| Hivemind eval book | `…/bughouse-db/hivemind_book.db` | absent |
| server DB | `python/twic-position-finder/bughousedb.db` | absent (lives on the deployed API) |

So the `/bughousedb` site is serving whatever the deployed API has
accumulated from visitors, and there is no local seed corpus to compare it
against. To build one:

```
python3 -m bughouse_db fetch          # ~2.1 GB, kept bz2
python3 -m bughouse_db check --sha
python3 -m bughouse_db index          # → bughouse_book.db, ~177 MB
python3 -m bughouse_db status
python3 -m bughouse_db.hivemind_book run --expand-fics --width 4 --max-ply 12
python3 -m bughouse_db.hivemind_book push --url https://api.chessautoprep.com
```

The app's Databases screen tells the user to run the first two by hand; it
never downloads the book itself, and a machine without one is the normal case.

## The web payload

**43,936,825 bytes (41.9 MiB) before a visitor gets one evaluation.** The
breakdown, from the pinned lockfile and the npm tarball (the generated files
are gitignored and absent locally, but every size is pinned exactly):

| Artifact | Bytes | Share |
|---|---:|---:|
| `model-a18e2e9f3056-0.bin` | 16,777,216 | 38.2% |
| `model-a18e2e9f3056-1.bin` | 14,922,652 | 34.0% |
| `ort-wasm-simd-threaded.wasm` | 11,210,254 | 25.5% |
| `hivemind.wasm` | 926,743 | 2.1% |
| `hivemind.mjs` | 78,674 | 0.2% |
| `ort-wasm-simd-threaded.mjs` | 20,856 | 0.1% |
| `model.json` manifest | ~430 | — |

The page's own code — `app.ts`, `boards.ts`, `engine.ts`, `engine.worker.ts`,
`setup.ts`, the CSS, chessground — is **~0.2–0.5 MB, under 1% of the
total**. Do not spend time on it. 72% of the problem is the FP32 network and
25% is a stock ONNX Runtime build.

Also: each worker holds its **own full 54 MB of FP32 weights in RAM**
(`EnginePool` defaults to `cores / 2` workers). Only the 32 MB download is
shared, through Cache Storage `hivemind-model-v1` with SHA-256 revalidation.
On an 8-core laptop that is ~220 MB of weights resident.

### How it is built

`package.json` runs `tools/bughouse_web/prepare_assets.py` on every
`prebuild`/`predev`: it slices the gzipped network into 16 MiB chunks (to stay
under Cloudflare Pages' 25 MiB per-file limit), writes `model.json`, and
copies the ORT runtime out of `node_modules`. It copies the gzip **exactly as
downloaded** — no recompression, no `-9`, no quantisation, no ONNX graph
optimisation, no ORT-format conversion.

`tools/bughouse_web/build.py` compiles the C++ with Emscripten 4.0.15 only
when the bridge changes. The complete optimisation story is `-O3` and
`NDEBUG`. There is no `wasm-opt`, no `-Oz`, no `--strip-debug`, no
`--closure 1`, no `-flto` anywhere in the build path. Meanwhile `-fexceptions`
with `DISABLE_EXCEPTION_CATCHING=0` and `ASYNCIFY=1` both inflate
`hivemind.wasm` substantially — Asyncify is load-bearing (the C++ search
awaits ORT through it), exceptions may not be.

### Levers, ranked by bytes

| Lever | Now | After | Saved | Risk |
|---|---:|---:|---:|---|
| **int8 dynamic quantisation** of the 168 FP32 tensors | 31.7 MB gz | ~12–14 MB | **~18–20 MB** | strength loss — must be measured, see below |
| **Minimal/custom ORT WASM build** — only the ~20 op types this graph uses; `--minimal_build`, ORT-format model, drop training/webgl/jsep | 11.2 MB | ~3–5 MB | **~6–8 MB** | build complexity only; no strength risk |
| **Verify brotli on `application/wasm`** — `_headers` has no `/bughouse-engine/*` rule at all, so 12.1 MB of WASM relies on Cloudflare's defaults, unasserted | up to 12.1 MB raw | ~3.3 MB | up to ~8.8 MB (overlaps above) | none — cheapest win available |
| **Shrink or prune the 5 `body_spatial.*.se.body.0.weight` `[384,384,5]` tensors** (27% of weights) | 14.75 MB raw | — | up to ~8 MB gz | needs upstream; possibly an export artifact |
| **FP16 instead of FP32** | 54.4 MB raw | 27.2 MB raw | ~6–8 MB gz | ORT's WASM CPU EP casts back up, so inference gets *slower* |
| **`-Oz` + `wasm-opt -Oz --strip-debug` + `--closure 1`; `ASYNCIFY_ONLY` to narrow the transform; drop `-fexceptions` if possible** | 1.0 MB | ~0.5–0.65 MB | ~0.35 MB | small; verify the search still runs |
| **Hash the two WASM filenames and add `Cache-Control: immutable`** | 12.2 MB refetched/revalidated on later visits | 0 | 12.2 MB on repeat visits | none |

A realistic programme: **brotli headers** (an afternoon, ~8 MB, zero risk) →
**immutable caching on hashed WASM names** (an afternoon, fixes repeat
visits) → **minimal ORT build** (a day, ~7 MB) → **int8 quantisation gated on
a strength match** (the big one, ~19 MB).

That last one must be *measured*, not assumed. Policy/value networks are
often fine under int8 dynamic quantisation and occasionally fall apart, and
Hivemind already has the harness to tell you: `engine/scripts/` has
`run_strength_sweep.py` and the binary has a `tournament` subcommand, plus
this repo's own [engine matches](BUGHOUSE_MATCHES.md). Quantise, then run a
few hundred games quantised-vs-FP32 at a fixed node count before shipping it.
If int8 costs real strength, per-channel or int8-weights-only (keeping
activations FP32) is the usual middle ground.

Done in full, 41.9 MiB → roughly **15–18 MiB**, with the network still the
majority of it. Getting materially below that means a smaller network, which
is an upstream training question, not a packaging one.

## Where to push

Ordered by what looks most valuable per unit of effort, and separated by who
has to do the work.

**In this repo, no engine changes:**

1. **A readable scale.** Anchor the display on a pawn-in-hand (see [What to
   do about it](#what-to-do-about-it)). Fit it across a few dozen positions
   rather than the ten above.
2. **Surface WDL.** The network's own win/draw/loss exists and nothing reads
   it. It is the only calibrated probability in the system.
3. **Web payload**, in the order above.
4. **Build the books.** Both pipelines are complete and unrun here; the FICS
   book would also give the eval work a popularity-ordered queue and give the
   app its opening explorer.
5. **Note in the tooling**: python-chess is a hard dependency of the
   `bughouse` MCP server and was missing from this machine's `python3`, which
   is why the server reported `CONNECTION_CLOSED`. `python3 -m pip install
   --user python-chess`.

**Upstream, in the engine:**

6. **The missing joint-factor heads.** The ORT backend already looks for
   `jointfactors_a` / `jointfactors_b` and the shipped network does not
   provide them, so the search combines two *independent* per-board policies
   into a joint prior. In bughouse the boards are emphatically not
   independent — whether to take on A depends on what your partner needs on
   B. Training those heads is the most interesting modelling gap visible from
   here.
7. **The clock is one bit.** `TimeAdvantage` is a boolean, so the network
   cannot distinguish "ahead by two seconds" from "ahead by a minute", and it
   cannot see the diagonal at all. Given that this bit already dominates the
   evaluation, giving it a real-valued clock differential is likely the
   single largest strength gain available.
8. **The value range is badly allocated.** ~60% of the output range goes to
   one input bit, leaving material and structure to fight over the rest. That
   is what makes every eval look flat. Worth checking whether the self-play
   training distribution over-represents clock-decided games.
9. **`moves_left` is inert** — it reported ~70 plies for every position
   tested, from the opening to a queen-up middlegame. Either it is
   undertrained or the discount that consumes it is doing nothing.
10. **Speed.** 350 nodes/second means a 36,000-wide root gets a few hundred
    visits. A smaller network, int8 inference, or a larger batch would all
    convert directly into strength here, and the TensorRT backend exists
    upstream for anyone with the GPU.

## Rebuilding and repackaging

```
# unpack the vendored corresponding source to read it
tar xzf tools/bughouse_windows/hivemind-source.tar.gz

# desktop: package a local engine build into assets/bughouse/
python3 tools/fetch_assets.py --only bughouse --hivemind <hivemind-checkout>

# web: recompile the WASM bridge (only when bridge.cc/engine_web.cc change)
python3 tools/bughouse_web/build.py
python3 tools/bughouse_web/prepare_assets.py

# checks
python3 tools/mcp/test_bughouse.py              # fast, no engine
python3 tools/mcp/test_bughouse.py --engine      # adds the searches, ~1 min
scripts/ci.sh test test/features/bughouse
```

`bughouse_tournament_engine_test.dart` and the other engine-backed Dart tests
run only when `HIVEMIND_BIN` / `HIVEMIND_MODEL` are set, and skip otherwise.
The Windows build needs its `hivemind_ort.dll` loaded by absolute path — see
`tools/bughouse_windows/README.md` and `windows_loader_check.dart`.

## Reproducing the measurements

Everything in [Why everything reads 0.00](#why-everything-reads-000) came from
three short scripts against the installed binary: a calibrated material
ladder (`HivemindEngine` + `calibration.measure_offset`, 1,500 nodes, two
searches per row), a raw-network probe (the `policy` command, no search), and
a python-chess count of joint action widths. The construction that matters is
the difference between removing a piece and *transferring* it:

```python
def strip(fen, square):          # 'chess thinking': the piece vanishes
    b = CrazyhouseBoard(fen); b.remove_piece_at(chess.parse_square(square)); return b.fen()

def give(fen, symbol):           # what a capture really does: into the partner's hand
    b = CrazyhouseBoard(fen)
    b.pockets[chess.BLACK if symbol.islower() else chess.WHITE].add(
        chess.PIECE_SYMBOLS.index(symbol.lower()))
    return b.fen()

# we are white on A, our partner is black on B, so a captured black knight
# reaches the BLACK pocket on board B:
dual_fen = f"{strip(ITALIAN, 'c6')}|{give(ITALIAN, 'n')}"
```

If you repeat this, use a position that is identical on both boards. Symmetry
is what makes the true advantage 0 by construction, and without that anchor
you cannot tell a calibration error from an evaluation.
