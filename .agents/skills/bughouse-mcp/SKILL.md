---
name: bughouse-mcp
description: Analyse bughouse positions with Hivemind, the neural-network two-board engine, through the `bughouse` MCP server (`mcp__bughouse__*`) — set a two-board position up from a line or a dual FEN, get the engine's best joint action and its shortlist, rank candidate moves against each other, list the drops a chess eye misses, or let the engine play both teams out. Reach for it whenever a task mentions bughouse, Hivemind, a two-board position, a dual FEN, sitting, passing, partner boards or reserves — including opening research ("what does White play against 1.e4 Nf6 2.e5 Nd5?"), and whenever you need to test or edit the server itself under `tools/mcp/bughouse/`.
---

# Bughouse MCP

Bughouse is not chess with extra rules. It is a four-player, two-board team
game, and three differences shape every tool here:

* **A capture crosses boards.** Take a black knight and you hand it to your
  partner, who sits on the *other* board playing the opposite colour and drops
  it as a *black* knight. The colour survives; the board changes. (Crazyhouse
  does the opposite — same board, your colour — which is why a crazyhouse
  library alone gets bughouse wrong.)
* **A move is a *joint* action.** The engine answers with one decision per
  board, `(d2d4,pass)`, and `pass` — sitting, deliberately not moving — is a
  legal and often correct half.
* **The clock is a rule, not a statistic.** Only a team ahead on the *diagonal*
  clock may sit on both boards, so `time_advantage` changes what is legal, and
  `require_move_on` forbids passing on one board when you want to know what to
  actually play there.

## The server

Registered in `.mcp.json` as `bughouse`; tools appear as `mcp__bughouse__*`.
Load one with `ToolSearch "select:mcp__bughouse__analyse"`. From a shell:

```
python3 .Codex/skills/chess-prep-mcp/mcp_tools.py --server bughouse check
python3 .Codex/skills/chess-prep-mcp/mcp_tools.py --server bughouse list
python3 .Codex/skills/chess-prep-mcp/mcp_tools.py --server bughouse describe compare
python3 .Codex/skills/chess-prep-mcp/mcp_tools.py --server bughouse call analyse moves="e4 Nf6 e5 Nd5" nodes=4000 multipv=3
```

| Tool | What it answers | Engine |
|---|---|---|
| `status` | which Hivemind build is installed, and does it start | starts it |
| `position` | play a line, read both boards back: FENs, turn, reserves, each board's own movetext | no |
| `legal_moves` | every legal move on one board, drops included (`drops_only=true` for just the reserves) | no |
| `analyse` | the best joint action here, with `multipv` giving the engine's ranked shortlist from the same search — and a readable `advantage`, which costs a second search | yes, ×2 |
| `compare` | rank *named* candidate moves: each is played, the opponent answers it under the same budget, lowest score for them wins | yes |
| `playout` | the engine on both sides for a few joint actions, so you see the piece flow a line really produces | yes |

## Writing a position

Every tool takes the position the same way: a `dual_fen`, a list of `moves`,
or both (the moves are played on top of the FEN).

```
moves = "e4 Nf6 e5 Nd5 B:d4 B:d5 B:c4 B:dxc4"
```

Moves are board-tagged, `A:` or `B:`, and an untagged move means board A — a
line of ordinary opening moves is the common case. SAN or UCI both parse;
drops are `P@f7`. `team` says which colour we hold on board A (default white);
our partner always holds the other colour on board B.

`position` is free and exact — call it first when a line is long or has
captures in it, and check the movetext and the four reserves before spending
minutes of engine time on the wrong position.

## Reading the score

**Read `advantage`, never `score`.** Hivemind reports `180·tan(1.56·Q)` of an
MCTS value, and that value is not an evaluation of the position: it carries a
large offset the network reads mostly off its `TimeAdvantage` input — the bit
alone is worth about ±0.58 of Q, more than a queen. So a *balanced* position
reads about −2.3 from both seats when neither team may sit.

The offset is **not a constant**. It is what the clock advantage is worth *in
this position*, so it is large in a piece-rich opening and small in a bare
endgame. Measured across exactly symmetric two-board positions — identical FEN
on both boards, so the true value is 0 — it ranged from −0.31 to −0.67 of Q:

| position (all dead equal) | raw `score` | offset (Q) |
|---|---|---|
| the opening | −2.29 | −0.575 |
| a symmetric Italian on both boards | −3.07 | −0.672 |
| a mirrored king-and-pawn ending | −0.93 | −0.337 |

So it is measured, not assumed. `analyse` searches the position from *both*
seats and takes `offset = (q_ours + q_theirs)/2`, leaving
`advantage = (q_ours − q_theirs)/2`. That is what `advantage` (Q units, 0 is
level), `advantage_score` (the same put back on the engine's scale) and
`win_percent` are. **This makes `analyse` cost two searches**; pass
`calibrate=false` for one, and then read only the ordering.

A rough sense of scale in `advantage`: a queen is about **0.14**, and anything
under **0.02** at a few thousand nodes is noise.

Two things follow:

* **`compare` needs no calibration.** Every candidate is searched from the same
  seat under the same settings, so they share one offset and it cancels in a
  difference — which is what `loss_vs_best` is. The ranking is the answer.
* **Never compare a raw `score` across calls**, across `team`, across budgets,
  across `time_advantage`, or against Stockfish. Two `advantage` values from
  calls with the same settings are comparable; two `score` values are not.

## Budgets

The bundled build is ONNX Runtime on CPU: roughly **350 nodes/second** on this
machine. `nodes` is reproducible and is what to use for research; `movetime_ms`
is wall-clock. Rough costs per search:

| nodes | time | good for |
|---|---|---|
| 500 | ~1.5 s | a smoke test |
| 3 000 | ~9 s | a first pass over a wide candidate list |
| 8 000 | ~23 s | separating plausible candidates |
| 30 000 | ~90 s | deciding between the top two or three |

`compare` runs one search *per candidate*, so twelve candidates at 8 000 nodes
is about five minutes. `analyse` runs **two** — the position from both seats,
which is what makes its `advantage` readable — so double the table above, or
pass `calibrate=false` when the ordering is all you want. Start a long sweep in
the background and do something else.

## Where the engine comes from

`paths.locate()` looks, in order, at `HIVEMIND_BIN`/`HIVEMIND_MODEL`/
`HIVEMIND_LIB`; the desktop app's support directory (the app unpacks the bundle
on its first analysis); this server's own directory; and finally
`assets/bughouse/*.gz` in the checkout, which it unpacks into
`~/.local/share/chess-prep/bughouse/`. It never writes inside the app's
directory. If nothing is installed, `python3 tools/fetch_bughouse.py` downloads
the bundle for this platform; `--hivemind <checkout>` packages a local Hivemind
build instead, which is what you want while working on the engine itself.

The same engine drives **Bughouse Lab** in the app (`lib/features/bughouse/`,
`/drive` to look at it). The two share only files; either can run alone.

## Editing the server

```
python3 tools/mcp/test_bughouse.py             # fast: no engine needed
python3 tools/mcp/test_bughouse.py --engine    # adds the searches (~1 min)
```

`board.py` owns the cross-board rule and the per-board movetext, `engine.py`
the UCI dialect, `analysis.py` the three question shapes, `tools.py` the
schemas. The JSON-RPC transport is `tools/mcp/mcp_stdio.py`, shared with the
chess-prep server — do not fork it.
