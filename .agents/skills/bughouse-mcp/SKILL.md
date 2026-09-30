---
name: bughouse-mcp
description: Analyse bughouse positions with Hivemind, the two-board neural-network engine, through the `bughouse` MCP server (`mcp__bughouse__*`) — set up a position from a line or dual FEN, get the best joint action and shortlist, rank candidate moves, list drops, or play both teams out. Use it whenever a task mentions bughouse, Hivemind, a two-board position, a dual FEN, sitting, passing, partner boards or reserves (including opening research such as "what does White play against 1.e4 Nf6 2.e5 Nd5?"), and when testing or editing `tools/mcp/bughouse/`.
---

# Bughouse MCP

Bughouse is a four-player, two-board team game. Three differences from chess
shape every tool:

* **A capture crosses boards.** A captured black knight goes to your partner,
  who plays the other colour on the other board and drops it as a *black*
  knight. (Crazyhouse keeps it on the same board in your colour, so a
  crazyhouse library alone gets bughouse wrong.)
* **A move is a joint action**, one decision per board: `(d2d4,pass)`.
  `pass` (sitting) is legal and often correct.
* **The clock is a rule.** Only a team ahead on the diagonal clock may sit on
  both boards, so `time_advantage` changes what is legal; `require_move_on`
  forbids passing on a board when you want the move to play there.

## The server

Registered in `.mcp.json` as `bughouse`; load a tool with
`ToolSearch "select:mcp__bughouse__analyse"`. From a shell:

```
M=.agents/skills/chess-prep-mcp/mcp_tools.py
python3 $M --server bughouse check
python3 $M --server bughouse describe compare
python3 $M --server bughouse call analyse moves="e4 Nf6 e5 Nd5" nodes=4000 multipv=3
```

| Tool | Answers | Engine |
|---|---|---|
| `status` | installed Hivemind build; does it start | starts it |
| `position` | play a line; both FENs, turn, reserves, per-board movetext | no |
| `legal_moves` | legal moves on one board, drops included (`drops_only=true`) | no |
| `analyse` | best joint action; `multipv` shortlist; readable `advantage` | yes, ×2 |
| `compare` | rank named candidates; each is played and answered at the same budget | yes |
| `playout` | engine plays both sides for a few joint actions | yes |

## Writing a position

Every tool takes a `dual_fen`, `moves`, or both (moves played on the FEN):
`moves = "e4 Nf6 e5 Nd5 B:d4 B:d5 B:c4 B:dxc4"`. Moves are tagged `A:` or
`B:`; untagged means board A. SAN or UCI; drops are `P@f7`. `team` is our
colour on board A (default white); our partner holds the other colour on B.

Call `position` first for long or capture-heavy lines — it is free and exact —
and check the movetext and all four reserves before spending engine time.

## Reading the score

**Read `advantage`, never `score`.** Hivemind prints `180·tan(1.56·Q)` of an
MCTS value that carries a large offset, read mostly off its `TimeAdvantage`
input (worth about ±0.58 Q, more than a queen). A balanced position reads
about −2.3 from both seats when neither team may sit.

The offset depends on the position — measured on exactly symmetric positions
(true value 0) it ranged from −0.31 to −0.67 Q:

| position (all equal) | raw `score` | offset (Q) |
|---|---|---|
| the opening | −2.29 | −0.575 |
| a symmetric Italian on both boards | −3.07 | −0.672 |
| a mirrored king-and-pawn ending | −0.93 | −0.337 |

So `analyse` searches from both seats: `offset = (q_ours + q_theirs)/2`,
`advantage = (q_ours − q_theirs)/2` (Q units, 0 is level), plus
`advantage_score` and `win_percent`. That costs two searches;
`calibrate=false` runs one, and then only the ordering is meaningful.

Scale of `advantage` on a symmetric middlegame:

| our team is up a… | piece gone from the board | piece in partner's hand |
|---|---:|---:|
| pawn | 0.079 | **0.104** |
| knight | 0.105 | **0.177** |
| rook | 0.051 | **0.155** |
| queen | 0.147 | **0.426** |

A piece in the partner's reserve is worth about three times one that merely
left the board. When writing a material-up position by hand, **transfer** the
piece: remove it from one board and add it to the partner's pocket. One
pawn-in-hand ≈ 0.10, so `advantage / 0.10` reads as pawns-in-hand; under 0.02
at a few thousand nodes is noise. [Hivemind, end to end](../../../docs/HIVEMIND.md)
explains the network, the search, and why `score` ≈ 2.8× `advantage`.

* **`compare` needs no calibration.** Candidates share one seat and settings,
  so the offset cancels in `loss_vs_best`. The ranking is the answer.
* **Never compare raw `score`** across calls, `team`, budgets,
  `time_advantage` or Stockfish. `advantage` values are comparable only under
  the same settings.

## Budgets

ONNX Runtime on CPU, roughly **350 nodes/s** here. Use `nodes` (reproducible)
for research; `movetime_ms` is wall-clock.

| nodes | per search | good for |
|---|---|---|
| 500 | ~1.5 s | smoke test |
| 3 000 | ~9 s | first pass over many candidates |
| 8 000 | ~23 s | separating plausible candidates |
| 30 000 | ~90 s | deciding between the top two or three |

`compare` runs one search per candidate (twelve at 8 000 ≈ 5 min); `analyse`
runs two. Start long sweeps in the background.

## Where the engine comes from

`paths.locate()` tries `HIVEMIND_BIN`/`HIVEMIND_MODEL`/`HIVEMIND_LIB`, the
desktop app's support directory, the server's own directory, then unpacks
`assets/bughouse/*.gz` from the checkout into
`~/.local/share/chess-prep/bughouse/`. It never writes into the app's
directory. `python3 tools/fetch_assets.py --only bughouse` downloads the
bundle; `--hivemind <checkout>` packages a local Hivemind build instead.
The same engine drives Bughouse Lab in the app; they share only files.

## Editing the server

```
python3 tools/mcp/test_bughouse.py             # no engine needed
python3 tools/mcp/test_bughouse.py --engine    # adds searches (~1 min)
```

`board.py` owns the cross-board rule and movetext, `engine.py` the UCI dialect,
`analysis.py` the question shapes, `tools.py` the schemas. The JSON-RPC
transport `tools/mcp/mcp_stdio.py` is shared with chess-prep; do not fork it.
