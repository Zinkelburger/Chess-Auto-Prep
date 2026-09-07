# Pure expectimax contract

The Dart app and standalone C builder now use the same finite-horizon search
rules. `stockfishExpectimax` defaults to Pure. The optional
[Fast mode (four-ply lookahead)](ROLLING_SEARCH_AND_STUDY_LINES.md) uses the same local
model with approximate receding lookahead. Legacy Fast is retired; an old Fast
setting cannot activate heuristic pruning. This document defines Pure. Database exploration and the ChessDB mainline book remain
separate build sources.

## What is optimized

Choose a fixed repertoire side, a horizon H in half-moves from the supplied
root, an engine depth D, a maximum engine loss L in centipawns, and an opponent
policy. The default horizon is 4 plies. A larger horizon is exponentially more
expensive, even with just a few plies of preparation.

For each of our positions, enumerate **every legal move**, including all four
promotions. Evaluate each resulting position at depth D, using the repertoire
side's perspective. Retain every move whose evaluation is at least best − L.
These fixed-depth evaluations are immutable during expansion and backup.
Neither MultiPV width nor book popularity determines our candidate set.

For a complete tree, the recurrence is:

```
V(terminal) = 1 for our win, 0.5 for a draw, 0 for our loss
V(horizon)  = U(fixed-depth engine evaluation from our perspective)
V(our turn) = max V(child) over the admitted legal candidates
V(opponent) = sum policy(move | position) * V(child)
```

`U(cp) = 1 / (1 + exp(-0.00368208 * cp))`; packed mate scores with magnitude
above 9000 saturate to 0 or 1. This is a bounded **expected-score estimate**,
not a calibrated human win probability. The engine-loss constraint and leaf
utility depend on Stockfish's estimates. Search correctness does not prove
that those estimates, the opponent model, or the resulting move are objectively
correct chess. Stockfish itself remains a selective engine search.

The selected move uses exactly the same scorer as the maximizing backup.
Ties use engine evaluation, then UCI, then SAN. There are no novelty bonuses,
confidence blends, setup preferences, memorability bonuses, skeleton overrides,
reply-count preferences, or separate selection objectives.

## Opponent model

**Pure and Fast use Stockfish + Maia only.** Stockfish supplies position
estimates and the own-move loss constraint. Maia, at the displayed opponent
rating, supplies every opponent position's move probabilities. The legal
probabilities are normalized to sum to one; every positive-probability legal
reply remains in the search. There are no master counts, database fallbacks,
blends, probability-temperature changes, or hidden reply caps.

A missing or invalid Maia policy is an error. It never triggers a switch to a
game database. Master targeting and automatic downloads are unavailable for
Stockfish expectimax, including when an old preset enables their legacy flags.
The separate database build modes keep their own data workflows.

Saved trees record `opponent_book_source: "none"` and
`use_master_games: false`. C also records `maia_only: true`. Earlier trees
built with master probabilities cannot resume under this policy: start a fresh
build. Existing Maia-only trees can continue with the same position, rating,
evaluation settings and search method. Changes to the Maia or Stockfish model
versions can still affect newly evaluated positions.

## Chess state and draw convention

Each node retains its full path from the root. Identical piece placements can
have different remaining horizons, half-move clocks, or repetition histories;
Pure never borrows their backed-up values or merges their policies by FEN.
Starting a new search from an old Pure subtree rebuilds it with the new history.

Checkmate and stalemate are exact terminals. Insufficient material is detected
by the chess rules implementation. The model assumes both players immediately
claim a draw at the third occurrence or 100 half-moves, with checkmate taking
precedence. Repetition keys include side to move, castling rights, and legal
en-passant availability. History before the supplied root is unknown.

This is an explicit draw-claim convention, not full modeling of optional or
prospective draw claims. General dead positions beyond recognized insufficient
material, arbitrary game history before a FEN, and tablebase proofs are outside
this model. “100% correct chess” would require those inputs and additional rules.

## Completion, budgets, and resume

An expansion is committed atomically: first construct its complete action set
and evaluations, then attach it to the tree. Cancellation, time limits, or a
node budget never leave a partial probability distribution or partial legal
candidate enumeration. A node budget may leave some allowance unused when the
next complete expansion cannot fit. An in-flight engine evaluation may finish
after a requested time limit.

Unresolved frontier values are provisional. Their bounds are [0,1]; exact
terminals and evaluated horizon leaves have equal bounds. Bounds propagate by
max at our nodes and probability-weighted sum at opponent nodes. They bound
the defined finite model, not Stockfish error or real-world playing strength.
An incomplete result is labeled as such and does not claim its leader is solved.

Resume requires the same root, repertoire side, engine depth, engine-loss
limit, opponent rating, master-target setting, and book source. The horizon can
increase, but cannot shrink. Already expanded policies/evaluations are retained;
new frontier queries use the currently available engine/model/data. For a
uniform fresh comparison after changing any of these sources, start a new run.
Legacy heuristic trees must be rebuilt. Legacy files remain readable for review;
cyclic history-free value dependencies are rejected instead of iterated an
arbitrary number of times.

## Export and verification

Export follows the maximizing policy and every positive-probability opponent
reply. Pure paths are not folded by FEN or discarded by diversity, cumulative
probability, or absolute evaluation windows. Optional output products such as
trap-only collections and extra explanatory variations remain output choices;
they are not the tree's optimized policy. Engine tails are disabled for Pure.

There is no separate deep-verification pass for Pure. To strengthen evaluation,
rebuild at the desired engine depth, so all legal moves are admitted or rejected
at that depth. The legacy verifier re-evaluates its entire saved tree, commits
only a completed pass, and always recomputes values and selection. It can only
check saved candidates; it cannot recover moves a legacy build omitted.

## Implementation and checks

- Dart: `pure_position.dart`, `pure_tree_builder.dart`, `eca_calculator.dart`,
  `repertoire_selector.dart` under `lib/services/generation/`.
- C: `tree_builder/src/pure_search.c`; chesslib adapter in `san_convert.c`.
- Both use the v4 tree wire format with `history_aware`, terminal values,
  lower/upper bounds, and `algorithm_version: 3` in configuration.
- C JSON uses 17 significant digits so saved probabilities survive round trips.
- Shared fixture: 30 independently solved trees, both colors, chance nodes,
  constrained max nodes, exact terminals, and deterministic policy checks.
- Dart tests cover legal action enumeration, master/Maia support, tiny replies,
  cancellation/budget behavior, resume restrictions, promotion and repetition.
- C tests exercise the same oracle, legal-move fixtures, and the real builder
  through a deterministic UCI process. Run `make test-pure` in `tree_builder/`.

Correctness-preserving speedups can follow: reusable fixed-depth evaluations,
parallel evaluation, and rigorous bounded chance-node pruning. Rolling is
explicitly approximate and tested against this reference. Study selection and
exercise boundaries are a separate, reversible output layer.
