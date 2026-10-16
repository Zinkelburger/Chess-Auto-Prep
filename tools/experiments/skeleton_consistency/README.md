# Skeleton-consistency experiment

Question: given only a user's *skeleton* lines (e.g. the Benko mainline
`1.d4 Nf6 2.c4 c5 3.d5 b5 4.cxb5 a6 5.bxa6 e6`), which scoring signal makes
the generator rediscover the "consistent" reply when White deviates
(`2.Nf3 c5`, `2.Nf3 c5 3.d5 b5`, `2.Bf4 c5`, `2.Bf4 c5 3.e3 Qb6`, `2.e3 c5`,
`4.Qxd4 Nc6`)?

Standalone Python; not part of the app or CI. Uses the app's own assets:
Stockfish (`~/.local/share/com.example.chess_auto_prep/stockfish-linux`),
`assets/maia3_simplified.onnx` + `assets/data/all_moves_maia3_reversed.json`
(Maia-3 encoding mirrors `tree_builder/src/maia.c`), and the public ChessDB
API. Everything is cached in `cache.db` next to the scripts.

```
python3 -m venv venv && ./venv/bin/pip install chess numpy onnxruntime
./venv/bin/python experiment.py    # round 1: engine / expectimax / transfer / reach / pawn-structure
./venv/bin/python experiment2.py   # round 2: transfer with distance cap, shadow distance, opponent-error
```

`onnxruntime` segfaults loading `maia3_simplified.onnx` with graph
optimizations on; `harness.py` disables them.

Raw tables are in `results_round*.txt`.

## Findings (2026-08)

The experiment scores candidate Black moves at seven White deviations, given
only the Benko skeleton (and, in a second pass, also
`2.c4 c5 3.Nf3 cxd4 4.Nxd4 e5`). Data: Stockfish 18, Maia-3 at 1800,
ChessDB evals. Sources of candidates: engine MultiPV-8, ChessDB top-8, Maia
top-6, and "transfer" moves (see below). Tolerance 40 cp vs ChessDB best.

| Position (expected) | engine | expectimax | transfer ≤5 | exact reach | pawn Jaccard |
|---|---|---|---|---|---|
| 2.Nf3 (…c5) | d5 ✗ | d5 ✗ | **c5** | c5 only with L1 | e6 ✗ |
| 2.Nf3 c5 3.d5 (…b5) | b5 | e6 ✗ | **b5** | b5 | e6 ✗ |
| 2.Nf3 c5 3.c4 (…cxd4) | cxd4 | d5 ✗ | cxd4 (with L1) | cxd4 (with L1) | — |
| 2.Bf4 (…c5) | c5 | Nh5 ✗ | **c5** | c5 | e6 ✗ |
| 2.Bf4 c5 3.e3 (…Qb6) | d5 ✗ | **Qb6** | d5 ✗ | d5 ✗ | e6 ✗ |
| 2.e3 (…c5) | e6 ✗ | d5 ✗ | **c5** | e6 ✗ | e6 ✗ |
| 4.Qxd4 (…Nc6) | Nc6 | d5 (!) | — | Nc6 | Nc6 |

Tally, both skeletons: engine 4/7 · expectimax 1/7 · transfer 6/7 · exact
reach 4/7 · pawn-structure 0–3/7.

Seven conclusions:

1. **Engine MultiPV alone can't even *see* the consistent move.** Stockfish
   d20 MultiPV-8 leaves …c5 out of its list both after 2.Nf3 and after 2.Bf4
   (where ChessDB has …c5 as *best*). A selector that draws our candidates
   only from MultiPV cannot fix this by scoring — **candidate generation must
   union in Maia's top moves, ChessDB's top moves, and skeleton-transfer
   moves.**
2. **"Transfer" is the metric that works, and it is trivially explainable.**
   Transfer = the move the skeleton plays at its *nearest* our-turn node,
   measured as number of differing squares, capped at 5, and only if it is
   within tolerance. After 2.Nf3 the nearest skeleton node is "after 2.c4"
   (4 squares differ) and it played …c5; likewise after 2.Bf4, 2.e3, and after
   2.Nf3 c5 3.d5 (→ …b5). The UI can say "like your line vs 2.c4". Without the
   cap it misfires (picked …a6 at 3.c4, distance 7).
3. **Exact-transposition reach is the right *second* signal** — it fires when
   the skeleton is rich (…c5 vs 2.Nf3 becomes ✓ once `3.c4 cxd4 4.Nxd4` is in
   the skeleton) and never fires wrongly.
4. **Expectimax finds the "challenging" moves the skeleton can't.** …Qb6 vs
   the London: static evals are d5 = 0, Qb6 = −1, e6 = −1 — indistinguishable —
   but Maia-weighted expectimax gives Qb6 **+22 cp** because 1800-level White
   goes wrong so often (4.Nc3?, 4.b3?, 4.Qc1). Same after 4.Qxd4: …d5!? is
   sound (−1) and 5.Nc3?? (35 % of replies, +1.45) / 5.Bg5? (11 %, +1.08) make
   it +62 cp in expectation. That's a genuine *trappy* alternative to the
   *common* …Nc6, and the reason to show both.
5. **"Coherence" — SAN-token itemsets or pawn-structure similarity to the
   goal — is dead.** Both rank …e6 "consistent" everywhere because the Benko
   goal position *contains* e6; a move name or a resemblance to the final
   structure says nothing about the position at hand. Dropped. (Transfer is a
   different thing: nearness to a *position where the user already decided*,
   not similarity of move names.)
6. **Explicit structure preferences work as a veto, not as a vote.** Scoring
   candidates by user-declared features over Maia-2300-likely positions four
   plies down (pawn on c5 +1, d6 +½, pawn on d5 −1, queens traded −½):

   | position | top by structure | the …d5 approach |
   |---|---|---|
   | 2.Nf3 | e6 1.00, c5 0.91, g6 0.84 | d5 **0.27** |
   | 2.Bf4 | e6 1.00, d6 0.95, c5 0.84 | d5 **0.00** |
   | 2.e3 | e6 1.00, c5 0.78 | d5 **0.02** |
   | 2.Bf4 c5 3.e3 | Qb6 1.00, e6 1.00 | d5 **−0.24** |
   | 4.Qxd4 | Nc6/e6/g6 0.00 | d5 **−0.14** (5.cxd5 Qxd5, queens off) |

   Every QGD-ish …d5 approach is killed decisively, but …c5-now and
   …e6-then-…c5 are indistinguishable because both reach c5 structures.
   So: structure preferences filter; transfer and expectimax select.
7. **Opponent Elo changes the "trappy" numbers a lot; report it.** At Maia
   1800 vs 2300: 4.Qxd4 …d5 expected gain +62 → +19 (5.cxd5 goes from 44 % to
   83 %); …Qb6 vs the London +22 → +4 (still top; 4.Nc3 61 % at 2300).
