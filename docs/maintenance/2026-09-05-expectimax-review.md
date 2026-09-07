# Expectimax implementation review

Reviewed 5 September 2026 · revision 37ccb574. Production code unchanged.

The max/expectation core is sound in principle. The current system is a selectively expanded chess preparation graph with a heuristic leaf utility and several later policy overrides. Six deterministic counterexamples expose correctness failures. Fast and Pure remain a useful product distinction, but they should solve the same declared objective.
Primary review: Dart stockfishExpectimax build, backups, selection, verification, policy smoothing and export handoff. C spot-check: matching backup and verification logic; the MCP expectimax tools launch C, not Dart. The C setup preference is already inside its shared scorer, so the Dart setup mismatch should not be attributed to C.

**Validation:** 43 existing focused tests passed; six new invariant counterexamples reproduced failures. Tests use scripted evaluations, not chess-strength measurements.

## Reproduced correctness failures

### P1 · Opponent probability mass can exceed 100%

Reproduced: a book position containing 3,000 c5 games yields p(c5)=1 after the prior is skipped. The engine's missing e5 reply is then injected with Maia p(e5)=0.5. Total probability is 1.5.

Expectimax clamps covered mass but leaves the weighted value sum untouched. This distorts move ranking and can produce values above 1. The issue affects both Fast and Pure, and uses the default prior-skip threshold.

**Repair:** Generate one normalized policy over legal moves. Every edge gets its probability from that same policy, including injected engine replies. A reply can be searched for safety with zero model mass. Do not invent probability to force search, and do not merely clamp the final score.

[Source](/home/anbernal/Projects/Chess-Auto-Prep/lib/services/generation/node_expander.dart:538)

### P1 · The exported policy differs from the policy being valued

Reproduced with setupMoves=d4: the root propagates e4's 0.518402 value, then selection chooses d4 with value 0.5. The calculator knows about novelty and the eval-loss filter, but the selector separately applies pins, reply count, structure, transfer, memorability and setup preferences.

At deeper decision nodes, ancestors compare continuations under choices the repertoire will not make. This can select the wrong root move, not just display the wrong percentage. Non-default preference settings trigger this failure; the default empty preference configuration avoids this particular path.

**Repair:** Resolve constraints and preferences inside the same Bellman backup that chooses and stores the move. Export follows those stored choices. If an alternative unconstrained value is useful, store it under a separate, explicit name.

[Source](/home/anbernal/Projects/Chess-Auto-Prep/lib/services/generation/repertoire_selector.dart:96)

### P1 · Two passes do not solve transposition dependencies

Reproduced using legal Nf3/g3/b3 opening move orders. A transposition points to a later canonical subtree that itself points to another later canonical subtree. After calculate(), the first alias still reads 0.5 while its canonical reads 0.676212.

Scores depend on child order and how often calculate() has previously run. The comment that canonical subtrees do not depend on transposition leaves is false. The C implementation has the same two-pass assumption.

**Repair:** Use a horizon-indexed position graph and memoized recursive backups that follow graph dependencies. Detect recursion explicitly. Handle repetition/draw state rather than borrowing a partially computed ancestor value. Add child-order and repeated-calculation invariance tests.

[Source](/home/anbernal/Projects/Chess-Auto-Prep/lib/services/generation/eca_calculator.dart:30)

### P1 · Verification uses shallow scores as if they were upper bounds

Reproduced: the chosen move deep-checks at +48cp; a sibling was +30cp shallow but is scripted at +200cp deep. The sibling is never checked and completed is true, despite a 152cp difference and a 50cp limit.

A shallow engine evaluation is not an optimistic bound on its deeper score. Moreover, the verifier only considers existing siblings, so it cannot discover a refutation or superior move omitted during candidate generation. The C verifier shares the shallow-score shortcut.

**Repair:** Compare the chosen move with a fresh unrestricted best-move search at the verification budget, using comparable evidence for the chosen move. Treat this as a depth/budget-relative check, not proof of chess truth. Report unresolved checks honestly.

[Source](/home/anbernal/Projects/Chess-Auto-Prep/lib/services/generation/repertoire_verifier.dart:159)

### P1 · Selection drops answers to forced bad positions

Reproduced: the tree contains e4 e5 Nf3; e5 leaves us at -150cp with a -100cp floor. The prepared Nf3 answer is never selected. The builder deliberately preserves answers to bad positions forced by the opponent, but the selector rejects both sides below the floor.

Coverage survives the build and is lost during selection. Export cannot teach an answer that was never selected. The selector also uses inclusive window boundaries while expansion uses strict comparisons.

**Repair:** Separate stopping preparation from rejecting our candidate moves. Never drop an opponent-forced question solely because the answer is unpleasant. Validate coverage on the actual selected/exported repertoire.

[Source](/home/anbernal/Projects/Chess-Auto-Prep/lib/services/generation/repertoire_selector.dart:58)

### P2 · Successful verification leaves propagated values stale

Reproduced: a selected leaf changes from +50cp to +200cp at verification. Its engine eval updates, but the root retains 0.545896 instead of the implementation's own expected 0.676212.

Recomputation only runs after a demotion. A successful verification pass can leave old expectimax values and selection scores beside new engine evaluations. Changing a tail evaluation also changes the correct backup even if the selected move stays the same.

**Repair:** Invalidate and recompute affected values after every eval update, then refresh the selected policy and annotations. Certify the resulting final policy, including any newly selected branch.

[Source](/home/anbernal/Projects/Chess-Auto-Prep/lib/services/generation/repertoire_verifier.dart:210)

## Conceptual and static findings

These are model limitations and code-inspection findings, separate from the six runtime reproductions.

### The score is not calibrated human win probability

winProbability is a symmetric logistic of centipawns: a 0cp position maps to 0.5 and wins/losses sum to 1, leaving no explicit draw model. This is a utility proxy. Prefer expected tournament score P(win)+0.5P(draw), with exact terminal outcomes. Stockfish WDL is an engine-selfplay model and is not automatically a human calibration.

### Different horizons systematically reward more explored opportunities

An unexpanded candidate uses a minimax-derived leaf proxy. An expanded one gets credit for observed opponent mistakes across additional plies. The comparison mixes different continuation assumptions. This can be a useful approximation, but extra expansion is not neutral and does not establish that the more expanded move is better.

### Fast can permanently miss the practical best move

ourChildrenToExpand gates alternatives by shallow centipawn gap and a cap of two outside the opening band. Values are computed after building; there is no online expectimax incumbent update. A slightly inferior engine move with much better human expectation can remain a leaf even with a larger fresh-build budget. Deep verification cannot recover the missing human subtree.

### Search priority is not reach probability

Alternative discounts multiply along a path even when those alternatives would become our chosen repertoire. Master factors also multiply: 1+0.35 log(1+games) exceeds 1. Treating either quantity as actual probability for cold-zone error reasoning is unjustified. Summing transposition arrivals across alternative own policies is also not one policy's reach probability.

### Master practice is not necessarily the target opponent

The default master book dominates the Maia prior where counts are high. Changing maiaElo then has little effect on those positions. Master games are excellent candidate evidence; treating their frequency as the user's opponent distribution needs an explicit population assumption. Keep candidate discovery separate from opponent modeling.

### Pure is selective full-width search, not an exact oracle

The enum comment acknowledges this. Pure retains MultiPV limits, opponent caps, probability floors, eval windows, master extensions and the same leaf/tail proxy. Its FIFO order is an implementation choice; BFS is not what makes expectimax mathematically pure.

### Transposition identity omits horizon and draw history

FenMap uses four-field FEN keys, discarding clocks and not recording path repetition or remaining search horizon. Sharing engine evaluations may be useful, but finite-horizon backed-up values are not generally interchangeable at different horizons or repetition histories. The build comments also leave terminal nodes indistinguishable from failed expansion; terminal outcomes should be determined from board rules.

### Verification completion can overclaim after its last pass

Static finding: the third pass can demote and reselect a new branch, then the loop ends and completed is simply !cancelled. The final new continuation need not have been checked. Keep a set of verified final decisions and require it to cover the final policy.

### Tail mass is a sensible accounting device, not an uncertainty estimate

Keeping original probabilities and assigning omitted mass a fallback is better than renormalizing the retained replies. But the parent engine score is neither the conditional expected value of omitted replies nor a certified bound from finite-depth Stockfish. Show how much mass remains unresolved and its potential effect on root ranking.

## Parameter decisions

| Decision | Parameters | Reason |
| --- | --- | --- |
| Keep explicit | Opponent population/rating; side and starting position; time/node budget; preparation horizon; one clearly defined engine-loss tolerance. | These describe the problem or the acceptable effort/risk. |
| Keep internally, measure | Candidate width, engine budget, policy prior strength, progressive widening, missing-mass tolerance. | Tune against an exact reference and held-out opponent data; avoid stacking unrelated floors and caps. |
| Remove from the default objective | Novelty multiplier, fewest-good-replies override, priority-dependent eval-loss window. | Novelty is not a demonstrated change in opponent behavior. Reply counts ignore probabilities and depend on which replies were expanded. Safety tolerance should not change with scheduling priority. |
| Remove or replace | Global leafConfidence. | With valid mass and novelty off, a common positive affine transformation of all leaf and tail values commutes with max and expectation. For c>0 it rescales values but does not change their ordering. c=0 collapses everything to ties. Genuine confidence must vary by evidence and guide refinement. |
| Separate from search | Setup/pins, memorability, chapter sizes, engine tails, model games, line diversity. | Pins/setup are policy constraints; learned memorability can be a separate cost. Export controls do not belong in the mathematical search objective. |

## The design I would build from scratch

First define the task: choose a preparation policy that maximizes expected tournament points against a specified opponent policy, subject to a declared engine-loss tolerance. Assume we follow the prepared moves perfectly within the horizon. That assumption is appropriate for finding a repertoire; it does not model forgetting or our later human errors.

The engine-loss guard defines the allowed action set; it is a deliberate constraint on expectimax, not expectimax itself. Compare against a fresh unrestricted engine best move. A finite engine search establishes a budget-relative safety check, never a proof that a move is objectively safe.

For the first version, use a bounded engine-derived expected-score proxy and label it honestly. Preserve exact terminal outcomes. A human-calibrated value model would require held-out outcomes conditioned on rating, time control and position features; simply replacing the sigmoid with engine WDL does not supply that calibration. A learned human value head also describes its training continuation policy, which need not match a perfectly followed repertoire.

Start Pure as a deliberately small exact reference, even if it is too slow for long openings. Cache engine evaluations separately from horizon-dependent backed-up values. Larger production runs can use iterative horizons. If a practical Pure mode retains a fixed shortlist, call its result exact only within that declared shortlist and horizon.

Fast should spend work where the root decision might change: plausible challengers, likely opponent replies, missing probability mass and uncertain evaluations. Search rare forcing replies for safety even when their modeled probability is tiny. Avoid permanently locking candidates out because their shallow centipawn gap exceeds 30cp.

For utilities in [0,1], unresolved chance mass m contributes an interval of width at most m at that node if the remaining resolved values are exact. Propagate these intervals through max and expectation. Engine and model error need separate empirical treatment; finite-depth evaluations are not rigorous bounds. Path probabilities must be conditional on the policy under consideration, not summed indiscriminately across our alternatives.

```text
Terminal: U = 1 for a win, 0.5 for a draw, 0 for a loss
Our turn: V(s,h) = max over allowed a of V(next(s,a),h-1)
Opponent turn: V(s,h) = sum p(a|s,opponent) V(next(s,a),h-1)
Horizon: V(s,0) = declared leaf utility(s)
Store the selected move during the backup; export that policy.
```

| Contract | Pure | Fast |
| --- | --- | --- |
| Objective and opponent model | Shared, explicit | Identical to Pure |
| Action set | All legal moves, or an explicitly documented safety-constrained set evaluated for every legal candidate | Progressively consider the same action set; omitted candidates remain unresolved |
| Expansion | Complete small finite horizons; publish completed horizons for a usable reference | Best-first refinement and progressive widening under a fixed compute budget |
| Policy accounting | One distribution over legal opponent moves | Same distribution; retain omitted mass explicitly |
| Backups | Memoized by state, remaining horizon and necessary draw history | Incremental backups after new evidence; revisit the incumbent and challengers |
| Stopping | Completed requested horizon, or honest partial status | Budget exhausted or remaining uncertainty cannot change the choice within tolerance |
| Safety and export | Verify the final selected policy and export it | The same final verification and export contract |

## Validation before adding more tuning

Repair the six reproduced invariants first. Then require values in [0,1], conserved probability, identical chosen and valued policy, child-order invariance, repeated-calculation invariance, correct terminal/repetition handling, final verification coverage and export coverage. Use exhaustive tiny trees and legal transposition fixtures as an independent oracle, rather than tests that simply repeat the current heuristic formulas.

Benchmark Fast against Pure at a fixed opponent model and horizon. Report root decision regret under the same reference evaluator, agreement rate, engine work, unresolved mass and stability across budgets. Separately evaluate opponent probabilities with held-out log loss/calibration, split by rating and time control. Synthetic tests establish correctness failures; they do not measure practical chess strength.

Keep one canonical implementation or add shared cross-language fixtures. Today the app uses Dart while MCP expectimax launches C, and their policy handling already differs. A repair in one does not automatically repair the other.

## Sources and reproduction

[Official Stockfish WDL documentation](https://official-stockfish.github.io/docs/stockfish-wiki/Useful-data.html): its score normalization and WDL model are based on engine selfplay.

[Maia project](https://www.maiachess.com/): human move prediction alone does not calibrate this pipeline’s final win percentages.

[Six counterexample tests](/home/anbernal/.local/share/chess-prep/worktrees/expectimax-review-20260905/test/services/generation/review_counterexamples_test.dart)

[Test output](/home/anbernal/.local/share/chess-prep/worktrees/expectimax-review-20260905/expectimax-review-tests.log)
