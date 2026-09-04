# Bughouse matches

Give the engine a line and let it play the rest out, a dozen times over. The
games land on the lab's own two boards, so you click through them the way you
click through anything else here.

```
 a line ─▶ Bughouse Lab · Matches ─▶ Documents/bughouse_matches/<slug>/
                                      ├── games.bpgn   ← what tools/bughouse_db reads
                                      └── match.json    ← config + every game
```

This is the engine tournament's question asked about two boards, and it is
**not** the same question. There is one bughouse engine, so a match is not
"which binary is stronger" — it is *what happens after this line*.

## In the app

**Bughouse Lab → Matches**, beside "Edit position". Play the opening on the
boards (`1. d4 d5 2. Bf4`), press **New match**, and the games arrive as they
finish. Clicking a row replays that game on the two boards.

The panel leads with the number the feature exists to produce:

> **WHITE ON BOARD 1 SCORED** `5½/10` — 55% ±16 · 3W 5D 2L

That is the score of the *line*, counted from the same side every game
whichever participant is sitting there. It is deliberately not the crosstable's
Elo: with seats swapping, the crosstable measures the two engines against each
other and the opening's own bias cancels out of it exactly. The crosstable is
still there, shut, for when the two teams have different budgets.

### Where the games come from

Both teams are one Hivemind process, borrowed from the lab — entering the
Matches pane stops the analysis pump, because one process answers one question
at a time. A match keeps the engine if you wander off to another mode; the
games are waiting when you come back.

The two teams alternate: each is asked for a **joint action** (one decision
across both boards, in which sitting is a legal move), and a team with nothing
to move is skipped rather than searched. A captured piece crosses to the other
board with its colour intact, because the arbiter is `BughouseState.playMove` —
the same code the boards use. A game ends on checkmate on either board, on
stalemate, on both teams sitting four times running, or at the ply limit.

| | Options | Default |
|---|---|---|
| Start | The boards; a typed line; a dual FEN | The boards |
| Games | 2 – 50 | 10 |
| Think | 200 – 6400 nodes, per team | 800 nodes |
| Variety | Sampled plies, candidates, window | First 8 plies, top 3, within 0.05 |
| Seats | Swap every other game, or fixed | Swap |
| Clock stance | White on 1 ahead / level / Black on 1 ahead | Level |
| Ply limit | 80 – 400, filed as a draw | 240 |

**Variety is not optional in practice.** Hivemind's search is not bit-exact —
four workers race on batching, so the node count wobbles a percent either way —
but at the budgets a match uses that never reaches the move. Measured on
`1. d4 d5 2. Bf4`: identical answers over six runs at 800 nodes and twelve at
800 ms; only at ~300 ms does the wobble start flipping the choice, and what it
produces there is an under-searched engine rather than considered alternatives.
So without variety a ten-game match is one game shown ten times. For the
first N plies a team plays a move drawn from the engine's *own* MultiPV
shortlist, restricted to lines within a window of the best in the engine's
value (`q`, not the raw score — see `bughouse_eval.dart` for why the raw number
is not a scale you can subtract on). In that same position the top two lines
score *identically* — `(b8c6,d2d4)` and `(g8f6,d2d4)`, both cp −239 — which is
exactly the choice the sampler exists to make. So the games diverge early and
every divergence is a move the engine would defend.

Nodes rather than seconds, plus a stored seed, mean a match usually replays.
Usually, not always: a game is a chain of a hundred searches and the search is
not bit-exact, so one flip anywhere diverges the rest of it.

**Clock stance is fixed for the match, not simulated.** Teams take turns in
this model, so a simulated diagonal would never move — it would be "level"
dressed up as arithmetic. It is the one bit the engine reads, and it decides
whether sitting is legal at all.

### A typed line

`1. d4 d5 2. Bf4` goes on board 1; prefix a line `2:` (or `B:`, or `Board 2:`)
to give board 2 its own. Move numbers are decoration. Board 1 is played through
before board 2, which only matters when the opening contains a capture.

## The files

`games.bpgn` is **BPGN**, the format bughouse-db.org publishes and
`tools/bughouse_db/bpgn.py` already parses — `1A. d4 1B. e4 1a. d5`, board
letter and its case naming the mover, moves in the order they were played. A
`1-0` means what it means there: a win for the pair holding White on board A.
So a match exported here can be indexed into the same book as twenty-one years
of FICS games. PGN was never an option; it has nowhere to put the second board.

A match from a set-up position also carries a non-standard `SetUpDualFEN` tag,
without which it could not be replayed.

## Where the code lives

| | |
|---|---|
| `features/bughouse/models/bughouse_tournament.dart` | Config, participants, variety, the stored match, the opening score |
| `features/bughouse/services/bughouse_tournament_runner.dart` | The arbiter and the sampler; `replayBughouseGame` |
| `features/bughouse/services/bughouse_tournament_store.dart` | The directory and the BPGN writer |
| `features/bughouse/controllers/bughouse_tournament_controller.dart` | Runs one match, owns the list, drives the boards |
| `features/bughouse/widgets/bughouse_tournament_panel.dart` | The panel; `new_bughouse_match_dialog.dart` sets one up |
| `models/crosstable.dart`, `services/crosstable_builder.dart`, `widgets/crosstable_view.dart`, `widgets/match_games_table.dart` | Shared with [the engine tournament](ENGINE_TOURNAMENT.md) — standings, Elo ± interval, LOS, and the games table |

The standings maths and the games table are the engine tournament's, not a
second copy: `buildCrosstable` takes participant names and anything that can
say `whiteIndex`, `blackIndex` and a result, which a one-board game record and
a two-board one both can.

`bughouse_tournament_engine_test.dart` drives the real engine when
`HIVEMIND_BIN` / `HIVEMIND_MODEL` are set, and is skipped otherwise; everything
else in the runner is covered against a scripted fake.
