# Repertoire Generation Algorithm — Design Document

## Overview

The tree builder generates chess opening repertoires through a single
interleaved DFS that builds the tree and evaluates positions simultaneously:

1. **Building** the move tree by querying Lichess Explorer, Maia, and Stockfish
   together — engine MultiPV for our-move candidates, Lichess DB + Maia
   supplement for opponent responses, with eval-window pruning at every node
2. Computing **expectimax values** — propagating practical win probabilities
   bottom-up through the tree
3. **Selecting** repertoire moves using expectimax values
4. Extracting complete lines and exporting to JSON/PGN

---

## Pipeline Stages

The CLI runs five stages (`[0/4]` through `[4/4]`).

### Stage 0: Database + Engine Initialization

Open (or create) the SQLite database for caching explorer responses, engine
evaluations. Locate and start the Stockfish engine pool
(required for building).

### Stage 1: Build Opening Tree (Interleaved)

A single DFS builds the tree by interleaving Lichess explorer queries with
Stockfish evaluation. At each node, the algorithm dispatches based on whose
move it is:

#### Our-Move Nodes (Engine-Driven)

1. **Stockfish MultiPV** — evaluate the position with `our_multipv`
   (default 5) lines, a **constant at every depth**.  No depth-based
   tapering — a smaller MultiPV at deeper plies would monotonically
   under-estimate V (fewer candidates can only lower the MAX), so
   shrinking the action space with depth would bake a systematic
   downward bias into every value propagated upward.  The line-0
   score is also used as the node's own engine eval (the DB cache
   stores it for us), so there is no separate single-PV call before
   MultiPV.
2. **Window-prune check** — run the `min_eval_cp` / `max_eval_cp`
   check using the line-0 score and stop here if the position is
   already outside the window.  The check lives here (rather than
   before the MultiPV call) so the MultiPV result can double as the
   eval — it's strictly more information at the same cost.
3. **Eval-loss filter** — discard candidates more than
   `max_eval_loss_cp` (default 50) worse than the best line.  All
   surviving lines become children.  This is a *quality* gate, not a
   branching budget.
4. **Lichess enrichment** — if `--lichess`, query the explorer for SAN
   notation, win rates, and game counts (enrichment only — Stockfish
   drives branching).
5. **Create children** with evaluations set inline, cached to the DB.
6. **Maia frequency enrichment** — if a Maia model is loaded and
   `populate_maia_frequency` is set (e.g. under `--fresh` /
   `--novelty-weight`), run inference on the parent position and store
   each child's predicted human play probability as `maia_frequency`.
   This inference goes through the DB-cached Maia wrapper so resumed
   builds don't pay for it twice.
7. **Recurse** into each child.

#### Opponent-Move Nodes (single source — Maia OR Lichess)

Opponent moves come from exactly one source so the resulting child
probabilities live in a single, coherent distribution.  The choice is a
hard switch:

- `--maia-only` (default) — Maia's policy head over all legal moves.
  Every opponent node always gets a prediction; no API rate limit.
- `--lichess` — Lichess Explorer empirical distribution only.  Opponent
  nodes without enough games simply get no children and the expectimax
  tail term (below) absorbs the missing mass.

Either way, the selection loop is the same:

1. Walk the chosen source's moves in probability order.
2. Drop moves below the source's min-probability gate
   (`min_games` for Lichess, `maia_min_prob` for Maia, default 0.05).
3. Stop when `opp_max_children` is reached or the mass target
   `opp_mass_target` (default 0.95, **constant at every depth**) is
   covered.
4. **Probabilities are kept raw** — `child.move_probability` is the
   real-world frequency from the source, not a renormalized share.
   `Σ pᵢ` is usually < 1 (we deliberately don't cover 100%); the
   expectimax pass treats the uncovered mass as a tail term evaluated
   by the engine eval at this node.
5. **Recurse** into each child.  Children are NOT batch-evaluated up
   front: every opponent-move child is an our-move node, and its
   `build_our_move` pass will run MultiPV on that FEN at the same
   depth anyway.  A batch single-PV pre-eval would be strictly
   redundant with the MultiPV pass that follows.

No normalization to 1.0 is performed at build time — renormalizing
would silently claim the moves we dropped behave identically to the
moves we kept, which is false.  Leaving `Σ pᵢ < 1` preserves the
honest covered-mass signal that the expectimax pass uses to weight
the tail.

> **TODO — Engine injection (`--engine-injection`):** A future flag
> could inject Stockfish's top-1 opponent move at each opponent node
> when that move is not already a child.  This would replace the
> eval-based tail term with an actual V value from an engine-best
> subtree, giving a tighter bound on the uncovered mass.

Runtime at every depth is bounded by the hard caps (`our_multipv`,
`opp_max_children`) and the eval filters; natural depth limits come from
`min_probability` (cumulative probability pruning), `max_depth`, and the
`[min_eval_cp, max_eval_cp]` window — not from depth-dependent branching.

#### Eval-Window Pruning

The window check runs where the eval already lives, not as a separate
pre-step:

- **Opponent-move nodes** — the expansion step produces a policy, not
  an eval.  `build_recursive` runs `ensure_eval` (a single-PV call,
  with DB cache) immediately before dispatching so the window check
  has something to look at.
- **Our-move nodes** — MultiPV is about to run anyway.  The window
  check is deferred into `build_our_move` and uses MultiPV's line-0
  score, so no extra Stockfish call is made just to gate the MultiPV
  call on the same FEN.

The check itself is the same either way:

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

**Transposition detection.** A FenMap (hash table, canonical 4-field FEN
→ canonical TreeNode*) tracks every position that has been fully expanded
during the build.  The key ignores halfmove/fullmove counters so the same
chess position reached on a different move number still hits the same
transposition entry.  The map starts at 4096 buckets and doubles when the
load factor exceeds 0.75, so lookups stay O(1).

When a position is reached via a different move order, the transposition
node is linked into a **circular equivalence ring** with the canonical
node via the `next_equivalent` pointer.  All nodes for the same position
can find each other by walking the ring.  The canonical node (first
expanded) has children; the others are transposition leaves.

During expectimax calculation, transposition leaves walk their equivalence
ring to find the canonical node and borrow `expectimax_value`, `local_cpl`,
`subtree_depth`, and `subtree_opp_plies` from it instead of contributing
a raw leaf value.  The tree remains a tree (not a DAG) for serialization
and traversal, but the equivalence ring lets expectimax see through to the
subtree.  On resume, existing nodes re-register their FENs in the map so
transpositions are still detected for newly expanded branches.

Equivalence rings are persisted in JSON via `next_equivalent_id` on each
node.  On load, a `LoadContext` builds an ID→node map during parsing and
resolves all links in a single pass afterwards.  The global node-ID
counter is also synced to `max(loaded_id) + 1` so resume doesn't create
collisions.

The expectimax pass runs twice, so transposition leaves reliably borrow
`expectimax_value` from the canonical node even after a load-from-JSON or
other subtree reordering.  Total cost stays linear in tree size.

**Known limitation:** Transposition leaves keep the cumulative probability
of the path that discovered them.  If a higher-probability path reaches
the same position later, the canonical node is not re-expanded at the
deeper depth that the higher cumP would allow.  This is acceptable since
it only under-explores some positions rather than producing incorrect
results.

#### Maia Neural Network Integration

With `--maia-only` (the default), Maia's policy head is the **sole**
source of opponent moves.  Maia runs at every opponent node and its
top predictions — filtered by `maia_min_prob` (default 0.05) and the
mass / children caps — become the children.  `make_child()`
rejects duplicates by resulting FEN as a safety net.

With `--lichess`, Maia is not used for opponent move selection at all
— the opponent distribution is exclusively the Lichess Explorer's
empirical frequencies.  Maia may still be loaded for novelty scoring
(see `--novelty-weight`) where it provides a predicted-frequency
fallback when Lichess game counts aren't available at a position.

Maia auto-detects at `./maia3_simplified.onnx` or
`../assets/maia3_simplified.onnx`, or use explicit `--maia-model <path>`.

Maia policy responses are cached in the repertoire DB under
`(fen, elo)`.  On a resumed build the inference is skipped entirely
for positions that have already been seen in an earlier session.
The cache does not key on model hash — delete the `.db` file after
swapping Maia weights if you want the predictions regenerated.

### Stage 2: Generate Repertoire (Expectimax + Selection)

After the tree is built with all nodes evaluated:

1. **Load DB evals** — for trees loaded from JSON, sync DB-cached evals
   into TreeNode structs.
2. **Expectimax value propagation** — compute a practical win probability
   V in [0, 1] at every node (see Expectimax section below).
3. **Move selection** — traverse the tree top-down, selecting the child
   with the highest V at each our-move node.
4. **Line extraction** — extract complete repertoire lines from the
   selected moves.

### Stage 3: Trap Detection (Optional)

Two modes:

**`--traps`** (whole-tree search): Scans every opponent-move node in the
entire tree for positions where the most popular move is significantly
worse than the best move.  Outputs an annotated `<name>.traps.pgn` with
detailed explanations: which move opponents play, how often, the eval
swing, and what the best response was.  The trap score formula is:

```
trap = min(1, max(0, best_eval − popular_eval) / 200) × p_popular
```

Lines are sorted by trap score descending (up to 200).  This is
independent of the repertoire — it surfaces the trickiest positions
anywhere in the tree.  The `--traps` preset also widens build
tolerances (`min_eval` to −100/−300, `max_eval_loss` to 100cp) so
the tree explores more speculative positions where traps are likelier.

**`--traps-in-repertoire`**: The older behavior — scans the tree and
prints the top 20 trap positions to stdout (no PGN output).  Can be
combined with any preset.

### Stage 4: Export

Save results to JSON tree, repertoire JSON, and optionally PGN.

---

## Expectimax Value Propagation

### Concept

Every node gets a single value **V** in [0, 1] — its **practical win
probability** — computed in two linear bottom-up passes.  V naturally
incorporates opponent mistake tendencies at every level.

**V = 0.500** means dead equal (50% expected win rate).  **V = 0.534**
means "53.4% chance of winning in practice against a human" — a slight
edge.  **V = 0.662** means a strong practical advantage, typically
because opponents frequently blunder in the resulting positions.

The conversion from engine centipawns to win probability uses a
logistic function: `wp(cp) = 1 / (1 + e^(−0.00368 × cp))`.  Some
reference points:

| Engine eval | V (win prob) | Meaning |
|-------------|--------------|---------|
| 0 cp        | 0.500 (50%)  | Dead equal |
| +50 cp      | 0.523 (52%)  | Slight edge |
| +100 cp     | 0.545 (55%)  | Clear advantage |
| +200 cp     | 0.590 (59%)  | Significant advantage |
| +300 cp     | 0.633 (63%)  | Winning |

These are **leaf** values — the raw engine conversion.  Interior nodes
can have V higher or lower than wp(eval) because the expectimax backup
accounts for which moves opponents actually play.  A position evaluated
at +50 cp might have V = 0.56 if opponents frequently blunder there, or
V = 0.51 if they always find the right move.

### Intuition

At any position where the opponent is about to move, Maia predicts the
likelihood of each reply.  Each child already has its own V from the
subtree below it.  The opponent node's value is the probability-weighted
average of children's values — what will actually happen when real humans
choose the next move.

If the most popular opponent move is a mistake (leads to a high-V child),
V at this node will be high.  If the popular move is the engine-best move,
V reflects that too.  Trickiness emerges naturally: no tuning parameter
is needed.

### Worked Example

Consider two candidate moves for White that Stockfish evaluates equally
at +0.50 (50 centipawns).  Each leads to a position where the opponent
has two replies:

**Position A** (after 5. Nf3 — a quiet, natural position):

| Opponent reply | Maia prob | Engine eval (for us) | wp(eval) |
|----------------|-----------|----------------------|----------|
| ...d6 (good)   | 85%       | +55 cp               | 0.523    |
| ...Bg4 (good)  | 15%       | +45 cp               | 0.517    |

The opponent's most likely moves are both reasonable:

```
V_A = 0.85 × 0.523 + 0.15 × 0.517 = 0.522
```

**Position B** (after 5. Ng5 — a tricky, provocative move):

| Opponent reply | Maia prob | Engine eval (for us) | wp(eval) |
|----------------|-----------|----------------------|----------|
| ...d5! (best)  | 30%       | +20 cp               | 0.504    |
| ...h6?? (trap) | 70%       | +150 cp              | 0.575    |

Most opponents play the natural ...h6, chasing the knight — but it's a
mistake.  Only 30% find the correct ...d5:

```
V_B = 0.30 × 0.504 + 0.70 × 0.575 = 0.554
```

**Result:** Position B scores **0.554 vs 0.522** despite both positions
having the same engine evaluation (+50 cp).  The algorithm prefers Ng5
because it leads to a position where opponents are likely to go wrong.

This compounds through the tree.  At deeper levels, each child's V
already reflects the trickiness of *its* subtree.  A line that offers
repeated opportunities for opponent mistakes will accumulate a higher V
at every level.

### Three Rules

**Leaves** (no children):

```
V = leaf_confidence · wp(engine_eval_for_us)
  + (1 − leaf_confidence) · 0.5
```

At `leaf_confidence = 1.0` (the default) this is just `wp(eval)`.  For
`leaf_confidence < 1.0` the value is pulled toward 0.5 — the honest
"we haven't expanded this position, we don't really know who's winning"
prior.  The earlier formulation of this rule (plain `leaf_conf · wp`)
biased unexplored leaves toward 0 instead of toward neutral, which is
the wrong direction for an uncertainty discount.

**Opponent-move nodes** (probability-weighted expectation with a
proper tail term for uncovered mass):

```
covered = Σ pᵢ          (raw probabilities of explored children)
V       = Σ pᵢ · V(childᵢ)  +  (1 − covered) · V_tail
V_tail  = leaf_value(this node)
        = leaf_confidence · wp(eval_for_us at this node)
          + (1 − leaf_confidence) · 0.5
```

Child probabilities are NOT renormalized.  `covered` is typically
< 1 (we cap at `opp_max_children` and the mass target).  The
missing `(1 − covered)` mass is the opponent playing moves we did not
model — the engine eval at the node is our expected result if they
play best, which is a principled, slightly conservative anchor for
that tail (rare human moves on average give us a slightly better
result than engine-best).

**Our-move nodes** (we choose optimally):

```
candidates = children where eval_for_us >= best_child_eval - max_eval_loss_cp
V = max(V(child_i)) for child_i in candidates
```

Fallback: if no children pass the eval-loss filter, consider all children.

### Why This Works

Trickiness is implicit: if the popular opponent move leads to a child
with high V (good for us) while the engine-best reply (which happens
rarely) leads to low V, the probability-weighted sum pulls V up.
The "trick" signal emerges naturally, compounded properly through the
sigmoid at every level.

The sigmoid conversion (`wp()`) is critical.  A 50cp blunder at +50 cp
moves our win probability from 0.52 to 0.56 — a meaningful swing.  The
same 50cp blunder at +300 cp moves it from 0.75 to 0.78 — barely
noticeable, because the game is already won.  By working in win
probability space rather than raw centipawns, the algorithm
automatically weights blunders by how much they *matter*.

Depth compounds this effect.  In the worked example above, Position B
scored higher at a single node.  But in a real tree, each child's V
reflects the full subtree below it.  A line that consistently presents
the opponent with tricky decisions — where the popular move is worse
than the engine-best move — will accumulate a higher V at every level.
The algorithm doesn't need an explicit "trickiness" metric; it emerges
naturally from the probability-weighted propagation.

### Local CPL (display only)

`local_cpl` is still computed at opponent-move nodes for display and
diagnostics.  It is NOT used in scoring:

```
best_opp_cp = min(child.engine_eval_cp for all children with evals)
local_cpl   = Σ(prob_i × max(0, child_i.engine_eval_cp - best_opp_cp))
              for children with move_probability >= 0.01
```

### Transposition Handling

Transposition leaves borrow V from the canonical node before the leaf
formula runs.  The canonical's V already has `leaf_confidence` baked in
at its own leaves, so transposition leaves do not re-apply the discount.

The expectimax pass runs **twice** (`tree_calculate_expectimax`) so the
borrow is robust to DFS order.  In a single pass, a transposition leaf
visited before its canonical would fall through to the leaf formula and
pollute the values propagated up through its ancestors.  The first pass
guarantees every canonical has `has_expectimax = true`; the second pass
fully overwrites every node's V, so transposition leaves now find their
canonical ready and the corrected value propagates cleanly.  Total
cost is 2·O(n) — still linear, and negligible against the build
phase's engine-call cost.

### Move Selection

At each our-move node, `score_our_move_children()` filters by
`max_eval_loss_cp`, then returns `argmax(V)` — just pick the child with
the highest practical win probability.

When `novelty_weight > 0` (e.g. via `--fresh` or `--novelty-weight`),
the selection applies a novelty bonus before picking:

```
novelty = 1 - frequency          // 0 for the mainline, ~1 for rare moves
V_adj   = V × (1 + nw × novelty)
selected = argmax(V_adj)
```

The **frequency** signal comes from one of two sources, chosen
automatically:

- **Lichess mode** (`--lichess`): `frequency = child.total_games /
  parent.total_games`.  A move played in 200 of 10,000 games has
  frequency 0.02 and novelty 0.98.
- **Maia-only mode** (default): `frequency = child.maia_frequency`,
  where `maia_frequency` is Maia's predicted probability that a human
  would play this move (populated during build via a single ONNX
  inference per our-move node).  A move Maia predicts at 60% has
  novelty 0.4; a move at 2% has novelty 0.98.

The Lichess signal is preferred when available (real game data); Maia
is the fallback.  The `max_eval_loss_cp` filter still runs first, so
novelty cannot promote objectively bad moves.  The raw
`expectimax_value` (without the novelty boost) is what propagates
upward in the tree — novelty only affects the local argmax choice.

At opponent-move nodes, all children above the probability threshold are
recursed into.  The DFS also stops at eval-window boundaries.

### Line Extraction (unchanged)

Follow selected repertoire moves through the tree.  At our-move nodes, only
the selected move is followed.  At opponent-move nodes, all likely responses
are followed.  Lines always end with the repertoire side's move.

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
| `our_multipv` | `--our-multipv` | 5 | MultiPV count at every depth (constant, no taper) |
| `max_eval_loss_cp` | `--max-eval-loss` | 50 | Candidates must be within this of best |

### Tree Building — Opponent Moves (Maia-only OR Lichess-only)

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `opp_max_children` | `--opp-max-children` | 6 | Hard cap on opponent responses per position |
| `opp_mass_target` | `--opp-mass` | 0.95 | Covered-mass target at every depth (constant, no taper) |
| `maia_only` | `--maia-only` | on | Use Maia exclusively for opponent moves |
| — | `--lichess` | off | Use Lichess exclusively for opponent moves |
| `min_games` | `-g` | 10 | Minimum Lichess games to include a move (Lichess mode) |
| `ratings` | `-r` | 2000,2200,2500 | Lichess rating buckets |
| `speeds` | `-s` | blitz,rapid,classical | Time controls |

### Tree Building — General

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `min_probability` | `-p` | 0.0001 (0.01%) | Prune branches below this cumulative probability |
| `max_depth` | `-d` | 20 ply | Maximum tree depth |
| `eval_depth` | `-e` | 20 | Stockfish search depth per position |
| `num_threads` | `-t` | 4 | Parallel Stockfish engines |

### Eval Window Pruning

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `min_eval_cp` | `--min-eval` | W: 0, B: -200 | Stop if our eval drops below this |
| `max_eval_cp` | `--max-eval` | W: 200, B: 100 | Stop if our eval exceeds this |
| `relative_eval` | `--relative` | off | Make thresholds relative to root eval |

### Maia

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `maia_model` | `--maia-model` | auto-detect | Path to `maia3_simplified.onnx` |
| `maia_elo` | `--maia-elo` | 2200 | Elo for predictions (600–2400) |
| `maia_min_prob` | `--maia-min-prob` | 0.05 (5%) | Skip Maia moves below this probability |

### Expectimax & Move Selection

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `leaf_confidence` | `--leaf-confidence` | 1.0 | Blends wp(eval) with a neutral 0.5 prior at unexplored leaves. 1.0 = trust eval fully, 0.0 = assume neutral. |
| `max_eval_loss_cp` | `--max-eval-loss` | 50 | Quality floor at our-move nodes |
| `novelty_weight` | `--novelty-weight` | 0 | 0 = off, 100 = maximize novelty boost at our-move nodes |

### Preset Modes

The CLI supports five preset bundles (`--solid`, `--practical`, `--tricky`,
`--traps`, `--fresh`). Each sets defaults for eval tolerance, novelty
weight, and eval floor (`--min-eval`).
**Modes set defaults only; explicit flags override.** For example:
`--fresh --novelty-weight 80` keeps fresh’s other defaults but overrides
the novelty weight to 80.

| Mode | novelty | `--min-eval` (W / B) | `--max-eval-loss` | Intent |
|------|---------|----------------------|-------------------|--------|
| `--solid` | 0 | 0 / -100 | 30 | Tight quality floor, no compromise. |
| `--practical` | 0 | -25 / -200 | 50 | Balanced eval tolerance. |
| `--tricky` | 0 | -50 / -250 | 75 | Wider tolerance for speculative moves. |
| `--traps` | 0 | -100 / -300 | 100 | Widest tolerance + whole-tree trap PGN (`<name>.traps.pgn`). |
| `--fresh` | 60 | (default) | 40 | Sound but unusual moves. Favor rarely-played lines. |

### What Each Parameter Does Intuitively

- **`our_multipv`**: "How many engine moves to consider at our turn?"
  Constant at every depth (default 5).  `max_eval_loss_cp` further
  narrows actual children.  Keeping this flat avoids a one-sided
  downward bias on the MAX operator: fewer candidates at deep plies
  can only lower their V, which then propagates upward as a
  systematic under-estimate of our achievable win probability.

- **`opp_mass_target`**: "How much of the opponent's probability mass
  to cover at every opponent node?" Constant at every depth (default
  0.95).  The uncovered `(1 − covered)` mass is not dropped on the
  floor — expectimax handles it via the tail term
  `(1 − covered) · leaf_value(this node)`, where `leaf_value` blends
  `wp(eval_for_us)` with a neutral 0.5 prior according to
  `leaf_confidence`.  Natural depth pruning comes from
  `min_probability`, `max_depth`, and the eval window, not from a
  depth-dependent mass target.

- **`opp_max_children`**: "Hard cap on opponent responses per position?"
  Safety net — rarely hit when the mass target is doing its job. Raise to
  8-10 for more thorough preparation of rare-sideline-heavy openings.

- **`novelty_weight`**: "How much should we prefer unusual moves?"
  At our-move nodes, boosts the adjusted V of moves that are rarely
  played (low Lichess game count or low Maia predicted frequency).
  The eval-loss filter still runs first, so novelty cannot promote
  objectively bad moves.  Use `--fresh` for the preset or
  `--novelty-weight <0-100>` for fine-grained control.  In maia-only
  mode the novelty signal comes from Maia predictions (approximate);
  `--lichess` gives novelty based on real game data.

- **`min/max_eval_cp`**: "What eval range should we explore?" Stops the DFS
  when positions are too bad (lost cause) or too good (already winning,
  no need to study further). Applied during the build as inline pruning.

- **`--maia-only`** (default): Pure Maia for opponent move selection.
  Every opponent node gets a prediction (no API rate limit), which
  produces larger trees than Lichess since Maia has no min-games gate.
  Tighten `min_probability` / `maia_min_prob` / `opp_max_children`
  to compensate if needed.

- **`--lichess`**: Pure Lichess for opponent move selection.  Positions
  with too few games simply get no children — the expectimax tail term
  absorbs the uncovered mass using the engine eval.  Use this when you
  trust empirical human play data more than Maia's NN predictions.

---

## File Layout

```
tree_builder/
├── include/
│   ├── node.h          # TreeNode struct (eval, expectimax, probabilities)
│   ├── tree.h          # Tree config + interleaved build + expectimax
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
│   ├── tree.c          # Interleaved build, expectimax, traversal
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
   │  Stockfish    │                      │  single source:  │
   │  MultiPV=5    │                      │   Maia OR Lichess│
   │  (constant)   │                      │   (Maia cached   │
   │  → line-0 cp  │                      │    in DB by      │
   │    → node eval│                      │    (fen, elo))   │
   │  → window     │                      │  → raw probs     │
   │    prune      │                      │     (Σpᵢ ≤ 1)    │
   │  → eval-loss  │                      │  → mass target   │
   │    filter     │                      │    (95%, const)  │
   │  → optional   │                      │  → children NOT  │
   │    Lichess    │                      │    pre-evaluated │
   │    enrichment │                      │    (each child's │
   │               │                      │    MultiPV will  │
   │               │                      │    produce the   │
   │               │                      │    eval for free)│
   │               │                      │  → tail absorbed │
   │               │                      │    by expectimax │
   └──────┬────────┘                      └────────┬─────────┘
          │                                        │
          │   Window prune runs where the cheap    │
          │   eval already lives: for opp-nodes    │
          │   before expansion, for our-nodes      │
          │   inside build_our_move after MultiPV. │
          │   All evals cached in SQLite.          │
          └────────────────┬───────────────────────┘
                           ▼
              Tree with evals on all nodes
                           │
                           ▼
              tree_calculate_expectimax()   → V in [0,1] at every node
                                              (two-pass, robust to trans-
                                               positions / reloaded trees)
                  Opp:  V = Σ pᵢVᵢ + (1−Σpᵢ)·leaf_value(this)
                  Our:  V = max(Vᵢ) among eval-loss-filtered candidates
                  Leaf: V = leaf_conf·wp(eval_us) + (1−leaf_conf)·0.5
                           │
                           ▼
              build_repertoire_recursive()
                  Our nodes: pick argmax(V) after eval-loss filter
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

### Leaf Node Values

Leaf nodes use `V = leaf_conf · wp(eval) + (1 − leaf_conf) · 0.5`.  At
`leaf_conf = 1.0` (default) this is just `wp(eval)` — full trust in the
engine's verdict.  At smaller `leaf_conf`, V is pulled toward the 0.5
"we don't know" prior rather than toward 0 (certain loss), which is
what an uncertainty discount should actually do.

### DFS Order Bias on Interrupted Builds

The build is DFS, so earlier children are fully explored before later
ones.  If interrupted (SIGINT), earlier children have deeper subtrees
and accumulate more expectimax signal.  Resume partially mitigates this, but
any time-limited build has an inherent bias toward first-explored
branches.

### Transposition Leaf Values

When a transposition leaf borrows `expectimax_value` from the canonical
node, the value reflects the canonical path's subtree.  A position
reached via a different move order borrows the same V value regardless
of how the path to reach it differs.  In practice this is minor since
transposition leaves are a small fraction of candidates.

`tree_calculate_expectimax` runs the recursion twice so the borrow is
robust to DFS traversal order (see *Transposition Handling* above).
Total cost is 2·O(n) — still linear in tree size, and dominated by
the build phase's Stockfish/Maia inferences by several orders of
magnitude.

### Eval-Too-Low Pruning and the Tail Term

`tree_prune_eval_too_low` deletes children that fell below the eval
window from the tree.  Their `move_probability` is no longer part of
`covered`, so the expectimax tail credits that mass with
`leaf_value(parent)` instead of the "we lost that branch" value it
semantically deserves.  In practice this only overstates V when a
meaningful share of the policy mass lands on positions well below
`min_eval_cp`, which the build tries to avoid via `min_probability`
anyway.  Fixing this would require retaining the pruned children with
a clamped V (or tracking a separate "already-lost tail mass") — left
as future work.

### Equivalence Ring Serialization

Equivalence rings ARE serialized.  `node_to_cjson` writes a
`next_equivalent_id` field for each node in a ring, and the loader
(`cjson_to_node`) collects `(node, target_id)` pairs which
`load_ctx_resolve` wires back up after the full tree is parsed.
Trees loaded from JSON therefore have their equivalence rings fully
restored without needing a rebuild.
