# Repertoire Generation Algorithm — Design Document

## Overview

The tree builder generates chess opening repertoires by:

1. Building a move tree from the Lichess Explorer database (with optional
   Maia neural network fallback when explorer data is exhausted)
2. Optionally discovering strong engine moves not in the Lichess database
   (Stockfish MultiPV discovery pass)
3. Evaluating every position with Stockfish
4. Computing **ECA (Expected Centipawn Advantage)** — a metric that estimates
   how many centipawns opponents will lose on average in each line
5. Selecting repertoire moves that maximize ECA (subject to an eval guard),
   with a fallback scoring path when ECA data is unavailable
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

**Sub-stage 3 — ECA calculation:** Compute local CPL and accumulated ECA for
the entire tree (see detailed description below).

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

## ECA: Expected Centipawn Advantage

### Concept

ECA measures: "If I play this line, how many centipawns will my opponent lose
on average due to suboptimal play?"

It combines two ideas:
- **Local CPL (Centipawn Loss)**: at a single node, how much does the player
  lose by playing popular moves instead of the best move?
- **Accumulation**: sum local CPL contributions from opponent nodes down the
  tree, discounted by depth.

### Local CPL Calculation

At each node, `compute_local_eca()` looks at all children (moves available)
and computes how much the side-to-move loses on average:

```
best_cp = min(child.engine_eval_cp for all children)

local_cpl = Σ(child.move_probability × max(0, child.eval_cp - best_cp))
```

**Key detail — sign convention:** Children's evals are from the *next* STM's
perspective (opposite to the player choosing). The player's best move is the
child with the **minimum** eval (worst for the opponent). Loss for choosing
child `i` is `eval_i - min_eval` (positive = the player gave away centipawns).

Children with `move_probability < 0.01` (1%) are excluded.

A Q-value version (`local_q_loss`) is also computed using a sigmoid transform
that provides diminishing returns for large eval differences.

### Bottom-Up Accumulation

`calculate_eca_recursive()` runs a post-order DFS:

- **Leaf nodes**: `accumulated_eca = depth_decay^depth × local_cpl`
- **Our-move nodes**: `accumulated_eca = max(child.accumulated_eca)` — we pick
  the trickiest line
- **Opponent-move nodes**:
  `accumulated_eca = depth_decay^depth × local_cpl + Σ(prob_i × child_i.accumulated_eca)`
  — local blunder potential plus probability-weighted future blunders

### Move Selection (composite scoring)

At our-move nodes, each candidate move receives a **composite score** that
blends objective evaluation with trickiness:

```
norm_eca = child.accumulated_eca / max(sibling accumulated_eca values)
eval_us  = win_probability(child eval, from our perspective)

score = eval_weight × eval_us + (1 - eval_weight) × norm_eca
```

- `eval_weight` (`--eval-weight`): controls the eval-vs-trickiness tradeoff.
  At 0, pure trickiness. At 1, pure objective strength. Default 0.40.
- `norm_eca`: ECA normalized to [0, 1] relative to the best sibling, so eval
  and ECA contribute on comparable scales.
- `eval_us`: win probability from our perspective, naturally in [0, 1].

Before scoring, two filters reject candidates:
1. **Max-eval-loss filter**: candidates more than `max_eval_loss_cp` worse
   than the best sibling are skipped.
2. **Eval guard**: moves where our win probability falls below
   `eval_guard_threshold` (default 0.35) are rejected regardless of trickiness.

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

## Known Issue: ECA Ignores Absolute Evaluation

**This is the most significant design flaw.**

ECA measures *relative* opponent error within a subtree — how much worse
opponents play compared to their best option *in that position*. It does NOT
account for the absolute evaluation baseline.

### Example (1.e4 Nf6 — Alekhine's Defense)

| Move | White's Eval | Black's "blunder" | Black's eval after blunder |
|------|-------------|-------------------|---------------------------|
| 2.e5 | +64 cp | Nd5 (93.7%, loss=0) | -62 cp (still bad for Black) |
| 2.Nc3 | +26 cp | d5 (42.5%, loss=24) | -45 cp (better for Black than e5 line!) |

ECA prefers Nc3 (local_cpl=18.1) over e5 (local_cpl=3.8) because opponents
"blunder" more after Nc3. But these "blunders" leave Black in a better position
than perfect play in the e5 line! The 24 cp "blunder" after Nc3 gives Black
-45 cp, while the e5 mainline gives Black -62 cp even with perfect play.

**In other words: ECA rewards lines where opponents make small inaccuracies
in already-comfortable positions, rather than lines where opponents face
genuinely difficult problems from an already-worse starting position.**

### Current Mitigation: Composite Scoring

The move selection blends eval with ECA via `--eval-weight`:

```
score = eval_weight × eval_for_us + (1 - eval_weight) × normalized_eca
```

At eval_weight=0.40 (default), a move needs to be both objectively decent AND tricky to
score well. This helps but doesn't fully solve the problem at shallow depths
because the ECA gap between "tricky-but-weak" and "strong-but-obvious" lines
can still dominate.

### Further Improvements to Explore

1. **Deeper trees**: The most impactful fix. At depth 8, the e5 line hasn't had
   time to accumulate ECA from deeper opponent errors (moves 5-10). With deeper
   trees, objectively critical lines naturally accumulate more ECA.

2. **Minimum loss threshold**: Only count losses above N centipawns (e.g., 50 cp)
   as real mistakes, filtering out inaccuracies between equally reasonable moves.

3. **Absolute-floor CPL**: Only count opponent losses that push their eval below
   some threshold. A "blunder" that still leaves the opponent comfortable
   shouldn't count.

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
| `depth_discount` | `--depth-decay` | 0.90 | How fast deeper positions matter less. Lower = focus on immediate blunders. Higher = value deep traps more. Range: 0.80–0.98 |
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

- **`depth_discount`** (`--depth-decay`): "How much do we care about deep traps
  vs immediate mistakes?" At 0.85, a blunder 6 moves deep is worth only
  0.85^6 = 38% of its face value. At 0.95, it's worth 0.95^6 = 74%.

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
│   ├── node.h          # TreeNode struct (eval, ECA fields, probabilities)
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
│   ├── tree.c          # Tree building, ease, ECA, discovery pass, Maia fallback
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
   compute_local_eca() ──→ TreeNode.local_cpl (probability-weighted CPL)
        │                   TreeNode.local_q_loss
        ▼
   calculate_eca_recursive() ──→ TreeNode.accumulated_eca (bottom-up DFS)
        │                         TreeNode.accumulated_q_eca
        ▼
   build_repertoire_recursive() ──→ RepertoireMove[] (our selected moves)
        │                            - At our nodes: composite score (eval + ECA blend)
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
