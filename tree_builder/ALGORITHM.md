# Repertoire Generation Algorithm — Design Document

## Overview

The tree builder generates chess opening repertoires by:

1. Building a move tree from the Lichess Explorer database (with optional
   Maia neural network fallback when explorer data is exhausted)
2. Optionally discovering strong engine moves not in the Lichess database
   (Stockfish MultiPV discovery pass)
3. Evaluating every position with Stockfish
4. Computing **ECA (Expected Centipawn Advantage)** — a metric measured in
   win-probability-delta units that estimates how much win probability
   opponents will hand us on average in each line
5. Selecting repertoire moves using a blended score of eval and ECA
   (subject to eval guard and max-eval-loss filters), with the same formula
   used in both accumulation and selection for consistency
6. Extracting complete lines and exporting to JSON/PGN

---

## Pipeline Stages

The CLI runs six stages (`[0/5]` through `[5/5]`), while the internal
`generate_repertoire()` function bundles evaluation through line extraction
into its own five sub-stages.

### Stage 0: Database Initialization

Open (or create) the SQLite database that caches explorer responses,
engine evaluations, and ease scores across runs.

### Stage 1: Tree Building

Query the [Lichess Explorer API](https://explorer.lichess.ovh) for each position,
starting from a root FEN. For each position, the API returns every move played
along with game counts (wins/draws/losses) filtered by rating and time control.

**Pruning rules** (a move is excluded if any of these hold):
- `cumulative_probability < min_probability` — line is too rare to matter
- `total_games < min_games` — insufficient sample size
- `depth >= max_depth` — tree is deep enough
- `children_added >= max_children` — position already has enough children
- `mass_covered >= opponent_mass_target` — enough probability mass is covered

Each node stores:
- `move_probability`: fraction of games at the parent where this move was played
- `cumulative_probability`: probability of reaching this position in a real game,
  given that **we play our repertoire moves with 100% certainty**

**Cumulative probability only decreases on opponent moves.** When it's our turn,
every child inherits the parent's full cumP (we choose what to play). When it's
the opponent's turn, `child.cumP = parent.cumP × child.move_probability`. This
ensures sidelines like 2.d3 get explored just as deeply as the mainline 2.e5 —
the tree depth depends on how likely the *opponent* is to reach each position,
not on which of our moves we're considering.

**Resume support:** If an output file already exists, the tree is loaded and
building resumes from unexplored leaves. Nodes that were already explored
(have children or are marked `explored`) are skipped. Interrupted builds are
saved automatically on SIGINT so they can be resumed later.

#### Maia Neural Network Fallback

When the Lichess explorer returns no data for a position (insufficient games or
the line is too rare), the tree builder can fall back to the
[Maia](https://maiachess.com/) neural network to predict human-like move
probabilities and continue expanding the tree.

Maia fallback triggers when **all** of these hold:
- `--maia-model <path>` was provided (loads `maia_rapid.onnx`)
- The explorer returned zero usable moves for this position
- `node.cumulative_probability >= maia_threshold` (default 0.01 = 1%)

Maia moves below `maia_min_prob` (default 0.02 = 2%) are discarded. The
remaining moves are treated identically to explorer moves for tree expansion.
Maia moves use UCI notation as a placeholder for SAN since the model only
outputs UCI.

This allows the tree to extend into lines that are common in practice but
underrepresented in the Lichess database — for example, less popular openings
at higher rating bands.

### Stage 2: Engine Initialization + Discovery + Evaluation

#### Stockfish Discovery Pass (optional)

Enabled with `--discovery`. After the tree is built from Lichess/Maia data,
this pass finds strong engine moves that aren't in the database:

1. **Scan:** Collect all our-move nodes that have children (i.e., were
   explored by the Lichess API) and have `cumP >= min_probability`.

2. **MultiPV:** Run Stockfish MultiPV (default top-3) on each position.
   For each engine move not already a child, create a new child node if
   the move is within `max_eval_loss_cp` of the best move.

3. **Expand:** Each newly discovered branch is expanded `expansion_depth`
   ply deep (default 4). At our-move nodes, Stockfish top-1 provides the
   continuation. At opponent-move nodes, Maia top-N (if available) plus
   Stockfish top-1 (deduplicated) provide likely human responses.

Discovery-added moves have `move_probability = 0.0` (they aren't in the
database) and inherit the parent's cumulative probability.

#### Batch Engine Evaluation

Batch-evaluate every position with Stockfish (multithreaded via engine pool).
Results are cached in SQLite so re-runs skip already-evaluated positions.
Each node gets `engine_eval_cp` — the evaluation in centipawns **from the
side-to-move's perspective** (STM convention).

### Stage 3: Repertoire Generation (Eval + Ease + ECA + Selection)

The `generate_repertoire()` function runs five internal sub-stages:

**Sub-stage 1 — Engine evaluation:** Batch-evaluate any positions not yet in
the database at the configured depth.

**Sub-stage 2 — Ease calculation:** Compute ease scores (see below) for every
node and cache in the database.

**Sub-stage 3 — ECA calculation:** Compute local trickiness (wp-delta) and
accumulated ECA for the entire tree.  Takes the full `RepertoireConfig` so
that our-move filtering matches the selection phase exactly.

**Sub-stage 4 — Move selection:** Traverse the tree and select repertoire moves
(see Move Selection below).

**Sub-stage 5 — Line extraction:** Extract complete repertoire lines from the
selected moves (see Line Extraction below).

### Stage 4: Trap Detection (optional)

Enabled with `--traps`. Finds opponent positions where the most popular move
(from the database) is significantly worse than the best move. The "trap score"
measures how much eval the opponent gives away by playing the popular move,
weighted by that move's popularity.

### Stage 5: Export

Save results to JSON tree, repertoire JSON, and optionally PGN.

---

## Ease Metric

Ease measures how likely the side to move is to find a good move. It's a
legacy metric from the Flutter app, carried forward for backward compatibility
and used as a fallback scoring component when ECA is unavailable.

```
q(cp) = 2 / (1 + e^(-0.004 × cp)) - 1         # sigmoid, maps cp to [-1, 1]
q_max = q(best child eval, from our perspective)

weighted_regret = Σ(prob_i^1.5 × max(0, q_max - q(child_i eval)))
ease = 1 - (weighted_regret / 2)^(1/3)
```

Children with `move_probability < 0.01` (1%) are excluded. The formula
matches the Flutter/Python implementation exactly.

---

## ECA: Expected Centipawn Advantage (Win-Probability-Delta Units)

### Concept

ECA measures: "If I play this line, how much win probability will my opponent
hand me on average due to suboptimal play?"

Everything is measured in win-probability-delta units [0, ~0.5] from the bottom
of the tree to the top.  One number per node, one formula, no normalization.

The names `local_cpl`, `accumulated_eca`, and `has_eca` are kept for backward
compatibility — the concept is the same, just measured in win-probability space
instead of raw centipawns.

It combines two ideas:
- **Local trickiness (local_cpl)**: at a single node, how much win probability
  does the side-to-move hand the other side by playing database moves instead
  of the best move?
- **Accumulation**: sum local trickiness from opponent nodes down the tree,
  with our-move nodes selecting via the blended score that matches the
  selection phase.

### Win Probability Function

The Lichess-calibrated sigmoid:

```
wp(cp) = 1 / (1 + e^(-0.00368208 × cp))
```

Maps centipawns to [0, 1] from White's perspective.  A 50cp blunder near
equality (0.50 → 0.55 wp) contributes ~0.046 wp-delta.  The same 50cp blunder
when already up 300cp (0.75 → 0.77 wp) contributes only ~0.016.  The sigmoid
makes blunders in critical positions worth more than blunders in already-decided
positions.

### Local Trickiness (local_cpl)

At each node, `compute_local_eca()` computes how much win probability the
side-to-move gives away by playing database moves instead of the best move:

```
wp_for_mover(child) = 1 - wp(child.engine_eval_cp)

best_wp   = max(wp_for_mover(child) for all children with evals)
local_cpl = Σ(prob_i × max(0, best_wp - wp_for_mover(child_i)))
            for children with move_probability >= 0.01
```

**Sign convention:** `child.engine_eval_cp` is from the next-STM perspective
(the mover's opponent).  `wp(child_eval)` gives the opponent's win probability.
`1 - wp(child_eval)` gives the mover's win probability.  The mover wants to
maximize this, so the best move has the highest `wp_for_mover`.

Children with `move_probability < 0.01` are excluded from the delta sum but
NOT from the `best_wp` computation — rare strong moves set the baseline that
common moves are measured against.

`local_cpl` is in [0, 1] and typically ranges 0.00–0.10 (0–10 percentage
points of win probability).

### Bottom-Up Accumulation

`calculate_eca_recursive()` runs a post-order DFS.  The accumulation pass
receives the full `RepertoireConfig` so that our-move filtering matches the
selection phase exactly.

- **Leaf nodes**: `accumulated_eca = depth_decay^depth × local_cpl`
- **Opponent-move nodes**:
  `accumulated_eca = depth_decay^depth × local_cpl + Σ(prob_i × child_i.accumulated_eca)`
  — local trickiness plus probability-weighted future trickiness
- **Our-move nodes**: Select the child using the blended score
  `α × wp_us(child.eval) + (1-α) × child.accumulated_eca`, with eval-guard
  and max-eval-loss filters applied (same filters as selection).  Propagate
  the selected child's `accumulated_eca` upward.

The our-move formula is the key difference from the old system (which used
`max(child_eca)`).  Now the accumulated value reflects the trickiness of the
move we'd actually play under the current scoring policy — not the trickiest
move that might never be selected.

A shared helper function `score_our_move_children()` is called by both the
accumulation DFS and the selection DFS to guarantee they pick the same child.

### Move Selection (blended scoring, no normalization)

At our-move nodes during the top-down traversal:

```
for each child (after eval-guard and max-eval-loss filtering,
                with "if all fail, re-score all" fallback):
    score = α × wp_us(child.eval) + (1-α) × child.accumulated_eca

select argmax(score)
```

This is **identical** to what the accumulation phase computed.  No
normalization step is needed because `accumulated_eca` is in
win-probability-delta units — the same unit space as `wp_us`.  Both derive
from the same sigmoid, making them naturally comparable without rescaling.

**Eval source consistency:** Selection reads evals from
`child->engine_eval_cp` (TreeNode fields), not from the database via
`rdb_get_eval()`.  The accumulation pass also reads from TreeNode, so both
phases use the same source, guaranteeing they pick the same child.

The `α` parameter (`--eval-weight`) controls the tradeoff:
- `α = 1.0`: pure objective eval (pick the best engine move)
- `α = 0.0`: pure trickiness (pick the line where opponents blunder most)
- `α = 0.4` (default): blend

Before scoring, two filters reject candidates:
1. **Max-eval-loss filter**: candidates more than `max_eval_loss_cp` worse
   than the best sibling are skipped.
2. **Eval guard**: moves where our win probability falls below
   `eval_guard_threshold` (default 0.35) are rejected regardless of trickiness.
3. **Fallback**: if ALL children are filtered out, re-score all children with
   the blended formula (no filters) and pick the best.

#### Fallback Scoring (when ECA is unavailable)

If none of a node's children have ECA data (e.g., all are leaves without
engine evals), move selection falls back to a weighted four-component formula:

```
score = weight_eval × normalized_eval           (30%)
      + weight_ease × ease_component            (25%)
      + weight_winrate × database_win_rate      (25%)
      + weight_sharpness × (1 - opponent_ease)  (20%)
```

This is further adjusted by:
- **Statistical confidence**: positions with fewer than 100 games get a
  penalty (linearly scaled from 0.5 at 0 games to 1.0 at 100 games).
- **Probability weighting**: `0.5 + 0.5 × √probability` — likely positions
  matter more.

### Move Selection at Opponent Nodes

At opponent-move nodes, all children above the probability threshold
(`candidate_min_prob`, default 1%) are recursed into. The DFS also stops
if the position is too winning (`--max-eval`) or too losing (`--min-eval`).

### Line Extraction

Follow the selected repertoire moves through the tree. At our-move nodes, only
the selected move is followed. At opponent-move nodes, all likely responses are
followed. Each root-to-leaf path becomes a repertoire line.

**Lines always end with the repertoire side's move.** If a line would end on
the opponent's move (because the tree leaf happens to be at an our-move node
with no selected response), the trailing opponent move is trimmed. This way
every line shows exactly what we play in response to the opponent — lines never
leave you wondering "but what do I play here?"

---

## Resolved: ECA Now Accounts for Absolute Evaluation

The win-probability-delta metric naturally handles the absolute-evaluation
problem that was the most significant flaw in the old centipawn-based ECA.

### How the sigmoid solves it

A 50cp blunder near equality (0.50 → 0.55 wp) contributes ~0.046 wp-delta.
A 50cp blunder when already winning (+300cp, 0.75 → 0.77 wp) contributes only
~0.016.  The sigmoid makes blunders in critical positions worth more than
blunders in already-decided positions.

### Alekhine Example (1.e4 Nf6)

| Move | White's Eval | Blunder delta (old cp) | Blunder delta (new wp) |
|------|-------------|------------------------|------------------------|
| 2.e5 | +64 cp | 3.8 cp | ~0.004 wp |
| 2.Nc3 | +26 cp | 18.1 cp | ~0.017 wp |

The new metric still shows higher local trickiness for Nc3, but the gap is
compressed.  Combined with the blended score (α × eval_us + (1-α) × acc_eca),
the stronger position after e5 (higher wp_us) can now outweigh the trickiness
advantage of Nc3 — especially since the accumulation pass also factors in
eval when selecting our moves deeper in the tree.

### Accumulation/Selection Consistency

The old system had a second problem: accumulation used `max(child_eca)` but
selection used a blended score, so they could pick different children.  The
new system uses `score_our_move_children()` in both phases, guaranteeing they
agree.  A parent node's ECA now reflects the trickiness of the line we'd
actually play.

---

## Minor Issue: Unrenormalized Probabilities in ECA Accumulation

At opponent nodes, accumulated ECA sums `prob_i × child_eca` over all children.
The `prob_i` values are raw Lichess fractions (e.g., Nc6 = 0.60, Nf6 = 0.20,
d6 = 0.10). But tree building filters out moves below `min_games`,
`min_probability`, `max_children`, or `mass_cutoff`, so the remaining
probabilities typically sum to 0.85–0.95 rather than 1.0.

The missing mass implicitly contributes ECA = 0 — as if unanalyzed lines have
no trickiness. This creates a small bias: positions where opponent moves are
concentrated in a few popular choices get higher ECA than positions where the
probability is spread across many rare moves, even if the explored lines are
equally tricky.

**In practice this is minor.** The top 4–5 moves cover 90%+ of games in most
positions, so the gap is typically 5–10%. It only becomes significant with
aggressive filtering (`--mass-cutoff 0.80` or `--max-children 3`), where the
lower ECA honestly reflects reduced coverage.

The un-renormalized version has a defensible interpretation: "expected opponent
win-probability loss across *all* games from this position, treating unanalyzed
lines as contributing nothing."  This effect is arguably correct: positions
where the opponent has many diffuse responses genuinely have less exploitable
structure than positions with one dominant line.

---

## Parameters

### Tree Building

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `min_probability` | `-p` | 0.0001 (0.01%) | Prune branches below this cumulative probability (opponent moves only) |
| `max_depth` | `-d` | 30 ply | Maximum tree depth |
| `min_games` | `-g` | 10 | Minimum Lichess games to include a move |
| `max_children` | `--max-children` | 0 (unlimited) | Max moves to explore per position |
| `opponent_mass_target` | `--mass-cutoff` | 0 (off) | Stop adding moves after covering this fraction of probability |
| `ratings` | `-r` | 2000,2200,2500 | Lichess rating buckets for move probabilities |
| `speeds` | `-s` | blitz,rapid,classical | Time controls to include |

### Maia Fallback

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `maia_model` | `--maia-model` | (disabled) | Path to `maia_rapid.onnx` model file |
| `maia_elo` | `--maia-elo` | 2000 | Elo rating for Maia predictions (1100–2100) |
| `maia_threshold` | `--maia-threshold` | 0.01 (1%) | Min cumulative probability to trigger Maia fallback |
| `maia_min_prob` | `--maia-min-prob` | 0.02 (2%) | Skip Maia moves below this probability |

### Stockfish Discovery

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `discovery` | `--discovery` | off | Enable the discovery pass |
| `multipv` | `--discovery-multipv` | 3 | Top-N engine moves to check per position |
| `expansion_depth` | `--discovery-expand` | 4 | Ply to expand each new branch |

### Engine Evaluation

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `eval_depth` | `-e` | 20 | Stockfish search depth per position |
| `num_threads` | `-t` | 4 | Number of parallel Stockfish engines |

### ECA & Move Selection

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `depth_discount` | `--depth-decay` | 1.0 (no decay) | Depth discount for ECA. At 1.0, all depths contribute equally (the sigmoid + probability weighting handle importance). Lower values prefer early blunders over deep ones. Less necessary with wp-delta units since the sigmoid already compresses extreme evals |
| `eval_weight` | `--eval-weight` | 0.40 | Blend ratio. 0 = pure trickiness. 1 = pure objective eval. 0.4 = 40% eval, 60% trickiness |
| `eval_guard_threshold` | `--eval-guard` | 0.35 | Minimum win probability to consider a move. Moves below this are rejected regardless of trickiness |
| `min_eval_cp` | `--min-eval` | W: 0, B: -200 | Stop DFS if our eval drops below this (losing position). Color-dependent defaults applied automatically |
| `max_eval_cp` | `--max-eval` | W: 200, B: 100 | Stop DFS if our eval exceeds this (already won). Color-dependent defaults applied automatically |
| `relative_eval` | `--relative` | off | Make `--min-eval` / `--max-eval` relative to the root position's eval rather than absolute |
| `max_eval_loss_cp` | `--max-eval-loss` | 50 | Skip our-move candidates more than N cp worse than the best |
| `max_candidates` | `--max-children` | 8 | Max moves to consider per position during selection |
| `candidate_min_prob` | (config) | 0.01 (1%) | Minimum move probability to consider for opponent responses |

### What Each Parameter Does Intuitively

- **`min_probability`**: "How rare of a line should we still prepare for?"
  Lower = more complete but slower. Higher = focus on mainlines only.

- **`min_games`**: "How many games do we need to trust the statistics?"
  Higher = more reliable probabilities but might miss newer lines.

- **`depth_discount`** (`--depth-decay`): "Should early blunders count more than
  deep ones?" At 1.0 (default), all blunders contribute equally — the sigmoid
  compression and probability weighting already handle depth naturally.  Less
  necessary with wp-delta units since the sigmoid compresses extreme evals.
  Set below 1.0 for deep forcing-line repertoires where you want to prevent
  deep opponent nodes from dominating the signal.

- **`ratings`**: "Whose mistakes are we exploiting?" Using 2000+ means the
  probabilities reflect what strong players actually do. Using 1200+ would show
  beginner-level blunders that a strong opponent won't make.

- **`eval_depth`**: "How accurate should evaluations be?" Depth 12 is fast but
  noisy. Depth 20 is slow but catches deep tactical issues. Affects which moves
  are identified as "best" and how large the CPL values are.

- **`eval_weight`** (`--eval-weight`): "How much do I trust objective eval vs
  trickiness?" At 0.40, a move needs both good eval AND high ECA to score well.
  Raise toward 1.0 for more theoretically principled repertoires. Lower toward
  0.0 for maximally tricky lines regardless of objective merit.

- **`eval_guard`** (`--eval-guard`): "How bad of a position are we willing to
  accept for trickiness?" At 0.35, we'd play a line where we have only 35% win
  probability if it's tricky enough. Raise to 0.45–0.50 for more sound
  repertoires.

- **`--relative`**: "Should eval thresholds be relative to the starting position?"
  Useful when starting from a custom FEN that's already imbalanced — the
  min/max eval window shifts by the root position's eval so thresholds stay
  meaningful.

- **`--maia-model`**: "Should the tree extend beyond Lichess data?" When the
  explorer runs out of games, Maia provides human-like move predictions to
  keep building. Useful for rare lines where Lichess data is sparse but real
  opponents still play consistently.

- **`--discovery`**: "Should we look for strong engine moves that humans don't
  play?" Finds Stockfish-approved moves missing from the database. Good for
  novelties or improvements over the database mainline.

---

## File Layout

```
tree_builder/
├── include/
│   ├── node.h          # TreeNode struct (eval, ECA wp-delta fields, probabilities)
│   ├── tree.h          # Tree operations, ECA calculation, discovery config
│   ├── repertoire.h    # RepertoireConfig, move selection, line extraction
│   ├── lichess_api.h   # Lichess Explorer API client
│   ├── engine_pool.h   # Multithreaded Stockfish evaluation (batch + MultiPV)
│   ├── database.h      # SQLite caching layer
│   ├── serialization.h # JSON import/export
│   ├── chess_logic.h   # FEN parsing, UCI move application, board state
│   ├── maia.h          # Maia neural network integration (ONNX Runtime)
│   └── thread_pool.h   # Generic thread pool
├── src/
│   ├── tree.c          # Tree building, ease, ECA (wp-delta), scoring helper, discovery, Maia
│   ├── repertoire.c    # generate_repertoire pipeline, scoring, line extraction
│   ├── node.c          # Node creation, node_set_eca, node_set_eval
│   ├── lichess_api.c   # HTTP requests to Lichess Explorer (with auth)
│   ├── engine_pool.c   # Stockfish process pool (fork/pipe/select, MultiPV)
│   ├── database.c      # SQLite operations (eval cache, ease cache, repertoire moves)
│   ├── serialization.c # JSON serialization with ECA fields
│   ├── chess_logic.c   # Minimal chess rules for FEN/UCI handling
│   ├── maia.c          # ONNX Runtime inference, board encoding, move decoding
│   ├── thread_pool.c   # Thread pool implementation
│   ├── main.c          # CLI entry point, argument parsing, pipeline orchestration
│   ├── cJSON.c         # JSON library (vendored)
│   └── sqlite3_amalg.c # SQLite library (vendored)
```

---

## Data Flow

```
Lichess Explorer API ─────────────────────────────────────────────┐
        │                                                         │
        ▼                                                         │
   Tree Building ──→ TreeNode.move_probability (from game counts) │
        │              TreeNode.cumulative_probability             │
        │                                                         │
        │  ┌──── Maia fallback (when explorer exhausted) ────┐    │
        │  │  Predicts human-like move probabilities          │    │
        │  │  via ONNX model to extend tree                   │    │
        │  └──────────────────────────────────────────────────┘    │
        │                                                         │
        ▼                                                         │
   Discovery Pass (optional) ──→ New engine-only child nodes      │
        │  Stockfish MultiPV finds moves not in Lichess           │
        │  Maia + Stockfish expand new branches                   │
        │                                                         │
        ▼                                                         │
   Stockfish Pool ──→ TreeNode.engine_eval_cp (from STM perspective)
        │
        ▼
   calculate_ease_for_node() ──→ ease score [0, 1]
        │                        (fallback scoring component)
        ▼
   compute_local_eca() ──→ TreeNode.local_cpl (wp-delta trickiness)
        ▼
   calculate_eca_recursive() ──→ TreeNode.accumulated_eca (bottom-up DFS)
        │                         (win-probability-delta units)
        ▼
   build_repertoire_recursive() ──→ RepertoireMove[] (our selected moves)
        │                            - At our nodes: α × eval + (1-α) × acc_eca
        │                            - Uses score_our_move_children() (same as accumulation)
        │                            - Fallback: 4-weight formula when no ECA
        │                            - Filtered by max-eval-loss and eval guard
        │                            - At opponent nodes: recurse all likely responses
        ▼
   extract_lines() ──→ RepertoireLine[] (complete root-to-leaf paths)
        │                - Follows only selected moves at our nodes
        │                - Trims lines that end on the opponent's move
        ▼
   JSON / PGN export
```
