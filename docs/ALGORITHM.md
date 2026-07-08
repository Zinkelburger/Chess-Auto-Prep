# Expectimax Pipeline & Algorithm Reference

## Overview

Chess Auto-Prep builds repertoire trees using a best-first expectimax algorithm that combines engine evaluation, human move prediction (Maia), and database statistics to produce practical repertoire recommendations.

This document describes the **Flutter/Dart** generation pipeline in `lib/`. The native C `tree_builder` CLI (including `--resume`, `cli_args` persistence, db-explorer PGN ingest, and default thread count) is documented in [`tree_builder/ALGORITHM.md`](../tree_builder/ALGORITHM.md) and summarized under **External & non-Flutter components** in [`COMPONENT_MAP.md`](COMPONENT_MAP.md).

## Pipeline Stages

### 1. Candidate Generation

For each position in the BFS frontier:

**Our moves (configurable source):**
- **Maia (default):** Top-N moves ranked by Maia's predicted human probability. Ships with Flutter, no engine needed. Configured via `EngineSettings.candidateSourceOur`.
- **Stockfish:** MultiPV top-N moves by engine evaluation. Configured via `EngineSettings.stockfishTopN`.

**Opponent moves (configurable source):**
- **Maia (default):** Moves weighted by Maia predicted probability. Configured via `EngineSettings.candidateSourceOpp`.
- **Stockfish:** MultiPV opponent responses.
- **Lichess DB:** Opponent moves weighted by actual game frequency when DB data is available.

### 2. Evaluation Resolution (Eval Chain)

Evaluations are resolved through a multi-source chain, stopping at the first hit:

1. **Session cache** — in-memory hash of previously evaluated positions
2. **Local eval DB** (ChessDB direct file) — pre-downloaded centipawn evaluations
3. **Stockfish** — local engine evaluation at configured depth

Depth is configurable via `TreeBuildConfig.evalDepth` (default 14).

### 3. Frontier Tree Build (best-first by default)

```
start_fen
  └── our_move_1 (Maia top candidate)
  │     └── opp_response_1 (by DB frequency)
  │     └── opp_response_2
  └── our_move_2
        └── ...
```

**Frontier discipline (`bestFirst`, default on):** the build queue is a
max-heap on `searchPriority` — the node's reach probability (product of
opponent move probabilities along its path), discounted at non-incumbent
our-move alternatives. Popping always expands the frontier node that matters
most to the final repertoire, which makes the build an **anytime algorithm**:
at any node budget the tree is concentrated on the likeliest opponent lines,
and likely lines get searched deeper than rare sidelines. `bestFirst: false`
restores classic FIFO level-order BFS.

**Asymmetric our-move expansion (`ourAltDiscount`, default 0.25):** at an
our-move node the incumbent candidate (best eval at expansion time) inherits
the parent's priority; every alternative is multiplied by the discount, so
alternatives stay shallow unless the mainline budget runs out. Scheduling
only — `searchPriority` never feeds expectimax or selection.

**Opponent probability smoothing (`maiaPriorGames` = λ, default 30):** DB
frequencies are blended with Maia's policy as a Dirichlet prior:
`p = (count + λ·maiaP) / (N + λ)`. With thousands of games the data
dominates; at N = 0 this degrades continuously to pure Maia — replacing the
old hard DB→Maia fallback cliff. Maia-only moves absent from the DB get
prior-only mass. Skipped (saving the inference) when N ≥ 100λ. λ = 0
disables smoothing.

**Coverage guarantee (`coverMinProb`, default 0.05 — no silent holes):**
probability cutoffs decide how *deep* a line is searched, never whether a
popular reply *exists*.  Any opponent reply whose LOCAL (per-position)
smoothed probability clears the floor is forced into the tree even when its
reach probability is below `minProbability` or the mass/children budgets are
exhausted; the resulting our-turn node gets a **coverage-only expansion**
(one evaluated answer, no subtree).  An end-of-build sweep then answers any
remaining dangling our-turn leaf above the floor and removes the rest, so
the invariant holds: *no exported line ever ends on an unanswered opponent
move* — uncovered mass returns honestly to the expectimax tail term.
Selection and line extraction honor coverage-floored children below
`minProbability`.  0 disables (legacy behavior).

**Pruning rules:**
- `minProbability` (default 0.02): branches with cumulative probability below this threshold are not explored (also applied to `searchPriority` in best-first mode); overridden for existence by the coverage floor above
- `maxEvalLossCp` (default 80): our moves losing more than 80cp vs best are pruned
- `maxPly`: configurable tree depth (plies from root); our-turn leaves at the cap still receive a coverage answer one ply deeper
- `maxNodes`: hard cap on total tree nodes — with best-first this is the natural budget knob; the tree is always best-for-its-size (coverage answers are exempt)

### 3b. Final Verification Pass (`verifyFinal`, default on)

After selection, every chosen repertoire move is re-evaluated by Stockfish
at `verifyDepth` (0 = auto: `evalDepth + 6`, at least 20).  A move whose
deep eval loses more than `maxEvalLossCp` against the best deep-checked
sibling is **demoted**: the deep evals are written back into the tree,
expectimax and selection re-run, and the new spine is re-verified (up to 3
passes).  The exported repertoire therefore carries a guarantee: *no
selected move loses more than the threshold at the verification depth* —
instead of trusting the shallower build-time evals.  Verification changes
evals and selection only; it never adds or removes nodes, so the coverage
guarantee is preserved.  Implemented in
`lib/services/generation/repertoire_verifier.dart` (Dart) and
`repertoire_verify()` in `tree_builder/src/repertoire.c` (C,
`--verify`/`--no-verify`/`--verify-depth`).

### 3c. Preferred Setup — Consistency Bias (`setupMoves`, off by default)

The user can name the SAN moves of a system to play whenever it's sound
(e.g. `Be3 Qd2 f3 O-O-O h4 Nh3` for the 150 Attack vs the Pirc).  Two
mechanisms consume it:

1. **Candidate injection** (build): quiet system moves are often missing
   from Maia/MultiPV top-N, so any *legal* setup move is evaluated and
   added as a candidate — subject to the normal `maxEvalLossCp` window.
   Moves already played (or not legal) are skipped automatically, which
   gives move-order flexibility for free.
2. **Selection tie-break**: within `setupToleranceCp` (default 30,
   clamped to `maxEvalLossCp`) of the best child eval, a setup move is
   preferred over the plain expectimax pick; among several qualifying
   setup moves, the one with the best expectimax value wins.

Expectimax values are never modified — the bias only constrains the
argmax, exactly like `maxEvalLossCp` already does.  So when the opponent
makes consistency expensive (e.g. ...Ng4 hitting the Be3 bishop), every
setup continuation falls outside the tolerance and selection deviates to
the engine's answer; where the setup is fine, it's played.  The
verification pass deep-checks setup moves like any other selection.
Implemented in `lib/services/generation/setup_bias.dart` +
`RepertoireSelector._applySetupBias` (Dart) and `setup_moves_contain` /
`score_our_move_children` in `tree_builder/src/tree.c` (C, `--setup`,
`--setup-tolerance`).

### 4. Ease Calculation

**`myEase` (our moves, 0.0–1.0):**
How natural our chosen move is for a human to find. Computed from Maia's predicted probability for the move:
- If Maia says we'd play this move 80% of the time → myEase ≈ 0.80
- Only reasonable move (>200cp gap to 2nd best) → myEase = 1.0
- Engine-best but Maia-unlikely (<15%) → clamped to 0.5 max

**`ease` (opponent positions, 0.0–1.0):**
How easy it is for the opponent to find a good move at this position. Lower ease = opponent struggles more = better for us.

**`positionQuality` (unified, 0.0–1.0):**
- Our nodes: `positionQuality = myEase` (best repertoire child)
- Opponent nodes: `positionQuality = 1 - ease`

### 5. Expectimax Calculation

Minimax with probabilistic opponent moves:

```
V(our_node) = max over our children of V(child)
V(opp_node) = Σ P(child) × V(child)  for all opponent children
V(leaf)     = winProbability(evalCp)
```

`P(child)` is the Maia/DB frequency of the opponent's move. The result `V` is displayed as "% win" (practical win rate given human opponents).

### 5b. CPL Value Propagation (Trappy Mode)

When `SelectionMode.trappy` is selected, a parallel propagation computes `cplValue` — the total expected centipawn loss by the opponent downstream from each node:

```
cplV(leaf)     = 0
cplV(opp_node) = localCpl + Σ P(child) × cplV(child)
cplV(our_node) = max over eval-guarded children of cplV(child)
```

Where `localCpl` is the probability-weighted centipawn loss at a single opponent node (how much the opponent loses on average relative to their best move). The `cplValue` accumulates this across the whole subtree.

**Trappy selection** picks our moves to maximize `cplValue` instead of expectimax `V`. Build tolerances are automatically widened (matching the C `--traps` preset: `maxEvalLossCp` ≥ 100, `minEvalCp` relaxed to -100/-300 for White/Black) so the tree explores speculative territory where traps are more likely.

### 6. Line Quality (Playability)

**Geometric mean** of `positionQuality` across ALL nodes in a line (both sides):

```
lineQuality = exp(mean(log(clamp(q, 0.01, 1.0))))
```

Where `q` = `positionQuality` at each node. This correctly penalizes:
- Lines where our moves are hard to find (low myEase)
- Lines where opponent moves are easy to find (high ease → low 1-ease)

**Hard moves (bottleneck):** The position with the minimum `positionQuality` in a line, excluding the root position (not a move) and the first ply where it is our turn (opening choice). Surfaced with a warning when quality < 0.3. When the bottleneck falls on an opponent-move position, the label reads "easy for opponent" instead of "hard move."

### 7. Trap Detection

A position is a "trap" when:
- It's the opponent's turn
- A popular opponent move (high DB frequency or Maia probability) is significantly worse than the best move
- `trapScore = popularMoveProb × evalDiff / 1000`

After identifying a trap, the extractor also records the **refutation move** — our best reply after the opponent plays the popular blunder (repertoire move preferred, otherwise highest-eval child).

Traps are indexed by `TrapIndexService` for O(1) lookup by FEN and per-line queries.

### 8. Coverage Suggestion

`CoverageSuggestionService` identifies gaps in repertoire coverage:
1. Collect gaps: unaccounted opponent moves + too-shallow leaves
2. Resolve: walk tree to find continuations
3. Score: weighted combination of coverage impact, eval, ease, trap potential
4. Select: greedy set-cover to reach target coverage %

### 9. Coherence Analysis

`CoherenceService` uses FP-Growth to find frequent move patterns across repertoire lines, identifying structural consistency. Lines sharing common strategic motifs cluster together; outliers may need review.

## Configurable Parameters

| Parameter | Default | Location | Description |
|-----------|---------|----------|-------------|
| `depth` | 15 | EngineSettings | Stockfish eval depth |
| `easeDepth` | 15 | EngineSettings | Ease sub-evaluation depth |
| `evalDepth` | 14 | TreeBuildConfig | Tree build eval depth |
| `candidateSourceOur` | `maia` | EngineSettings | Our candidate source |
| `candidateSourceOpp` | `maia` | EngineSettings | Opponent candidate source |
| `stockfishTopN` | 3 | EngineSettings | Stockfish MultiPV count |
| `onTheFlyMaxDepth` | 5 | EngineSettings | On-the-fly BFS depth |
| `minProbability` | 0.02 | TreeBuildConfig | Pruning probability threshold |
| `maxEvalLossCp` | 80 | TreeBuildConfig | Max eval loss for our moves |
| `bestFirst` | `true` | TreeBuildConfig | Priority frontier (anytime) vs FIFO BFS |
| `ourAltDiscount` | 0.25 | TreeBuildConfig | Priority multiplier for non-incumbent our moves |
| `maiaPriorGames` | 30 | TreeBuildConfig | Dirichlet λ blending DB frequencies with Maia |
| `coverMinProb` | 0.05 | TreeBuildConfig | No-silent-holes floor on local opponent-reply probability |
| `verifyFinal` | `true` | TreeBuildConfig | Deep re-check of selected repertoire moves after selection |
| `verifyDepth` | 0 (auto) | TreeBuildConfig | Verification depth; 0 = max(evalDepth + 6, 20) |
| `setupMoves` | `''` | TreeBuildConfig | Preferred-setup SAN list (consistency bias); empty = off |
| `setupToleranceCp` | 30 | TreeBuildConfig | Max eval loss for a setup move to be preferred |
| `selectionMode` | `expectimax` | TreeBuildConfig | `expectimax`, `engineOnly`, `dbWinRateOnly`, `playable`, `trappy` |
| `maiaElo` | 1500 | EngineSettings | Maia model ELO level |

## Key Source Files

- `lib/services/generation/tree_my_ease.dart` — myEase, positionQuality, linePlayability
- `lib/services/generation/eca_calculator.dart` — expectimax calculation + CPL value propagation
- `lib/services/generation/trap_extractor.dart` — whole-tree trap line extraction
- `lib/services/tree_build_service.dart` — frontier tree building
- `lib/services/generation/frontier_queue.dart` — best-first/FIFO frontier
- `lib/services/generation/opponent_prior.dart` — λ-smoothing with Maia prior
- `lib/services/generation/repertoire_verifier.dart` — final deep-verification pass
- `lib/services/generation/setup_bias.dart` — preferred-setup parsing/matching
- `lib/services/on_the_fly_expectimax_service.dart` — on-the-fly computation
- `lib/features/browse/services/candidate_service.dart` — candidate move generation
- `lib/features/traps/services/trap_index_service.dart` — trap indexing and lookup
- `lib/features/coverage/services/coverage_suggestion_service.dart` — coverage gap suggestions
- `lib/services/coherence_service.dart` — FP-Growth coherence analysis
- `lib/features/eval_tree/services/eval_tree_line_metrics.dart` — line quality metrics
- `lib/core/generated_repertoire.dart` — single derived bundle (tree + FenMap + snapshot + traps)
