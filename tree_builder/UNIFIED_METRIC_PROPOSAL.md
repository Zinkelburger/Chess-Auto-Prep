# Proposal: Win-Probability-Delta ECA

## Problem Statement

The current algorithm maintains two separate quantities that get combined
at different stages:

1. **Accumulated ECA** (in centipawns) — computed bottom-up during accumulation
2. **Engine eval** (converted to win probability) — mixed in during selection

This creates three problems:

- **Inconsistency at our-move nodes:** Accumulation uses `max(child_eca)`,
  assuming we pick the trickiest move. Selection uses `α × eval + (1-α) × eca`,
  often picking a different move. The parent's ECA is based on a move we might
  never play.

- **ECA ignores absolute evaluation:** A 30cp "blunder" that leaves the
  opponent at +0.5 and a 30cp blunder that pushes them to -2.0 contribute
  equally to ECA. The algorithm can't distinguish between inconsequential
  inaccuracies in comfortable positions and real mistakes in critical positions.

- **Late normalization:** ECA (centipawns) and eval (win probability) are on
  different scales. They get jammed together at selection time via normalization
  (`norm_eca = eca / max_sibling_eca`), which is context-dependent and hides
  the absolute magnitude of trickiness.

## Proposed Solution

Replace centipawn-based ECA with a **win-probability-delta** ECA. Everything
is measured in the same units (win probability, [0, 1]) from the bottom of the
tree to the top. One number per node, one formula, no late normalization.

The names `local_cpl`, `accumulated_eca`, and `has_eca` are kept — the concept
is the same (Expected Centipawn Advantage), just measured in win-probability
space instead of raw centipawns.

### Core idea

Instead of measuring "how many centipawns does the opponent lose," measure
"how much win probability does the opponent hand us by playing natural moves
instead of the best move."

A 50cp blunder in an equal position (shifting win prob from 0.50 to 0.55) is
worth more than a 50cp blunder when the opponent is already lost (shifting win
prob from 0.12 to 0.13). The sigmoid naturally compresses large eval
differences, which is what we want — a blunder that matters practically
contributes more than one that doesn't change the outcome.

---

## Detailed Design

### Win probability function

Same sigmoid already used in the codebase:

```
wp(cp) = 1 / (1 + e^(-0.00368208 × cp))
```

This maps centipawns to [0, 1] from White's perspective. Reference values:

```
wp(0)   = 0.500    wp(100) = 0.591    wp(200) = 0.676    wp(300) = 0.751
wp(-100)= 0.409    wp(-200)= 0.324    wp(-300)= 0.249
```

The sigmoid spans 0.249–0.751 across the ±300cp eval window. This is not
linear — it's substantially S-shaped. But both `eval_us` and
`accumulated_eca` are computed through the same sigmoid, so they share
the same scale and compression characteristics. See the Scale Validation
section for why this makes normalization unnecessary.

For our perspective:

```
wp_us(cp, is_white_to_move, play_as_white):
    eval_white = is_white_to_move ? cp : -cp
    wp_white = wp(eval_white)
    return play_as_white ? wp_white : (1 - wp_white)
```

### Win probability from mover's perspective

`wp_for_mover` converts a child's eval to win probability from the **current
node's side-to-move perspective**. Since child evals are from the child's
side-to-move perspective (the opponent of the current mover), a sign flip is
needed:

```
wp_for_mover(child_eval_cp) = 1.0 - wp(child_eval_cp)
```

Concretely: `child.engine_eval_cp` is from the next-STM perspective (the
mover's opponent). `wp(child_eval_cp)` gives the opponent's win probability.
`1 - wp(child_eval_cp)` gives the mover's win probability. The mover wants
to **maximize** this value, so the best move is the one with the highest
`wp_for_mover`.

This is equivalent to `wp(-child_eval_cp)` since `wp(-x) = 1 - wp(x)`.

### Local trickiness (replaces centipawn-based `local_cpl`)

At each node, compute how much win probability the side-to-move hands the
other side by playing database moves instead of the best move:

```
best_wp = max(wp_for_mover(child.engine_eval_cp) for all children)

local_cpl = Σ(prob_i × max(0, best_wp - wp_for_mover(child_i.engine_eval_cp)))
```

`local_cpl` is in [0, 1] — it represents the expected fraction of win
probability the mover gives away. In practice it's usually 0.00–0.10 (0–10
percentage points of win probability).

Children with `move_probability < 0.01` are excluded from the **delta sum**
but not from the **best_wp computation**. This means the baseline "best move"
could be a rare engine line (say 0.3% probability) that almost nobody plays.
All common moves are then measured against a "best" that the opponent rarely
finds. This is intentional: the purpose of local_cpl is "how much win
probability do opponents lose by not finding the best move?" If a strong
move exists but is hard to find, that makes the position tricky — exactly
what we want to measure. This behavior is preserved from the current code.

**Discovery moves:** `--discovery` adds engine-only moves with
`move_probability = 0.0`. These are excluded from the delta sum (prob < 0.01)
but included in the best_wp baseline. This means discovery moves can set a
superhuman baseline, inflating local_cpl at every position with a discovery
move. In the old system, sibling normalization partially compensated (all
siblings inflated → relative ranking preserved). In the new system, the
inflation is absolute.

This is a pre-existing behavior, not introduced by this proposal. If it
proves problematic, the fix is to also exclude discovery moves (prob = 0.0)
from the best_wp computation. This would change local_cpl from "how much
do opponents lose relative to the best available move" to "how much do
opponents lose relative to the best move humans actually play" — arguably
more appropriate for a metric about human blunder tendency.

**Note:** `compute_local_eca()` runs on every node, but `local_cpl` is only
consumed at opponent-move nodes (where it's added to `accumulated_eca`) and
leaf nodes. At our-move internal nodes, it's computed but not used in the
accumulation — the value measures the mover's blunder tendency, which is
irrelevant since we choose our own moves. The wasted computation is
negligible (one sigmoid per child) and keeping the code path uniform is
simpler than branching.

### Accumulated ECA (same name, new units)

Bottom-up DFS, same structure as current ECA, but now everything is in
win-probability-delta units. The accumulation pass receives the full
`RepertoireConfig` (or at minimum: `eval_weight`, `eval_guard_threshold`,
`max_eval_loss_cp`) so that our-move filtering matches the selection phase
exactly.

**Leaf nodes:**
```
accumulated_eca = local_cpl
```

(Usually 0 for true leaves with no children.)

**Opponent-move nodes:**
```
accumulated_eca = local_cpl + Σ(prob_i × child_i.accumulated_eca)
```

The local trickiness at this node plus the probability-weighted future
trickiness in each child subtree. Same formula as current ECA, just in
different units.

**Our-move nodes:**
```
// Apply the same filters as selection:
// 1. Compute best_child_cp among all children
// 2. Exclude children > max_eval_loss_cp worse than best
// 3. Exclude children with wp_us < eval_guard_threshold
// 4. If ALL children are excluded, re-score all children with the
//    blended formula (no filters) and pick the best

for each surviving child:
    child_score = α × wp_us(child.eval) + (1-α) × child.accumulated_eca

best_child = argmax(child_score)
accumulated_eca = best_child.accumulated_eca
```

This is the key change. Instead of `max(child.accumulated_eca)`, we select the
child using the blended score — the same policy that selection would use, with
the same filters. The accumulated value propagated upward reflects the
trickiness of the move we'd actually play under the current scoring policy.

**Fallback consistency:** When all children are filtered out, the fallback
also uses blended scoring (not `max`). This keeps the accumulation formula
consistent in all paths. Selection has the same fallback structure: when no
children pass filters, it re-evaluates all children and picks the best
blended score. Both paths agree.

No circular dependency: by the time we're at an our-move node, all children's
`accumulated_eca` and `eval` are already computed (post-order DFS).

### Selection (replaces `build_repertoire_recursive` scoring)

At our-move nodes during the top-down traversal:

```
for each child (after eval-guard and max-eval-loss filtering,
                with "if all fail, re-score all with blended formula" fallback):
    score = α × wp_us(child.eval) + (1-α) × child.accumulated_eca

select argmax(score)
```

This is now **identical** to what the accumulation phase computed. There's no
normalization step (`norm_eca = eca / max_sibling_eca`) because
`accumulated_eca` is in win-probability-delta units — the same unit space
as `wp_us`. Both derive from the same sigmoid, making them naturally
comparable without rescaling.

**Critical change:** Selection must read evals from `child->engine_eval_cp`
(the TreeNode field), not from the database via `rdb_get_eval()`. The
accumulation pass reads from TreeNode, so selection must use the same source
to guarantee they pick the same child. See the Eval Source Consistency section.

The `α` parameter (`--eval-weight`) still controls the tradeoff:
- `α = 1.0`: pure objective eval (pick the best engine move)
- `α = 0.0`: pure trickiness (pick the line where opponents blunder most)
- `α = 0.4` (default): blend

The `score_position()` fallback (4-weight formula with ease, winrate,
sharpness) still serves as a fallback when `has_eca` is false for all
children (e.g., no engine evals available).

---

## Scale Validation

The claim "no normalization needed" rests on `accumulated_eca` staying in a
range comparable to win probability [0, 1].

### Why the scales are naturally compatible

The argument does **not** depend on the sigmoid being linear (it isn't —
it spans 0.249–0.751 across ±300cp). The argument is structural:

1. `wp_us(child.eval)` is a win probability in [0, 1], computed through `wp()`.
2. `accumulated_eca` is a sum of win-probability deltas, also computed
   through `wp()`.

Both quantities live in the same unit space because they derive from the same
sigmoid. When we compute `α × wp_us + (1-α) × accumulated_eca`, the two
terms are comparing apples to apples: win probability vs. expected win
probability gained from opponent mistakes.

The sigmoid's S-shape compresses both quantities equally: `eval_us` values
cluster in [0.35, 0.55] near equality and spread toward 0/1 at extreme evals,
while `accumulated_eca` stays bounded because each local delta is also
compressed by the sigmoid.

### Empirical validation (Three Knights Petrov, 954 nodes)

Simulated wp-delta accumulation on a real tree:

| Metric                    | Value            |
|---------------------------|------------------|
| Nodes with wp_acc > 0     | 121 / 954        |
| Range                     | [0.0000, 0.4361] |
| Non-zero mean             | 0.2303           |
| Non-zero median           | 0.2864           |
| Root value                | 0.3772           |

For comparison, `wp_us` at decision nodes ranges from ~0.35 to ~0.50.
With `α = 0.40`, eval contributes 0.14–0.20 and trickiness contributes
0.60 × 0.0–0.26. These are comparable — trickiness can meaningfully
influence decisions without dominating them.

### Dynamic range: why trickiness naturally dominates eval

A concern: if `accumulated_eca` has a wider range than `wp_us` among
siblings, trickiness dominates the blend regardless of α.

This is real, but it's a property of chess positions, not a formula bug.
At a decision node, the formula ranks siblings by
`α × eval_us + (1-α) × accumulated_eca`. What determines the winner
isn't the absolute values — it's the **differences between siblings**.
The term with more variance among siblings dominates the ranking,
regardless of the weight.

**Why eval spreads so little among siblings.** By the time we're scoring,
the filters have already removed bad moves: `--max-eval-loss 50` removes
anything > 50cp worse than the best sibling, and `--eval-guard 0.35`
removes anything objectively terrible. The surviving candidates are all
"reasonable moves in the same position," clustered in a narrow eval band.
Typical spread: 0.01–0.05 wp (10–50cp).

**Why trickiness spreads a lot.** One sibling leads to sharp complications
where opponents blunder 15% wp per move. Another simplifies to a boring
endgame where every move is obvious. The subtree structures are radically
different even when the immediate evals are similar. Typical spread:
0.10–0.40 wp.

This means trickiness has 5–10× more variance at a typical decision
point, so it dominates the ranking. No formula change fixes this because
it's inherent to the problem: acceptable moves have similar evals (by
construction — the filters ensured this), but their downstream trickiness
varies widely.

**What α actually controls.** α doesn't give a "40/60 blend" in the
sense that eval decides 40% of outcomes. What it does:

- **Tiebreaker:** When two moves have similar trickiness, better eval
  wins. This works perfectly.
- **Override threshold:** Higher α means a tricky move needs a bigger
  trickiness edge to beat a move with better eval. Lower α means even
  a small trickiness advantage wins.
- **Extremes work as expected:** α = 0.0 picks the trickiest move.
  α = 1.0 picks the best eval. The transition between these extremes
  is where α has its effect.

The eval guard and max-eval-loss filters do the heavy lifting on
position quality. α fine-tunes how much trickiness can override an eval
edge within the passing set.

### The new system gives eval MORE influence, not less

The concern above applies to both the old and new systems. But empirically,
the old normalization makes it **worse**.

Sibling normalization (`eca / max_sibling_eca`) always maps the trick
range to [0, 1]. At typical decision points, `wp_us` varies by only
0.01–0.12 (10–120cp of eval spread). The normalized trick range is always
1.0. With α = 0.40, eval's effective influence is:

```
eval_influence = (0.40 × eval_range) / (0.40 × eval_range + 0.60 × 1.0)
```

Across 19 decision points in the Three Knights Petrov:

| System               | Avg eval influence | Advertised |
|----------------------|--------------------|------------|
| Old (normalized ECA) | **4.7%**           | 40%        |
| New (wp-delta ECA)   | **23.6%**          | 40%        |
| Ideal (equal ranges) | 40.0%              | 40%        |

The old normalization stretches trick to [0, 1] at every node, making it
dominate. The new system's accumulated_eca among siblings has a narrower
spread (typically 0.0–0.4), giving eval 5× more influence than the old
system.

Neither system gives eval exactly 40% influence — the factor with more
variance always dominates. But the new system is significantly closer to
the user's intent.

### Validation caveat

This empirical data comes from a single opening (Three Knights Petrov, a
relatively quiet line). Sharp tactical openings (Sicilian, King's Indian,
gambits) could produce different distributions — potentially higher local
trickiness where opponents face many tactical traps, or lower where lines
are more forced.

**Before merging, validate on 3–5 diverse openings** spanning quiet
positional (e.g., London System), sharp tactical (e.g., Sicilian Najdorf),
and gambit lines (e.g., King's Gambit). The mathematical argument for scale
compatibility is structural (same sigmoid → same units), but the practical
range of `accumulated_eca` should be confirmed across styles.

### Unbounded accumulation (no cap)

`accumulated_eca` is not bounded in [0, 1]. At opponent nodes, each layer
adds its `local_cpl` and passes through probability-weighted children. With
enough opponent nodes with high local trickiness and high continuation
probability, the sum can theoretically exceed 1.0.

**Why this is not capped.** Clamping at 1.0 would destroy ranking information
exactly where it matters most: two subtrees with raw values 1.2 and 2.5 (one
mildly tricky, one a minefield) would become indistinguishable. The whole
point of ECA is to rank subtrees by trickiness, and a cap kills
discrimination in genuinely tricky openings.

In practice, geometric damping limits growth. Opponent and our-move nodes
alternate roughly every ply. At our-move nodes, nothing is added — we pass
through one child's value. The accumulation at opponent nodes forms a
geometric series:

```
acc_N = local × (1 - p^N) / (1 - p)
```

where `p` is the average continuation probability and `N` is the number of
opponent nodes. This converges to `local / (1 - p)` as N → ∞, but for
finite trees the values are lower:

| local_cpl | cont. prob | opp. nodes | accumulated | infinite limit |
|-----------|------------|------------|-------------|----------------|
| 0.03      | 0.5        | 8          | 0.060       | 0.060          |
| 0.05      | 0.5        | 10         | 0.100       | 0.100          |
| 0.10      | 0.8        | 10         | 0.446       | 0.500          |
| 0.15      | 0.9        | 10         | 0.977       | 1.500          |

The first two rows converge quickly (low p). The last row (p = 0.9) is only
65% of the infinite limit at 10 opponent nodes — it would take ~30 opponent
nodes to approach 1.50. In practice, trees rarely have 30 consecutive
opponent nodes with both high local trickiness AND 90% continuation
probability.

Reaching accumulated_eca > 1.0 requires extreme conditions. If it does
happen, it reflects a genuinely extraordinary trickiness level — the eval
guard still prevents picking objectively terrible positions regardless of
trickiness score.

If multi-opening validation reveals that unbounded values cause α-tuning
problems (e.g., trickiness always dominates in sharp openings), the
mitigation is to retune α, not to cap the metric. Alternatively, a log
transform (`log(1 + acc)`) could compress large values while preserving
ordering, but this should only be added if a real problem is observed.

---

## What This Fixes

### 1. The absolute-evaluation problem (the "Known Issue")

Current ECA: a 30cp blunder always contributes 30cp to local_cpl, regardless
of position.

New metric: a 50cp blunder near equality (0.50 → 0.55 wp) contributes ~0.046.
A 50cp blunder when already winning (0.85 → 0.87 wp) contributes ~0.016.
A 50cp blunder when losing (0.15 → 0.17 wp) contributes ~0.016.

The sigmoid makes blunders in critical (near-equal) positions worth more than
blunders in already-decided positions. This directly addresses the Alekhine
example from the algorithm document.

### 2. The accumulation/selection inconsistency

Current: accumulation uses `max(child_eca)`, selection uses composite score
with different filters. These pick different children, so the parent's ECA
is based on a move that might never be played.

New: accumulation and selection use the same formula with the same filters
(eval guard, max-eval-loss, blended fallback). The accumulated value
propagated upward reflects the actual move we'd play.

### 3. No normalization needed

Current: ECA is in centipawns, eval is in win probability. They get jammed
together via `norm_eca = eca / max_sibling_eca`, which is context-dependent
(a node's normalized ECA changes if you add a sibling).

New: both components are in win-probability space. No normalization step.
A node's score is stable regardless of what siblings exist. (Validated
empirically — see Scale Validation section.)

### 4. Depth decay is less necessary (but still available)

In the current system, depth decay was partially justified as a "confidence
penalty" for deep evaluations. The sigmoid helps in positions where deep
evals are extreme: a blunder at +500cp contributes less wp-delta than at
equality.

However, the sigmoid compresses based on eval magnitude, not depth. In long
theoretical lines that maintain near-equal evals deep into the tree (Najdorf,
Berlin, Marshall), the sigmoid doesn't dampen deep contributions at all. In
such lines, 10+ opponent nodes each contribute full-strength local_cpl, and
only probability weighting provides damping. In forcing lines with one
dominant response (prob ≈ 0.9), even probability damping is weak.

`--depth-decay` is kept as an option (applied as `decay^depth × local_cpl`)
and defaults to 1.0. Users with deep forcing-line repertoires may benefit
from setting it below 1.0 to prevent deep opponent nodes from dominating
the signal. The default of 1.0 is appropriate for typical opening trees
where eval-window pruning limits depth.

---

## Known Tradeoff: Parameter-Dependent Accumulation

### The regression

In the current system, ECA is computed once with `max(child_eca)` —
independent of `eval_weight`, `eval_guard`, and `max_eval_loss`. You can
experiment with different α values at selection time without recomputing
the ECA tree.

The proposal bakes α into the accumulation pass. Changing `--eval-weight`
from 0.40 to 0.60, or adjusting `--eval-guard`, requires a full ECA
recomputation (post-order DFS over all nodes).

### Why this is acceptable

The ECA DFS is O(N) simple arithmetic — one sigmoid evaluation and a
comparison per child per node. For a 1000-node tree this takes <1ms. The
expensive pipeline stages are:

| Stage                | Typical time |
|----------------------|-------------|
| Lichess API queries  | 30–120s     |
| Stockfish batch eval | 60–300s     |
| Maia inference       | 5–30s       |
| **ECA DFS**          | **<1ms**    |

Re-running ECA when α changes is free relative to the pipeline. The benefit
(accumulation/selection consistency) outweighs the cost.

### Alternative: max(child_eca) remains available

Setting `α = 0.0` in the config makes the blended formula degenerate to
`argmax(child.accumulated_eca)` — equivalent to the current `max` behavior.
Users who want parameter-free ECA for quick A/B testing can compute with
`α = 0.0` and vary α only at selection time, accepting the
accumulation/selection mismatch.

---

## Expected vs. Potential Trickiness

A nuance worth acknowledging: `max(child_eca)` and the blended selection
answer different questions.

- **max (current):** "What's the *potential* trickiness of this subtree if
  we play the trickiest available move?" This is a parameter-free upper
  bound. α then controls how much of that potential is realized.

- **blended (proposed):** "What's the *expected* trickiness of the move
  we'd actually play under this scoring policy?" This depends on α and
  the filter settings.

Neither is inherently more "honest" — they model different things. The
proposal prefers *expected* because it prevents a parent's ranking from
being inflated by a child that selection would never pick (e.g., a tricky
but objectively terrible move that fails the eval guard). But the *potential*
framing has the virtue of parameter independence.

The tradeoff is: consistency-with-selection vs. parameter-independence. This
proposal chooses consistency, on the grounds that accumulated_eca's purpose
is to rank moves at selection time, and a ranking signal based on moves we'd
never play is misleading.

---

## Avoiding Filter Duplication

The consistency guarantee requires the filter logic (eval guard, max-eval-loss,
"allow all" fallback) to be identical in accumulation and selection. Duplicating
this logic in two places is a maintenance trap: a future change to one site
could silently break consistency.

The fix: extract the shared logic into a helper function that both call:

```c
typedef struct {
    TreeNode *child;
    double score;
    double accumulated_eca;
} ScoredChild;

// Scores all children at an our-move node, applying filters.
// Returns the number of passing children. best_out is the winner.
int score_our_move_children(TreeNode *node,
                            const RepertoireConfig *config,
                            ScoredChild *best_out);
```

Both `calculate_eca_recursive` (accumulation) and `build_repertoire_recursive`
(selection) call `score_our_move_children`. Any future filter change
automatically applies to both. This eliminates the duplication risk and makes
the consistency guarantee compile-time enforced rather than convention-based.

---

## Eval Source Consistency

### The problem

The current selection code in `repertoire.c` reads evals from the database
first, falling back to `TreeNode.engine_eval_cp`:

```c
if (!rdb_get_eval(db, child->fen, &eval_cp, &edepth)) {
    if (child->has_engine_eval) eval_cp = child->engine_eval_cp;
}
```

The accumulation code reads from `TreeNode.engine_eval_cp` only (no database
access). If the database has a different eval — from a previous run at
different depth, or from a quick-eval vs full-eval pass — accumulation and
selection use different values and may pick different moves, defeating the
consistency guarantee.

### The fix

Selection should read evals from `TreeNode.engine_eval_cp` exclusively.
The pipeline already syncs DB evals to TreeNode fields via
`load_evals_callback` (BFS traversal) before ECA runs:

```
Stage 1: Batch engine eval → writes to DB + TreeNode
          load_evals_callback → copies DB → TreeNode for any misses
Stage 2: Ease calculation
Stage 3: ECA calculation    → reads TreeNode.engine_eval_cp
Stage 4: Move selection     → should also read TreeNode.engine_eval_cp
```

The `rdb_get_eval` calls in `build_repertoire_recursive` should be replaced
with direct reads from `child->engine_eval_cp`. This is a small change to
`repertoire.c` (~6 call sites) and eliminates the divergence risk entirely.

### DFS eval-window pruning

`build_repertoire_recursive` prunes subtrees where `eval_us` is outside
`[min_eval_cp, max_eval_cp]` — it stops recursing, not outputting repertoire
moves for deep positions in extreme eval ranges. The accumulation pass
traverses the entire tree and doesn't stop at these boundaries.

This is not an accumulation/selection inconsistency: the pruning doesn't
change which child is **selected** at a decision node — it changes how
**deep** the selection DFS explores. The accumulated_eca at a decision
node correctly reflects the trickiness of the line we'd choose, even if
selection later stops outputting moves in that line's extreme tail.

If desired, the accumulation pass could mirror the eval-window pruning
(treating pruned subtrees as having accumulated_eca = 0), but the current
behavior is defensible: the trickiness exists even if we don't generate
repertoire lines for the deepest positions.

### DB update workflow

The current code reads from DB first deliberately — the DB may have newer,
deeper evaluations from a subsequent Stockfish run. By switching to
TreeNode-only reads, you lose the ability to update evals in the database
and see their effect without re-running the full pipeline.

This is trivially mitigated: re-run `load_evals_callback` (a BFS traversal
that copies DB → TreeNode) before ECA + selection. It takes milliseconds.
The pipeline should call `tree_traverse_bfs(tree, load_evals_callback, db)`
before ECA whenever DB evals may have changed. This is already the pipeline's
behavior — the only change is that selection no longer independently reads
from the DB, which is the source of the consistency bug.

---

## What Doesn't Change

- **Tree building**: Completely unchanged. Lichess explorer queries, Maia
  fallback, discovery pass — all the same.

- **Engine evaluation**: Still batch-evaluate with Stockfish, same caching.

- **Ease metric**: Still computed separately for backward compatibility
  with the Flutter app.

- **All binary filters**: eval guard, max-eval-loss, min/max eval DFS
  pruning, probability thresholds — all unchanged. Now consistently applied
  in both accumulation and selection.

- **Line extraction**: Follows selected moves, trims trailing opponent
  moves — unchanged.

- **CLI parameters**: `--eval-weight`, `--eval-guard`, `--max-eval-loss`,
  `--min-eval`, `--max-eval`, `--depth-decay` all work the same way.

- **Field names**: `local_cpl`, `accumulated_eca`, `has_eca` keep their
  names for backward compatibility. The units change from centipawns to
  win-probability deltas. See the Naming Caveat section.

---

## Naming Caveat

"CPL" stands for "Centipawn Loss" — but the values are no longer in
centipawns. Keeping the name `local_cpl` for a win-probability-delta
quantity is misleading. Anyone reading the code in six months will be
confused.

The proposal keeps the names to minimize churn (struct field, JSON key,
Flutter app references), but this is a pragmatic choice, not a principled
one. A follow-up rename is recommended:

| Current name       | Suggested rename       | Reason                          |
|--------------------|------------------------|---------------------------------|
| `local_cpl`        | `local_wp_delta`       | Describes the actual units      |
| `accumulated_eca`  | `accumulated_wp_delta` | Or keep — "ECA" is opaque enough that the unit change doesn't clash |

The JSON field names can stay as-is (the `eca_units` field disambiguates),
or be renamed in the version 2 format. The struct fields should be renamed
in the implementation to avoid confusion in C code.

---

## What Changes

### Data structures (`node.h`)

```c
// Remove (no longer needed):
double local_q_loss;
double accumulated_q_eca;

// Keep (same names, new units):
double local_cpl;            /* wp delta lost by mover at this node */
double accumulated_eca;      /* total expected wp delta in subtree */
bool   has_eca;              /* whether values are computed */
```

The Q-loss variants (`local_q_loss`, `accumulated_q_eca`) are removed.

**Why drop Q-loss instead of the win-probability metric?** The codebase has
two sigmoid functions:

- `cp_to_win_prob()` — coefficient 0.00368208, maps to [0, 1]. This is the
  Lichess win-probability model, calibrated against millions of real game
  outcomes.
- `eca_cp_to_q()` — coefficient 0.004, maps to [-1, 1] via `2×wp - 1`.
  This is an uncalibrated alternative with more aggressive compression
  (a 100cp difference at equality produces Q-delta ≈ 0.19 vs wp-delta
  ≈ 0.09).

The proposal consolidates on the Lichess-calibrated sigmoid because: (a) it's
empirically grounded in real game data, (b) it's already used throughout the
codebase for all eval-to-wp conversions, and (c) having one sigmoid means
one compression curve to reason about. The Q-loss variant was an experimental
parallel metric that was never promoted to primary. Removing it simplifies
the codebase without losing anything — the win-probability sigmoid now serves
the same role (nonlinear compression of centipawn differences).

### API change (`tree.h`)

```c
// Current:
size_t tree_calculate_eca(Tree *tree, bool play_as_white, double depth_discount);

// New — takes full config for filter consistency:
size_t tree_calculate_eca(Tree *tree, const RepertoireConfig *config);
```

The function now receives `eval_weight`, `eval_guard_threshold`,
`max_eval_loss_cp`, and `play_as_white` from the config so that the
accumulation pass applies the same filters as selection. If a simpler
signature is preferred, a small subset struct works too.

### ECA computation (`tree.c`)

`compute_local_eca()` changes to use win-probability deltas.

**Note on helper functions:** The code below uses `win_probability()`,
`eval_for_us()`, and `wp_us()` — these don't exist in `tree.c` today.
They need to be implemented (or `cp_to_win_prob` from `repertoire.c`
needs to be moved to a shared location). `eval_for_us()` computes
centipawn eval from our perspective; `wp_us()` converts that to win
probability. The exact signatures will be defined during implementation.
The `score_our_move_children()` helper (see Avoiding Filter Duplication)
would also wrap these.

```c
static void compute_local_eca(TreeNode *node) {
    if (!node || node->children_count == 0) return;

    double best_wp = -1.0;
    bool has_any = false;
    for (size_t i = 0; i < node->children_count; i++) {
        if (!node->children[i]->has_engine_eval) continue;
        // wp_for_mover = 1.0 - wp(child_eval): mover wants high value
        double mover_wp = 1.0 - win_probability(node->children[i]->engine_eval_cp);
        if (mover_wp > best_wp) best_wp = mover_wp;
        has_any = true;
    }
    if (!has_any) return;

    double sum = 0.0;
    for (size_t i = 0; i < node->children_count; i++) {
        TreeNode *child = node->children[i];
        if (!child->has_engine_eval) continue;
        if (child->move_probability < 0.01) continue;
        double mover_wp = 1.0 - win_probability(child->engine_eval_cp);
        double delta = best_wp - mover_wp;
        if (delta < 0) delta = 0;
        sum += child->move_probability * delta;
    }
    node->local_cpl = sum;
}
```

`calculate_eca_recursive()` changes at our-move nodes to use blended scoring
with full filter mirroring. **The fallback also uses blended scoring** (not
`max`) so the formula is consistent in all code paths:

```c
static size_t calculate_eca_recursive(TreeNode *node,
                                       const RepertoireConfig *config) {
    if (!node) return 0;
    size_t count = 0;

    for (size_t i = 0; i < node->children_count; i++)
        count += calculate_eca_recursive(node->children[i], config);

    compute_local_eca(node);

    bool is_our_move = (node->is_white_to_move == config->play_as_white);

    if (node->children_count == 0) {
        node->accumulated_eca = node->local_cpl;

    } else if (is_our_move) {
        // Mirror selection filters: max-eval-loss + eval guard
        int best_child_cp = -100000;
        for (size_t i = 0; i < node->children_count; i++) {
            if (!node->children[i]->has_engine_eval) continue;
            int cp_us = eval_for_us(node->children[i], config->play_as_white);
            if (cp_us > best_child_cp) best_child_cp = cp_us;
        }

        double best_score = -1e9;
        double best_eca = 0.0;
        int passing = 0;

        for (size_t i = 0; i < node->children_count; i++) {
            TreeNode *child = node->children[i];
            if (!child->has_eca) continue;

            int cp_us = eval_for_us(child, config->play_as_white);
            if (cp_us < best_child_cp - config->max_eval_loss_cp) continue;

            double eval_us = wp_us(child, config->play_as_white);
            if (eval_us < config->eval_guard_threshold) continue;

            passing++;
            double score = config->eval_weight * eval_us
                         + (1.0 - config->eval_weight) * child->accumulated_eca;
            if (score > best_score) {
                best_score = score;
                best_eca = child->accumulated_eca;
            }
        }

        // Fallback: all children filtered out → re-score all with blended
        // formula (no filters), same as selection's "if all fail, allow all"
        if (passing == 0) {
            best_score = -1e9;
            for (size_t i = 0; i < node->children_count; i++) {
                TreeNode *child = node->children[i];
                if (!child->has_eca) continue;
                double eval_us = wp_us(child, config->play_as_white);
                double score = config->eval_weight * eval_us
                             + (1.0 - config->eval_weight) * child->accumulated_eca;
                if (score > best_score) {
                    best_score = score;
                    best_eca = child->accumulated_eca;
                }
            }
        }

        node->accumulated_eca = best_eca;

    } else {
        // Opponent: local trickiness + probability-weighted future
        double future = 0.0;
        for (size_t i = 0; i < node->children_count; i++) {
            TreeNode *child = node->children[i];
            if (!child->has_eca) continue;
            future += child->move_probability * child->accumulated_eca;
        }
        node->accumulated_eca = node->local_cpl + future;
    }

    node->has_eca = true;
    count++;
    return count;
}
```

### Selection (`repertoire.c`)

`build_repertoire_recursive()` simplifies — no normalization step, and
eval reads from TreeNode instead of database:

```c
// At our-move nodes, for each child (after filtering):
// Read eval from TreeNode directly (not rdb_get_eval) for consistency
int eval_cp = child->has_engine_eval ? child->engine_eval_cp : 0;
int eval_white = child->is_white_to_move ? eval_cp : -eval_cp;
double eval_us = config->play_as_white
    ? cp_to_win_prob(eval_white)
    : 1.0 - cp_to_win_prob(eval_white);

double score = config->eval_weight * eval_us
             + (1.0 - config->eval_weight) * child->accumulated_eca;

// Pick argmax(score)
```

The `rdb_get_eval` calls in the scoring loop should be replaced with direct
`child->engine_eval_cp` reads (~6 call sites in `build_repertoire_recursive`).

### Serialization (`serialization.c`)

**Format version bump:** Change `"version": 1` to `"version": 2` and add
an `"eca_units"` field:

```c
cJSON_AddNumberToObject(root, "version", 2.0);
cJSON_AddStringToObject(root, "eca_units", "wp_delta");
```

JSON output drops Q-loss fields:

```
"local_q_loss"       → removed
"accumulated_q_eca"  → removed
```

`local_cpl` and `accumulated_eca` keep their field names. Values will be
small decimals (typically 0.0–0.5 in quiet openings, potentially higher
in sharp ones) instead of centipawns.

**Breaking change for consumers:** The Flutter app currently displays
these values as centipawns (e.g., "ECA: 38.2 cp"). It needs to check the
format version and adjust display:
- Version 1: display as centipawns (e.g., "38.2 cp")
- Version 2: display as percentage (e.g., "38%" from value 0.38)

Alternatively, the app can check for the `eca_units` field and format
accordingly. Until the app is updated, it will display small decimal
numbers where it used to show centipawns — functionally wrong for display
but correct for ordering (higher = trickier still holds).

**Configuration dependency:** The `accumulated_eca` values in version 2
JSON are artifacts of the `eval_weight`, `eval_guard`, and `max_eval_loss`
used during computation. Two trees computed with different α values have
different `accumulated_eca` for the same positions. The JSON does not
record which parameters produced the values. If cross-run comparison is
needed, the config should be stored alongside the tree (the `config`
block in JSON already records tree-building parameters; it should be
extended to include repertoire parameters).

---

## Pre-existing Issue: Unrenormalized Probabilities

At opponent nodes, child probabilities after the `move_probability >= 0.01`
filter don't sum to 1.0. This means:

```
accumulated_eca = local_cpl + Σ(prob_i × child_i.accumulated_eca)
```

The sum systematically underweights future contributions. This is a
pre-existing behavior in the current code (not introduced by this proposal).

**Interaction with normalization removal:** In the old system, sibling
normalization (`eca / max_sibling_eca`) partially masked this issue because
only relative ranking mattered, not absolute magnitude. In the new system,
absolute values matter more — a node where top moves cover 95% of games
will accumulate more future ECA than an otherwise-identical node where top
moves cover only 70%.

However, this effect is arguably correct: positions where the opponent has
many diffuse responses (low probability sum) genuinely have less exploitable
structure than positions with one dominant line. The un-renormalized
semantics say "we weight future trickiness by the probability of actually
reaching it," which is the right thing to measure.

If desired, renormalizing probabilities is a one-line fix at the summation
point, but the current semantics are defensible.

---

## Mock Scenarios

These scenarios use the real Three Knights Petrov tree (954 nodes, playing
as Black) with `eval_weight = 0.40`, `eval_guard = 0.35`, `max_eval_loss = 50`.

### Scenario 1: Depth-2 Decision (After 1...Nxe4 2.Be2)

Black chooses a response. Old system uses sibling-normalized ECA, new system
uses raw wp-delta accumulated_eca.

| Move | eval_cp | wp_us | old_eca | old_norm | old_score | wp_acc | new_score |
|------|---------|-------|---------|----------|-----------|--------|-----------|
| d5   | +61     | 0.444 | 10.8    | 0.574    | 0.522     | 0.409  | 0.423     |
| Re8  | +43     | 0.461 | 15.2    | 0.806    | 0.668     | 0.402  | 0.425     |
| d6   | +50     | 0.454 | 18.8    | 1.000    | 0.782     | 0.380  | 0.410     |
| Nc6  | +52     | 0.452 | 5.8     | 0.310    | 0.367     | 0.365  | 0.400     |
| b6   | +58     | 0.447 | 0.0     | 0.000    | 0.179     | 0.329  | 0.376     |
| c6   | +62     | 0.443 | 0.0     | 0.000    | 0.177     | 0.294  | 0.354     |

**Old selects: d6** (score 0.782) — dominated by being the "most tricky" sibling.
**New selects: Re8** (score 0.425) — best blend of sound position and trickiness.

Analysis: The eval difference between Re8 (+43cp) and d6 (+50cp) is small
(7cp), so this isn't a dramatic improvement. The more significant effect is
that the old system's normalization amplifies the gap between d6 (norm=1.0)
and Re8 (norm=0.806), making d6 appear far superior when the actual
trickiness difference is modest. The new system compresses scores into a
tighter, more realistic range where eval and trickiness compete on equal
terms.

A stronger motivating example would come from sharper openings with larger
eval spreads — this quiet Petrov doesn't stress-test the system much.

### Scenario 2: Depth-4 Decision (After 1...Nxe4 2.Be2 d5 3.Be3)

Deeper in the tree, where the old system had no differentiation:

| Move | eval_cp | wp_us | old_eca | old_norm | old_score | wp_acc | new_score |
|------|---------|-------|---------|----------|-----------|--------|-----------|
| Re8  | +48     | 0.456 | 0.0     | 0.000    | 0.182     | 0.324  | 0.377     |
| c6   | +55     | 0.450 | 0.0     | 0.000    | 0.180     | 0.286  | 0.352     |
| Bf5  | +72     | 0.434 | 0.0     | 0.000    | 0.174     | 0.275  | 0.339     |
| Nc6  | +67     | 0.439 | 0.0     | 0.000    | 0.176     | 0.246  | 0.323     |
| Nd7  | +67     | 0.439 | 0.0     | 0.000    | 0.176     | 0.000  | 0.176     |

**Old selects: Re8** (score 0.182) — pure eval (all ECAs are 0).
**New selects: Re8** (score 0.377) — same choice but with richer signal.

Analysis: The old system had `accumulated_eca = 0` for all children at this
depth (the ECA didn't propagate deeply enough through `max` selection). The
new system differentiates: Re8 has wp_acc = 0.324 while Nd7 has 0.000. Both
systems pick Re8, but the new system makes the choice for better reasons and
could diverge on different α values. This is the more compelling scenario:
the old system is effectively blind here, while the new system has real
trickiness information.

### Scenario 3: Root Decision (Opponent Move)

The root is an opponent-move node (Black to move, we play as Black). All
children are traversed with probability weighting:

| Move | eval_cp | wp_us | prob  | old_eca | wp_acc |
|------|---------|-------|-------|---------|--------|
| Nxe4 | +50    | 0.454 | 0.944 | 38.2    | 0.377  |
| Re8  | +63    | 0.442 | 0.054 | 53.7    | 0.346  |
| d5   | +179   | 0.341 | 0.002 | 0.0     | 0.026  |

Root accumulated_eca:
- Old: max propagation from children gives ~39.6 cp.
- New: wp_local(root) + Σ(prob × child.wp_acc) = 0.001 + 0.944 × 0.377 +
  0.054 × 0.346 + 0.002 × 0.026 = 0.377. The root's trickiness faithfully
  reflects the dominant Nxe4 line.

### Scenario 4: Eval Guard in Action

Consider a position where one child has very high trickiness but fails the
eval guard (wp_us < 0.35):

| Move | eval_cp | wp_us | wp_acc | passes guard? | score  |
|------|---------|-------|--------|---------------|--------|
| A    | +200    | 0.323 | 0.400  | No (< 0.35)  | —      |
| B    | +40     | 0.463 | 0.150  | Yes           | 0.275  |
| C    | +50     | 0.454 | 0.100  | Yes           | 0.242  |

Move A has the highest trickiness but is objectively too bad for us. The eval
guard filters it out. We select B — decent eval with moderate trickiness.
The accumulation phase sees this same result and propagates B's ECA upward,
so the parent node doesn't benefit from A's inflated trickiness.

In the old system, `max(child_eca)` would have propagated A's ECA (the
highest), making the parent appear trickier than the line we'd actually play.

---

### Scenario 5: Near-Equal Positions (local_cpl sanity check)

A 5cp "blunder" at equality contributes just 0.005 (0.5% wp). A 10cp
inaccuracy: 0.009 (0.9%). These are appropriately tiny — near-equal
positions don't produce phantom trickiness.

| Blunder size | local_cpl contribution |
|-------------|------------------------|
| 5cp         | 0.005 (0.5% wp)        |
| 10cp        | 0.009 (0.9% wp)        |
| 30cp        | 0.028 (2.8% wp)        |
| 100cp       | 0.091 (9.1% wp)        |
| 300cp       | 0.251 (25.1% wp)       |

### Scenario 6: Sigmoid Compression at Extreme Evals

The same 50cp blunder produces less trickiness when the position is already
decided. The compression is real but gradual within the eval window:

| Base eval | 50cp blunder delta | Ratio vs. equality |
|-----------|--------------------|--------------------|
| 0cp       | 0.046 (4.6% wp)   | 1.00×              |
| +100cp    | 0.044 (4.4% wp)   | 0.95×              |
| +200cp    | 0.039 (3.9% wp)   | 0.85×              |
| +300cp    | 0.033 (3.3% wp)   | 0.71×              |
| +500cp    | 0.020 (2.0% wp)   | 0.44×              |
| +800cp    | 0.008 (0.8% wp)   | 0.17×              |

Within ±300cp (the default eval window), a 50cp blunder loses 71–100% of
its equality-baseline impact. Beyond ±300cp, compression is severe — but
those positions are pruned by min/max eval before ECA runs. The compression
within the window is a feature: a blunder when you're already up 300cp
genuinely matters less than the same blunder at equality.

### Scenario 7: Accumulated ECA Bounds

In the 954-node Three Knights Petrov tree, no node exceeds 0.50:

| Range          | Count |
|----------------|-------|
| [0.00, 0.01)   | 845   |
| [0.01, 0.05)   | 16    |
| [0.05, 0.10)   | 4     |
| [0.10, 0.20)   | 15    |
| [0.20, 0.30)   | 29    |
| [0.30, 0.40)   | 32    |
| [0.40, 0.50)   | 13    |
| Exceeds 1.0    | 0     |

In this quiet opening, values stay well under 0.50. Sharp tactical openings
may produce higher values — potentially exceeding 1.0 in extreme cases. No
cap is applied; see the Unbounded Accumulation section for the rationale.

### Scenario 8: Accumulation/Selection Consistency

Checked 93 our-move nodes with at least 2 children passing filters.
**Zero mismatches.** The move selected during accumulation always matches
what selection would pick — the filter mirroring works correctly.

### Scenario 9: Sensitivity to eval_weight (After ...Nxe4 Be2)

| eval_weight (α) | Selected move | Score  |
|------------------|---------------|--------|
| 0.00 (pure trick)| d5           | 0.409  |
| 0.20             | d5           | 0.416  |
| 0.40 (default)   | Re8          | 0.425  |
| 0.60             | Re8          | 0.437  |
| 0.80             | Re8          | 0.449  |
| 1.00 (pure eval) | Re8          | 0.461  |

The transition from d5 (trickiest) to Re8 (best eval among tricky moves)
happens between α = 0.20 and 0.40. This confirms the parameter is effective:
users who want maximum trickiness set α low, users who want sound play set
it high, and the default blends reasonably.

**Important caveat:** This scenario is internally inconsistent. The wp_acc
values were computed with α = 0.40 baked into the accumulation pass, but the
table then varies α at selection time — exactly the accumulation/selection
mismatch the proposal argues against. To do this properly, each row would
need its own ECA recomputation at the corresponding α, which would change
the wp_acc values and potentially the results.

The scenario is included to show that α effectively shifts the decision
(which it does), but the exact scores are only valid for the α = 0.40 row.
This is an inherent consequence of the parameter-coupling tradeoff — see
the Known Tradeoff section.

---

## What to Test

1. **Multi-opening scale validation**: Run on 3–5 diverse openings (quiet
   positional, sharp tactical, gambit). Dump `accumulated_eca` values.
   Check the range. If sharp openings produce values >> 1.0, assess whether
   α needs retuning or a log-transform is warranted.

2. **Alekhine example**: After 1.e4 Nf6, does the new metric prefer 2.e5
   (objectively strong) over 2.Nc3 (tricky but weaker)? The current ECA
   prefers Nc3. The new metric should give e5 a better score because the
   win-probability baseline is higher.

3. **Lines with near-equal moves**: Positions where all opponent moves are
   within 10cp should produce near-zero `local_cpl`. Verify the sigmoid
   doesn't amplify small differences.

4. **Extreme positions**: At +5.0, a 50cp opponent blunder should produce
   tiny `local_cpl` (sigmoid compresses substantially). At 0.0, the same
   blunder should produce meaningful delta.

5. **Accumulation/selection consistency**: Verify that the move selected
   during accumulation matches the move selected during the top-down
   traversal. They should be identical by construction — if they diverge,
   the filter mirroring or eval source has a bug.

6. **Existing repertoire comparison**: Run the Three Knights Petrov
   repertoire with both old and new metrics. Compare selected moves and
   total line count. Expect some move changes at shallow depths where the
   absolute-eval issue was most pronounced.

7. **Fallback path**: Test positions where no children have `has_eca`
   (no engine evals). Verify the 4-weight fallback formula still works.

8. **Eval source consistency**: Verify that `build_repertoire_recursive`
   reads from `child->engine_eval_cp` (not `rdb_get_eval`) after the
   change, and that the selected move matches accumulation.

9. **Flutter app compatibility**: Verify the app handles version 2 JSON
   gracefully (or at minimum doesn't crash on [0, 0.5] values where it
   expects centipawns).

---

## Summary

| Aspect | Current (cp-based ECA) | Proposed (wp-delta ECA) |
|--------|------------------------|-------------------------|
| Local metric | centipawn loss | win-probability delta |
| Units | centipawns (unbounded) | win probability deltas (unbounded, typically [0, ~0.5]) |
| Absolute eval sensitivity | None (30cp = 30cp always) | Built in (sigmoid compression) |
| Our-move accumulation | max(child_eca) | selected child's eca (via blended score) |
| Our-move filters during accumulation | None | Same as selection (eval guard, max-eval-loss) |
| Our-move fallback | N/A (max has no filter) | Blended score, no filters (consistent) |
| Selection formula | α × eval + (1-α) × norm_eca | α × eval + (1-α) × accumulated_eca |
| Selection eval source | rdb_get_eval (DB first) | child->engine_eval_cp (TreeNode) |
| Normalization needed | Yes (eca / max_sibling_eca) | No (same units; no cap) |
| Parameter independence | Yes (ECA ignores α) | No (α baked in; recompute is <1ms) |
| Depth decay needed | Arguably no | Less so (sigmoid helps; still useful for deep forcing lines) |
| Q-loss variant | Separate fields | Removed (sigmoid is primary) |
| Filter duplication risk | N/A | Mitigated via shared helper function |
| Field name changes | — | Keep names; rename local_cpl → local_wp_delta recommended |
| Serialization version | 1 | 2 (with eca_units field) |
| API change | tree_calculate_eca(tree, white, decay) | tree_calculate_eca(tree, config) |
