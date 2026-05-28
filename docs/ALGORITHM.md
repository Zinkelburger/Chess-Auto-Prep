# Expectimax Pipeline & Algorithm Reference

## Overview

Chess Auto-Prep builds repertoire trees using a BFS-based expectimax algorithm that combines engine evaluation, human move prediction (Maia), and database statistics to produce practical repertoire recommendations.

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
3. **Lichess API** — cloud evaluations from Lichess opening explorer
4. **Stockfish** — local engine evaluation at configured depth (default: 15)

Depth is configurable via `EngineSettings.depth` (default 15, lowered from 20 for speed).

### 3. BFS Tree Build

```
start_fen
  └── our_move_1 (Maia top candidate)
  │     └── opp_response_1 (by DB frequency)
  │     └── opp_response_2
  └── our_move_2
        └── ...
```

**Pruning rules:**
- `minProbability` (default 0.02): branches with cumulative probability below this threshold are not explored
- `maxEvalLossCp` (default 80): our moves losing more than 80cp vs best are pruned
- `maxPly`: configurable tree depth (plies from root)
- `maxNodes`: hard cap on total tree nodes

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

### 6. Line Quality (Playability)

**Geometric mean** of `positionQuality` across ALL nodes in a line (both sides):

```
lineQuality = exp(mean(log(clamp(q, 0.01, 1.0))))
```

Where `q` = `positionQuality` at each node. This correctly penalizes:
- Lines where our moves are hard to find (low myEase)
- Lines where opponent moves are easy to find (high ease → low 1-ease)

**Hard moves (bottleneck):** The position with the minimum `positionQuality` in a line. Surfaced with a warning when quality < 0.3.

### 7. Trap Detection

A position is a "trap" when:
- It's the opponent's turn
- A popular opponent move (high DB frequency or Maia probability) is significantly worse than the best move
- `trapScore = popularMoveProb × evalDiff / 1000`

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
| `evalDepth` | 15 | TreeBuildConfig | Tree build eval depth |
| `candidateSourceOur` | `maia` | EngineSettings | Our candidate source |
| `candidateSourceOpp` | `maia` | EngineSettings | Opponent candidate source |
| `stockfishTopN` | 3 | EngineSettings | Stockfish MultiPV count |
| `onTheFlyMaxDepth` | 5 | EngineSettings | On-the-fly BFS depth |
| `minProbability` | 0.02 | TreeBuildConfig | Pruning probability threshold |
| `maxEvalLossCp` | 80 | TreeBuildConfig | Max eval loss for our moves |
| `maiaElo` | 1500 | EngineSettings | Maia model ELO level |

## Key Source Files

- `lib/services/generation/tree_my_ease.dart` — myEase, positionQuality, linePlayability
- `lib/services/generation/eca_calculator.dart` — expectimax calculation
- `lib/services/tree_build_service.dart` — BFS tree building
- `lib/services/on_the_fly_expectimax_service.dart` — on-the-fly computation
- `lib/services/candidate_service.dart` — candidate move generation
- `lib/services/trap_index_service.dart` — trap indexing and lookup
- `lib/services/coverage_suggestion_service.dart` — coverage gap suggestions
- `lib/services/coherence_service.dart` — FP-Growth coherence analysis
- `lib/features/eval_tree/services/eval_tree_line_metrics.dart` — line quality metrics
