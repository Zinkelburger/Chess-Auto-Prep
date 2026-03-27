# Repertoire Generation Algorithm — Design Document

## Overview

The tree builder generates chess opening repertoires through a single
interleaved DFS that builds the tree and evaluates positions simultaneously:

1. **Building** the move tree by querying Lichess Explorer and Stockfish
   together — engine MultiPV for our-move candidates, Lichess DB for opponent
   responses, with eval-window pruning at every node
2. Computing **ease scores** (legacy compatibility with the Flutter app)
3. Computing **ECA (Expected Centipawn Advantage)** — a win-probability-delta
   metric estimating how much win probability opponents hand us on average
4. **Selecting** repertoire moves using a blended score of eval and ECA
5. Extracting complete lines and exporting to JSON/PGN

---

## Pipeline Stages

The CLI runs five stages (`[0/4]` through `[4/4]`).

### Stage 0: Database + Engine Initialization

Open (or create) the SQLite database for caching explorer responses, engine
evaluations, and ease scores. Locate and start the Stockfish engine pool
(required for building).

### Stage 1: Build Opening Tree (Interleaved)

A single DFS builds the tree by interleaving Lichess explorer queries with
Stockfish evaluation. At each node, the algorithm dispatches based on whose
move it is:

#### Our-Move Nodes (Engine-Driven)

1. **Stockfish MultiPV (tapering)** — evaluate the position with a
   depth-dependent number of lines. At the root, `our_multipv_root`
   (default 10) lines cast a wide net to discover every viable opening
   move. This tapers linearly to `our_multipv_floor` (default 2) by
   `taper_depth` (default 8 ply), where only the top engine moves matter.
2. **Eval filter** — discard candidates more than `max_eval_loss_cp` (default
   50) worse than the best line. All surviving lines become children — no
   separate candidate cap. The MultiPV count *is* the exploration budget.
3. **Lichess enrichment** — query the Lichess explorer for this position to
   get SAN notation, win rates, and game counts (enrichment only — Stockfish
   drives the branching decision).
4. **Create children** with evaluations set inline, cached to the DB.
5. **Recurse** into each child.

The MultiPV taper at each depth:

| Depth (ply) | MultiPV | Typical surviving candidates |
|-------------|---------|----------------------------|
| 0 (root)    | 10      | 4–7 (many near-equal moves) |
| 2           | 8       | 3–5                         |
| 4           | 6       | 2–4                         |
| 6           | 4       | 2–3                         |
| 8+          | 2       | 1–2                         |

#### Opponent-Move Nodes (Lichess-Driven)

1. **Lichess Explorer** — query for human move frequencies.
2. **Maia fallback** — if the explorer returns no data and cumulative
   probability is above `maia_threshold`, predict human moves with the Maia
   neural network.
3. **Branching caps (tapering)** — add children until either
   `opp_max_children` (default 6) moves are added, or the depth-dependent
   mass target is reached. The mass target tapers linearly from
   `opp_mass_root` (default 95%) at the root to `opp_mass_floor` (default
   50%) at `taper_depth` and beyond. Near the root this covers almost every
   played response (including 2–5% sidelines worth preparing against); deeper
   in the tree it focuses on only the most popular replies.
4. **Engine top-1** — run Stockfish on this position. If the engine's best
   move is not already a child, add it (as a low-probability entry). This
   ensures the tree accounts for the opponent's objectively best play, not
   just their popular play.
5. **Batch evaluate** all children that lack evaluations (checks DB cache
   first, then Stockfish). Evals are cached to DB.
6. **Recurse** into each child.

The mass target taper at each depth:

| Depth (ply) | Mass target | Typical opponent children |
|-------------|-------------|--------------------------|
| 0           | 95%         | 5–6                      |
| 2           | 84%         | 4                        |
| 4           | 73%         | 3                        |
| 6           | 61%         | 2–3                      |
| 8+          | 50%         | 1–2                      |

#### Eval-Window Pruning

At every node, before branching:
- Check if the node has an engine evaluation (most nodes do — set by their
  parent during creation).
- If `eval_for_us <= min_eval_cp` — position is too bad, stop.
- If `eval_for_us >= max_eval_cp` — position is already won, stop studying.

This prunes the tree inline as it's built, avoiding wasteful exploration of
positions outside the eval window.

#### Key Design Principles

**Cumulative probability only decreases on opponent moves.** When it's our
turn, every child inherits the parent's full cumP (we choose what to play).
When it's the opponent's turn, `child.cumP = parent.cumP × child.move_probability`.
This ensures sidelines get explored just as deeply as the mainline — tree
depth depends on how likely the *opponent* is to reach each position.

**Resume support.** If an output file already exists, the tree is loaded and
building resumes from unexplored leaves. Nodes with children or marked
`explored` are skipped. Interrupted builds are saved on SIGINT.

**Evals are cached.** Every evaluation is stored in SQLite so re-runs skip
already-evaluated positions. The DB also caches Lichess explorer responses.

#### Maia Neural Network Fallback

When the Lichess explorer returns no data at an opponent-move node:
- Maia model was found (auto-detected from `./maia_rapid.onnx` or `../assets/maia_rapid.onnx`, or explicit `--maia-model <path>`)
- `node.cumulative_probability >= maia_threshold` (default 0.01 = 1%)
- Maia moves below `maia_min_prob` (default 0.02 = 2%) are discarded

### Stage 2: Generate Repertoire (Ease + ECA + Selection)

After the tree is built with all nodes evaluated:

1. **Load DB evals** — for trees loaded from JSON, sync DB-cached evals
   into TreeNode structs.
2. **Ease calculation** — compute ease scores from node evaluations (see
   Ease Metric below).
3. **ECA calculation** — compute local trickiness and accumulated ECA
   (see ECA section below).
4. **Move selection** — traverse the tree top-down, selecting one move at
   each our-move node using the blended score.
5. **Line extraction** — extract complete repertoire lines from the
   selected moves.

### Stage 3: Trap Detection (Optional)

Enabled with `--traps`. Finds opponent positions where the most popular move
is significantly worse than the best move. The "trap score" measures how much
eval the opponent gives away by playing the popular move, weighted by
popularity.

### Stage 4: Export

Save results to JSON tree, repertoire JSON, and optionally PGN.

---

## Ease Metric

Ease measures how likely the side to move is to find a good move. It's
computed from node evaluations (no DB lookups needed — evals are on nodes
from the build phase).

```
q(cp) = 2 / (1 + e^(-0.004 × cp)) - 1         # sigmoid, maps cp to [-1, 1]
q_max = q(best child eval, from our perspective)

weighted_regret = Σ(prob_i^1.5 × max(0, q_max - q(child_i eval)))
ease = 1 - (weighted_regret / 2)^(1/3)
```

Children with `move_probability < 0.01` (1%) are excluded.

---

## ECA: Expected Centipawn Advantage (Win-Probability-Delta Units)

### Concept

ECA measures: "If I play this line, how much win probability will my opponent
hand me on average due to suboptimal play?"

Everything is measured in win-probability-delta units [0, ~0.5] from the
bottom of the tree to the top. One number per node, one formula, no
normalization.

### Win Probability Function

The Lichess-calibrated sigmoid:

```
wp(cp) = 1 / (1 + e^(-0.00368208 × cp))
```

Maps centipawns to [0, 1] from White's perspective. A 50cp blunder near
equality (0.50 → 0.55 wp) contributes ~0.046 wp-delta. The same 50cp
blunder when already up 300cp (0.75 → 0.77 wp) contributes only ~0.016.

### Local Trickiness (local_cpl)

```
wp_for_mover(child) = 1 - wp(child.engine_eval_cp)

best_wp   = max(wp_for_mover(child) for all children with evals)
local_cpl = Σ(prob_i × max(0, best_wp - wp_for_mover(child_i)))
            for children with move_probability >= 0.01
```

### Bottom-Up Accumulation

Post-order DFS with the full `RepertoireConfig` for filter consistency:

- **Leaf nodes**: `accumulated_eca = γ^d × local_cpl`
- **Opponent-move nodes**:
  `accumulated_eca = γ^d × local_cpl + Σ(prob_i × child_i.accumulated_eca)`
- **Our-move nodes**: Select the child using the blended score
  `α × wp_us(child.eval) + (1-α) × child.accumulated_eca`, with eval-guard
  and max-eval-loss filters applied. Propagate the selected child's
  `accumulated_eca` upward.

A shared helper `score_our_move_children()` is used by both accumulation
and selection to guarantee consistency.

### Move Selection

At our-move nodes during the top-down traversal:

```
for each child (after eval-guard and max-eval-loss filtering,
                with "if all fail, re-score all" fallback):
    score = α × wp_us(child.eval) + (1-α) × child.accumulated_eca

select argmax(score)
```

This is **identical** to what the accumulation phase computed.

At opponent-move nodes, all children above the probability threshold are
recursed into. The DFS also stops at eval-window boundaries.

### Line Extraction

Follow selected repertoire moves through the tree. At our-move nodes, only
the selected move is followed. At opponent-move nodes, all likely responses
are followed. Lines always end with the repertoire side's move.

---

## Parameters

### Tree Building — Our Moves (Engine-Driven)

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `our_multipv_root` | `--our-multipv-root` | 10 | MultiPV at root (explore broadly) |
| `our_multipv_floor` | `--our-multipv-floor` | 2 | MultiPV floor (deep positions) |
| `taper_depth` | `--taper-depth` | 8 | Ply at which both tapers bottom out |
| `max_eval_loss_cp` | `--max-eval-loss` | 50 | Candidates must be within this of best |

### Tree Building — Opponent Moves (Lichess-Driven)

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `opp_max_children` | `--opp-max-children` | 6 | Max opponent responses per position |
| `opp_mass_root` | `--opp-mass-root` | 0.95 | Mass target at root (explore broadly) |
| `opp_mass_floor` | `--opp-mass-floor` | 0.50 | Mass target floor (deep positions) |
| `min_games` | `-g` | 10 | Minimum Lichess games to include a move |
| `ratings` | `-r` | 2000,2200,2500 | Lichess rating buckets |
| `speeds` | `-s` | blitz,rapid,classical | Time controls |

### Tree Building — General

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `min_probability` | `-p` | 0.0001 (0.01%) | Prune branches below this cumulative probability |
| `max_depth` | `-d` | 30 ply | Maximum tree depth |
| `eval_depth` | `-e` | 20 | Stockfish search depth per position |
| `num_threads` | `-t` | 4 | Parallel Stockfish engines |

### Eval Window Pruning

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `min_eval_cp` | `--min-eval` | W: 0, B: -200 | Stop if our eval drops below this |
| `max_eval_cp` | `--max-eval` | W: 200, B: 100 | Stop if our eval exceeds this |
| `relative_eval` | `--relative` | off | Make thresholds relative to root eval |

### Maia Fallback

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `maia_model` | `--maia-model` | auto-detect | Path to `maia_rapid.onnx` |
| `maia_elo` | `--maia-elo` | 2000 | Elo for predictions (1100–2100) |
| `maia_threshold` | `--maia-threshold` | 0.01 (1%) | Min cumProb to trigger fallback |
| `maia_min_prob` | `--maia-min-prob` | 0.02 (2%) | Skip moves below this probability |

### ECA & Move Selection

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `depth_discount` | `--depth-decay` | 1.0 | Depth discount for ECA |
| `eval_weight` | `--eval-weight` | 0.40 | Blend ratio (0 = trickiness, 1 = eval) |
| `eval_guard_threshold` | `--eval-guard` | 0.35 | Min win probability to consider a move |

### What Each Parameter Does Intuitively

- **`our_multipv_root / our_multipv_floor`**: "How many engine moves to
  consider?" At the root, cast a wide net (10 lines) to discover every
  viable opening move. Deep in the tree, only ask for the top 2. The eval
  filter further narrows actual children — MultiPV is the exploration
  budget, and `max_eval_loss_cp` decides who survives.

- **`opp_mass_root / opp_mass_floor`**: "How much of the opponent's
  probability mass to cover?" At the root, cover 95% — prepare for almost
  everything, including 2–5% sidelines. Deep in the tree, 50% means only
  the top 1–2 replies. Combined with cumulative-probability pruning, this
  focuses deep branches naturally.

- **`taper_depth`**: "When does the tree shift from broad exploration to
  focused depth?" Both the MultiPV taper and mass target taper reach their
  floor values at this depth. Default 8 ply = 4 moves each side.

- **`opp_max_children`**: "Hard cap on opponent responses per position?"
  Safety net — rarely hit when the mass target is doing its job. Raise to
  8-10 for more thorough preparation.

- **`eval_weight`**: "How much do I trust objective eval vs trickiness?"
  At 0.40, a move needs both good eval AND high ECA. Raise toward 1.0 for
  principled repertoires. Lower toward 0.0 for tricky lines.

- **`eval_guard`**: "How bad of a position are we willing to accept for
  trickiness?" At 0.35, we'd play a line with only 35% win probability if
  it's tricky enough.

- **`min/max_eval_cp`**: "What eval range should we explore?" Stops the DFS
  when positions are too bad (lost cause) or too good (already winning,
  no need to study further). Applied during the build as inline pruning.

---

## File Layout

```
tree_builder/
├── include/
│   ├── node.h          # TreeNode struct (eval, ECA, probabilities)
│   ├── tree.h          # Tree config + interleaved build + ease/ECA
│   ├── repertoire.h    # RepertoireConfig, move selection, export
│   ├── lichess_api.h   # Lichess Explorer API client
│   ├── engine_pool.h   # Multithreaded Stockfish (batch + MultiPV)
│   ├── database.h      # SQLite caching layer
│   ├── serialization.h # JSON import/export
│   ├── chess_logic.h   # FEN parsing, UCI move application
│   ├── maia.h          # Maia neural network (ONNX Runtime)
│   └── thread_pool.h   # Generic thread pool
├── src/
│   ├── tree.c          # Interleaved build, ease, ECA, traversal
│   ├── repertoire.c    # Repertoire selection, scoring, line extraction, export
│   ├── node.c          # Node CRUD
│   ├── main.c          # CLI entry point, pipeline orchestration
│   ├── lichess_api.c   # HTTP requests to Lichess Explorer
│   ├── engine_pool.c   # Stockfish process pool (fork/pipe, MultiPV)
│   ├── database.c      # SQLite operations
│   ├── serialization.c # JSON serialization
│   ├── chess_logic.c   # Minimal chess rules for FEN/UCI
│   ├── maia.c          # ONNX Runtime inference
│   ├── thread_pool.c   # Thread pool implementation
│   ├── cJSON.c         # JSON library (vendored)
│   └── sqlite3_amalg.c # SQLite library (vendored)
```

---

## Data Flow

```
                    ┌─────────────────────────────┐
                    │   Single Interleaved Build   │
                    │          (DFS)               │
                    └─────┬──────────┬─────────────┘
                          │          │
           ┌──────────────┘          └──────────────┐
           ▼                                        ▼
   ┌───────────────┐                      ┌──────────────────┐
   │  OUR MOVE     │                      │  OPPONENT MOVE   │
   │               │                      │                  │
   │  Stockfish    │                      │  Lichess Explorer│
   │  MultiPV      │                      │  (+ Maia fallback)
   │  (10 → 2)     │                      │  + engine top-1  │
   │  → eval filter│                      │  → batch eval    │
   │  → Lichess    │                      │  → mass target   │
   │    enrichment │                      │    (95% → 50%)   │
   └──────┬────────┘                      └────────┬─────────┘
          │                                        │
          │   Eval-window pruning at every node    │
          │   DB caching of all evaluations        │
          └────────────────┬───────────────────────┘
                           ▼
              Tree with evals on all nodes
                           │
                           ▼
              tree_calculate_ease()  → ease [0, 1]
                           │
                           ▼
              tree_calculate_eca()   → accumulated_eca (wp-delta)
                           │
                           ▼
              build_repertoire_recursive()
                  Our nodes: α × eval + (1-α) × acc_eca
                  Opp nodes: traverse all children
                           │
                           ▼
              extract_lines()  → root-to-leaf paths
                           │
                           ▼
              JSON / PGN export
```
