# Fast vs Pure Expectimax — findings

*2026-08-19. Harness: `test/benchmark/fast_vs_pure_benchmark.dart` driven by
`run_overnight.sh`; raw output under `results/ply8_d14/` (and `results/ply10_d14/`
when it completes). See `README.md` for what the metrics mean.  The compare reports
(`results/*/compare/`) are committed; trees, sandboxes and logs are gitignored.*

## Question

`TreeBuildConfig.searchAlgorithm == fast` (the default) is really two things:

1. **Best-first frontier** — pop the node with the highest reach priority
   (reach probability × 0.25 discount for non-incumbent our-move alternatives).
   Only matters when a build is stopped early; with no budget the finished
   tree is order-independent.
2. **Reach-zoned pruning** — hot (≥ 0.02) gets the full configured search,
   warm (≥ 0.002) loses one MultiPV line, cold gets MultiPV 2, half the
   eval-loss window, half the opponent fan-out, and only the incumbent plus ≤ 2
   alternatives within 30 cp get a subtree.  This is where the time goes.

The worry going in: the incumbent is chosen from the *shallow* engine eval at
expansion time, and then phase 2 compares incumbent vs. alternatives by
expectimax value.  Because expectimax at opponent nodes averages over
Maia-weighted *human* replies (which include mistakes), a deeper/wider subtree
accrues more "human error credit" than a thin one.  Hypothesis: Fast would
systematically confirm the shallow-eval incumbent, i.e. the asymmetry would
bias *which moves you learn*, not just how deep rare lines go.

## Setup

Real app pipeline, headless (flutter_tester + the app's extracted Stockfish +
Maia-3 ONNX), White from the start position, app defaults (`maxPly` 8,
eval depth 14, MultiPV 4, opp fan-out 4, Maia 2200, floor 1e-4, coverage floor
0.05) except `minEvalCp = −20` (see Caveats) and deep verify off.  Each
algorithm in its own sandbox with a fresh eval cache.  Phase 2 (ease,
expectimax, selection) exactly as `GenerationSessionController`.  6 engine
threads, niced, while the desktop app was itself running 10 engine workers
(so absolute times are contended; counts are not).

## Results — ply 8, depth 14

| | Fast | Pure | ratio |
|---|---|---|---|
| active build time | 24.9 min | 153.3 min | **6.2×** |
| engine MultiPV searches | 3,715 | 20,737 | 5.6× |
| Maia evals | 4,899 | 27,049 | 5.5× |
| nodes | 10,947 | 90,915 | 8.3× |
| nodes at ply 8 | 4,714 | 57,891 | 12× |
| root expectimax V | 0.5585 | 0.5576 | — |
| repertoire moves selected | 352 | 402 | — |

Our-move positions present in **both** trees with a selected move in both:
**171**.  (Pure has 18,599 our-move positions Fast never builds; 3,389
shared our-move positions are unexpanded leaves in Fast — the alternatives
the gate left as evaluated leaves.)

| zone (Pure reach) | nodes | reach mass | agree | regret / reach | max regret | disagreements: Fast pick is engine-best | disagreements: Pure pick is engine-best |
|---|---|---|---|---|---|---|---|
| all | 171 | 3.24 | 82.5% | 0.0006 | 0.019 | 3 / 30 | 24 / 30 |
| hot | 25 | 2.68 | 84.0% | 0.0006 | 0.019 | 2 / 4 | 1 / 4 |
| warm | 75 | 0.51 | 82.7% | 0.0007 | 0.008 | 1 / 13 | 10 / 13 |
| cold | 71 | 0.06 | 81.7% | 0.0013 | 0.018 | 0 / 13 | 13 / 13 |

Regret = Pure's expectimax value of Pure's move − Pure's value of Fast's move,
in win-probability units, weighted by Pure's reach probability.  Worst case
0.019 (≈ 2 pp) at `1.e4 d6`: Pure picks 2.c3 (V .597, eval +20), Fast 2.d4
(V .578, eval +52).  All other disagreements are ≤ 1 pp; most are < 0.5 pp.

## What we learned

1. **Fast is ~6× cheaper at equal depth and the result is practically the
   same.**  Root V differs by 0.001; reach-weighted regret is ~0.0006 per unit
   reach; hot-zone agreement 84 %.  No repertoire-relevant decision moved by
   more than 2 pp of win probability.

2. **The incumbent-confirmation bias did not show up.**  At the 30
   disagreements Fast's pick was the engine-best move only 3 times; *Pure's*
   was 24 times.  Fast deviates from engine-best on expectimax grounds
   *more* than Pure, not less.  Whether Fast's pick had a deeper subtree than
   its siblings did not predict the choice (23 / 126).  The asymmetry argument
   is correct in the abstract but at these depths its magnitude is below the
   noise floor.

3. **What disagreement actually is**: (a) engine noise — multithreaded
   Stockfish and different MultiPV widths mean the two trees hold different
   evals for the same position, so even "engine best" flips (`1.e4 c5`: Pure
   Nf3 +42, Fast Ne2 +33); (b) genuine near-ties (ΔV < 0.005).  Running Pure
   twice would show a similar disagreement rate — worth measuring if a tighter
   bound is ever needed.

4. **Where Fast spends less, it mostly spends nothing.**  It is not making
   worse choices in rare lines; it is not making choices there at all (leaf
   alternatives, unbuilt cold subtrees).  That is the coverage-vs-cost trade
   the design intends, and the coverage floor still guarantees an answer to
   every opponent move ≥ 5 %.

5. **Side finding — a product bug.**  With `relativeEval` and the default
   `minEvalCp = 0`, root-eval noise can make every root child "eval too low"
   (root +47, best child +30 at depth 8) and the build returns a 1-node tree.
   Hit in ~half of the shallow smoke runs.  The build should never prune *all*
   children of the root (or of any node that owes a coverage answer).

## Caveats

- 171 shared decision points at ply 8 is a modest sample; the ply-10 pair
  (Fast: 27.6k nodes, 9.9k searches, 56.8 min active, root V 0.5656; Pure
  running under a 4 h cap) will widen it and give the bias more room to
  appear.  Conclusions above should be re-checked against
  `results/ply10_d14/compare/compare.md`.
- Absolute times were measured with a contended CPU; use the search/Maia
  counts for the cost ratio.
- Only the expectimax selection mode, White, start position, one Maia Elo.
- `minEvalCp = −20` differs from the app default (0) for both algorithms.

## Recommendation

Keep Fast as the default.  If anything, the experiment argues for *more*
trust in the zoned pruning than the docs currently express.  Two cheap
follow-ups if the ply-10 run is consistent: (a) a root/coverage guard against
the all-children-pruned case; (b) a Pure-vs-Pure rerun to put a number on the
engine-noise floor so future comparisons can tell signal from noise.
