# Pure expectimax contract

The Dart app and standalone C builder now use the same finite-horizon search
rules. `stockfishExpectimax` defaults to Pure. The optional
[Rolling 4-ply mode](ROLLING_SEARCH_AND_STUDY_LINES.md) uses the same local
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

**Target master opponents** is on by default and can be deselected on the main
form. It means empirical move frequencies from the master-game source at each
position where that source has legal observations. All positive-count legal
moves are included and normalized by their total count. No independent engine
reply is injected, and no Maia probability is added to a book distribution.

Where no legal book observations exist, use Maia at the displayed opponent
rating, normalized over its legal moves. With master targeting deselected,
Maia supplies every opponent position. All positive-probability replies are
searched, however rare. A missing/invalid Maia policy is an error, not a silent
change to another population. A failed database query is also an error.

The app uses its local master-game database; C/MCP uses the Lichess masters
explorer. Its [query implementation](https://github.com/lichess-org/lila-openingexplorer/blob/master/src/api/query.rs) defaults to 12 moves; C explicitly requests up to 256 to cover all legal moves. These are different samples, so actual runs need not agree even with
the same settings. The source is saved in the tree and cannot silently change
on resume. Book counts describe observed practice, not every move a master
might play: unobserved moves have zero probability while in book. This simple
empirical assumption is deliberate and visible; there is no hidden smoothing
parameter. Engine and Maia versions and evolving source data can also affect
newly evaluated positions.

If the app's master database is missing, the form explicitly explains that
Maia will be used throughout and offers to download master games first.

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
