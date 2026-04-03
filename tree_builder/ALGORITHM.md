# Repertoire Generation Algorithm — Design Document

## Overview

The tree builder generates chess opening repertoires through a single
interleaved DFS that builds the tree and evaluates positions simultaneously:

1. **Building** the move tree by querying Lichess Explorer, Maia, and Stockfish
   together — engine MultiPV for our-move candidates, Lichess DB + Maia
   supplement for opponent responses, with eval-window pruning at every node
2. Computing **ease scores** (how likely the side to move finds a good move)
3. Computing **ECA (Expected Centipawn Advantage)** — estimating how many
   centipawns opponents hand us per turn due to suboptimal play
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

#### Opponent-Move Nodes (Lichess + Maia)

Opponent moves use a blended strategy: Lichess database moves are added
first (real game data), then Maia fills in remaining mass with predicted
human moves. A single node can end up with a mix of both sources.

1. **Lichess Explorer** — query for human move frequencies. Add moves that
   have at least `min_games` games, tracking cumulative mass covered.
2. **Maia supplement** — if the mass target hasn't been reached and
   `cumulative_probability >= maia_threshold`, run Maia inference and add
   predicted moves that weren't already added from Lichess. This handles
   three cases seamlessly:
   - Lichess covered some mass but not enough (e.g. 2 Lichess moves at 40%,
     Maia adds 3 more moves to reach 90%)
   - Lichess had total games but no individual move passed `min_games`
     (Maia provides the entire distribution)
   - Lichess had no data at all (equivalent to the old "fallback" behavior)
3. **Branching caps (tapering)** — both Lichess and Maia additions respect
   `opp_max_children` (default 6) and the depth-dependent mass target. The
   mass target tapers linearly from `opp_mass_root` (default 95%) at the
   root to `opp_mass_floor` (default 50%) at `taper_depth` and beyond. Near
   the root this covers almost every played response (including 2–5%
   sidelines worth preparing against); deeper in the tree it focuses on only
   the most popular replies.
4. **Engine top-1 injection** — run Stockfish on this position. If the
   engine's best move is not already a child, inject it so we have a
   prepared response.  A transposition check prevents injection when the
   resulting FEN is already expanded elsewhere in the tree.  If the
   engine's move already exists as a child, its eval is backfilled
   instead of duplicating.

   **Probability:** The injected move's probability comes from Maia's
   prediction for that move if available (the Maia response from step 2
   is reused).  If the move isn't in Maia's output, a fallback of 0.01
   (1%) is used.  This probability governs how deep the injected subtree
   is explored: the `cumulative_probability` of the child is
   `parent_cumP × prob`, and the tree's standard `min_probability`
   pruning naturally limits depth.

   **Subtree building:** Engine-injected nodes are normal children —
   they use the standard DFS build logic with the same pruning rules
   (cumP, mass target, eval window, max depth) as any other node.  No
   separate depth cap is needed because the low probability assigned
   to moves Maia didn't predict causes their cumP to decay quickly.
5. **Batch evaluate** all children that lack evaluations (checks DB cache
   first, then Stockfish). Evals are cached to DB.
6. **Recurse** into each child.

`--maia-only` (the default) bypasses Lichess entirely, using Maia as the
sole source of opponent moves. This eliminates the 500ms per-query API
rate limit but produces larger trees (Maia always has predictions, unlike
Lichess which naturally prunes positions with too few games). Use
`--lichess` to enable Lichess API queries with Maia as a supplement.

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
- If `eval_for_us > max_eval_cp` — position is already won, stop studying.
  The node is kept as a leaf with `prune_reason = PRUNE_EVAL_TOO_HIGH` and
  the triggering eval stored in `prune_eval_cp`.  PGN export annotates
  these with `{Already winning (+1.50); no further preparation needed}`.
- If `eval_for_us < min_eval_cp` — position is too bad for us.  The node
  is marked `PRUNE_EVAL_TOO_LOW` during the build, then **deleted** in a
  post-build cleanup pass (`tree_prune_eval_too_low()`).  There's no point
  keeping positions where we're already lost.

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

**Transposition detection.** A FenMap (hash table, FEN → canonical
TreeNode*) tracks every position that has been fully expanded during the
build.  The map starts at 4096 buckets and doubles when the load factor
exceeds 0.75, so lookups stay O(1).

When a position is reached via a different move order, the transposition
node is linked into a **circular equivalence ring** with the canonical
node via the `next_equivalent` pointer.  All nodes for the same position
can find each other by walking the ring.  The canonical node (first
expanded) has children; the others are transposition leaves.

During ECA calculation, transposition leaves walk their equivalence ring
to find the canonical node and borrow `accumulated_eca`, `local_cpl`,
`subtree_depth`, and `subtree_opp_plies` from it instead of contributing
zero.  The tree remains a tree (not a DAG) for serialization and
traversal, but the equivalence ring lets ECA see through to the canonical
subtree.  On resume, existing nodes re-register their FENs in the map so
transpositions are still detected for newly expanded branches.

Equivalence rings are persisted in JSON via `next_equivalent_id` on each
node.  On load, a `LoadContext` builds an ID→node map during parsing and
resolves all links in a single pass afterwards.  The global node-ID
counter is also synced to `max(loaded_id) + 1` so resume doesn't create
collisions.

**Known limitation:** ECA borrowing from the canonical node depends on
DFS traversal order — the canonical node must be processed *before* its
transposition leaves.  This holds in the common case (canonical was
expanded first, so it's in an earlier branch), but is not guaranteed
after reordering or manual edits.  When borrowing fails silently, the
transposition leaf contributes ECA=0.

**Known limitation:** Transposition leaves keep the cumulative probability
of the path that discovered them.  If a higher-probability path reaches
the same position later, the canonical node is not re-expanded at the
deeper depth that the higher cumP would allow.  This is acceptable since
it only under-explores some positions rather than producing incorrect
results.

#### Maia Neural Network Integration

Maia supplements Lichess data at opponent-move nodes, filling in mass that
Lichess couldn't cover. It triggers when all of:
- A Maia model was found (auto-detected from `./maia3_simplified.onnx` or
  `../assets/maia3_simplified.onnx`, or explicit `--maia-model <path>`)
- The mass target hasn't been reached after Lichess moves
- `node.cumulative_probability >= maia_threshold` (default 0.01 = 1%)

Maia moves already present from Lichess are skipped (dedup by UCI).
All child creation goes through `make_child()` which also rejects
duplicates by resulting FEN as a safety net.
Maia moves below `maia_min_prob` (default 0.02 = 2%) are discarded.

With `--maia-only`, Lichess is skipped entirely and the `maia_threshold`
gate is removed — every position gets Maia predictions regardless of cumP.

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

## ECA: Expected Centipawn Advantage

### Concept

ECA measures: "If I play this line, how many centipawns will my opponent
hand me on average per opponent turn, due to suboptimal play?"

Everything is in centipawn units. `local_cpl` is computed bottom-up
at each node, then `accumulated_eca` aggregates the signal through the
tree. At selection time, accumulated ECA is normalized by opponent ply
count so deep and shallow lines are compared on the same scale.

### Local Trickiness (local_cpl)

At opponent-move nodes, `child.engine_eval_cp` is eval for the side to
move (us, since the opponent just played). The opponent's best move
minimises our eval:

```
best_opp_cp = min(child.engine_eval_cp for all children with evals)
local_cpl   = Σ(prob_i × max(0, child_i.engine_eval_cp - best_opp_cp))
              for children with move_probability >= 0.01
```

`local_cpl` is the expected centipawn gift the opponent hands us at this
node by playing popular moves instead of their best move.

### Bottom-Up Accumulation

Post-order DFS with the full `RepertoireConfig` for filter consistency:

- **Leaf nodes**: `accumulated_eca = γ^d × local_cpl`
- **Opponent-move nodes**:
  `accumulated_eca = γ^d × local_cpl + Σ(prob_i × child_i.accumulated_eca)`
- **Our-move nodes**: Select the child using the blended score (see Move
  Selection below). Propagate the selected child's `accumulated_eca`.

A shared helper `score_our_move_children()` is used by both accumulation
and selection to guarantee consistency.

### Move Selection

At our-move nodes during the top-down traversal:

```
for each child (after max-eval-loss filtering,
                with "if all fail, re-score all" fallback):
    opp_plies = child.subtree_opp_plies   (actual count, min 1)
    avg_cpl   = child.accumulated_eca / opp_plies
    score     = eval_us_cp(child) + eca_weight × avg_cpl

select argmax(score)
```

`subtree_opp_plies` is the actual number of opponent-move levels in the
subtree, computed bottom-up during ECA calculation:
- Leaves: `subtree_opp_plies = 0`
- Opponent-move nodes: `subtree_opp_plies = 1 + max(child.subtree_opp_plies)`
- Our-move nodes: `subtree_opp_plies = max(child.subtree_opp_plies)`

This replaces the old estimate `1 + subtree_depth / 2`, which was
inaccurate in asymmetric trees where pruning removed branches unevenly.

Both terms are in centipawn units. `eca_weight` controls how much
trickiness matters relative to objective eval.

**Known issue:** `subtree_opp_plies` uses the *maximum* child depth,
not a weighted average.  In highly asymmetric trees (one deep branch,
many shallow ones), the max can over-count.  A probability-weighted
expected depth would be more accurate but is more complex to compute
(requires a second bottom-up pass after move selection, creating a
circular dependency).  The current approach is correct for balanced
trees and a reasonable approximation for asymmetric ones.

**Known issue:** For transposition leaves, `subtree_opp_plies` is
borrowed from the canonical node.  This is correct if the canonical
subtree is representative, but the actual depth from this path may
differ (the transposition might be reached deeper or shallower).
Currently accepted as a reasonable approximation.

At opponent-move nodes, all children above the probability threshold are
recursed into. The DFS also stops at eval-window boundaries.

### Line Extraction

Follow selected repertoire moves through the tree. At our-move nodes, only
the selected move is followed. At opponent-move nodes, all likely responses
are followed. Lines always end with the repertoire side's move.

### Castling UCI Normalization

The Lichess Explorer API returns castling in "king captures rook" notation
(`e1h1`, `e1a1`, `e8h8`, `e8a8`) while Stockfish uses "king destination"
notation (`e1g1`, `e1c1`, `e8g8`, `e8c8`). The tree builder normalizes
all castling UCI to king-destination form at three levels:

1. **Lichess responses** — normalized in `build_opponent_move()` and
   `build_our_move()` before any downstream use.
2. **`position_apply_uci()`** — normalizes internally so FEN generation
   is always correct regardless of input format.
3. **`make_child()` FEN dedup** — rejects a new child if a sibling with
   the same resulting FEN already exists, catching any representation
   mismatch that UCI-level dedup might miss.

---

## Parameters

### Tree Building — Our Moves (Engine-Driven)

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `our_multipv_root` | `--our-multipv-root` | 10 | MultiPV at root (explore broadly) |
| `our_multipv_floor` | `--our-multipv-floor` | 2 | MultiPV floor (deep positions) |
| `taper_depth` | `--taper-depth` | 8 | Ply at which both tapers bottom out |
| `max_eval_loss_cp` | `--max-eval-loss` | 50 | Candidates must be within this of best |

### Tree Building — Opponent Moves (Lichess + Maia)

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

### Maia Supplement

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `maia_model` | `--maia-model` | auto-detect | Path to `maia3_simplified.onnx` |
| `maia_elo` | `--maia-elo` | 2200 | Elo for predictions (600–2400) |
| `maia_threshold` | `--maia-threshold` | 0.01 (1%) | Min cumProb for Maia supplement |
| `maia_min_prob` | `--maia-min-prob` | 0.02 (2%) | Skip moves below this probability |
| `maia_only` | `--maia-only` | on (default) | Bypass Lichess API, use Maia exclusively |
| | `--lichess` | | Enable Lichess API (overrides `--maia-only`) |

### ECA & Move Selection

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `depth_discount` | `--depth-decay` | 1.0 | Depth discount for ECA |
| `eca_weight` | `--eca-weight` | 0.40 | Multiplier on avg CPL per opponent turn in the blended score |

### What Each Parameter Does Intuitively

- **`our_multipv_root / our_multipv_floor`**: "How many engine moves to
  consider?" At the root, cast a wide net (10 lines) to discover every
  viable opening move. Deep in the tree, only ask for the top 2. The eval
  filter further narrows actual children — MultiPV is the exploration
  budget, and `max_eval_loss_cp` decides who survives.

- **`opp_mass_root / opp_mass_floor`**: "How much of the opponent's
  probability mass to cover?" At the root, cover 95% — prepare for almost
  everything, including 2–5% sidelines. Deep in the tree, 50% means only
  the top 1–2 replies. Lichess moves fill mass first, then Maia supplements
  to reach the target. Combined with cumulative-probability pruning, this
  focuses deep branches naturally.

- **`taper_depth`**: "When does the tree shift from broad exploration to
  focused depth?" Both the MultiPV taper and mass target taper reach their
  floor values at this depth. Default 8 ply = 4 moves each side.

- **`opp_max_children`**: "Hard cap on opponent responses per position?"
  Safety net — rarely hit when the mass target is doing its job. Raise to
  8-10 for more thorough preparation.

- **`eca_weight`**: "How much should trickiness boost the score?"
  Multiplied against average CPL per opponent turn and added to eval.
  At 0.0, selection is purely by objective eval. Higher values reward
  lines where the opponent is more likely to blunder.

- **`min/max_eval_cp`**: "What eval range should we explore?" Stops the DFS
  when positions are too bad (lost cause) or too good (already winning,
  no need to study further). Applied during the build as inline pruning.

- **`maia_threshold`**: "When should Maia supplement Lichess?" Only positions
  with cumulative probability above this get Maia predictions. Prevents
  wasting inference on unlikely branches. With `--maia-only`, this gate is
  removed.

- **`--maia-only`** (default): "Skip the Lichess API entirely?" Eliminates
  the 500ms per-query rate limit, but produces larger trees since Maia
  always has predictions (unlike Lichess which prunes positions with too
  few games). Use `--lichess` to override. Tighten pruning parameters to
  compensate for larger trees.

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
│   ├── chess_logic.h   # FEN parsing, UCI move application, castling normalization
│   ├── san_convert.h   # SAN ↔ UCI move conversion
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
│   ├── chess_logic.c   # Minimal chess rules for FEN/UCI, castling normalization
│   ├── san_convert.c   # SAN ↔ UCI move conversion
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
   │  Stockfish    │                      │  1. Lichess DB   │
   │  MultiPV      │                      │     (min_games)  │
   │  (10 → 2)     │                      │  2. Maia fills   │
   │  → eval filter│                      │     remaining    │
   │  → Lichess    │                      │     mass         │
   │    enrichment │                      │  3. Engine top-1 │
   │               │                      │  → batch eval    │
   │               │                      │  → mass target   │
   │               │                      │    (95% → 50%)   │
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
              tree_calculate_eca()   → accumulated_eca (centipawns)
                           │
                           ▼
              build_repertoire_recursive()
                  Our nodes: eval + weight × avg_cpl_per_opp_turn
                  Opp nodes: traverse all children
                           │
                           ▼
              extract_lines()  → root-to-leaf paths
                           │
                           ▼
              JSON / PGN export
```

---

## Known Issues and Future Improvements

### Leaf Node ECA

Leaf nodes contribute `accumulated_eca = 0` (since `local_cpl` requires
children to compute).  This means lines pruned early look "less tricky"
simply because they have less depth, not because the opponent plays better
there.  Transposition leaves now borrow ECA from the canonical node (see
above), but other leaf types (max-depth, cumP-pruned) still contribute
zero.

A future improvement could estimate leaf ECA from the node's eval or
from the average ECA of nearby non-leaf nodes.

### Probability Normalization After Blended Sources

When both Lichess and Maia contribute children at an opponent node, the
`move_probability` values come from different distributions and may not
sum to 1.0.  The ECA formula weights by `move_probability`:

```
future += child.move_probability × child.accumulated_eca
```

If probabilities sum to 0.75, the remaining 0.25 mass is implicitly
treated as "opponent plays a move with zero ECA contribution."  This
underweights the ECA signal at every opponent node and the effect
compounds through the tree.

With `--maia-only` (the default), Maia probabilities are more
self-consistent but still capped at the mass target (e.g. 50% deep in
the tree), leaving substantial unnormalized mass.

A fix would be to normalize `move_probability` across all children after
all sources (Lichess, Maia, engine injection) have contributed, by
dividing each by the sum.  This would require a normalization pass at
the end of `build_opponent_move` after all children are created.

Alternatively, the ECA accumulation could divide by `mass_covered`
instead of assuming probabilities sum to 1.0.

### DFS Order Bias on Interrupted Builds

The build is DFS, so earlier children are fully explored before later
ones.  If interrupted (SIGINT), earlier children have deeper subtrees
and accumulate more ECA signal.  Resume partially mitigates this, but
any time-limited build has an inherent bias toward first-explored
branches.

### `subtree_opp_plies` for Transposition Leaves

When a transposition leaf borrows `subtree_opp_plies` from the canonical
node, the value reflects the canonical path's depth, not the
transposition path's depth.  A position reached 4 ply later via
transposition would have a different number of opponent plies from root,
but the borrowed value comes from the canonical expansion context.

### Equivalence Ring Serialization

Equivalence rings ARE serialized.  `node_to_cjson` writes a
`next_equivalent_id` field for each node in a ring, and the loader
(`cjson_to_node`) collects `(node, target_id)` pairs which
`load_ctx_resolve` wires back up after the full tree is parsed.
Trees loaded from JSON therefore have their equivalence rings fully
restored without needing a rebuild.
