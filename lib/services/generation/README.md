# Repertoire generation — module map and invariants

Read this before editing anything under `lib/services/generation/`,
`lib/services/tree_build_service.dart`, or
`lib/core/generation_session_controller.dart`. The invariants below are
enforced by scattered doc comments and tests; this page is the single map.
The Dart implementation ports a proven C `tree_builder`; comments saying
"matches C" mark intentional parity — do not "fix" them casually.

## Pipeline

`GenerationSessionController` owns the whole run and every artifact:

| Phase | What | Where |
|---|---|---|
| 1 | Build the tree: engine/DB/Maia expansion, eval-window pruning, transpositions, coverage sweep | `tree_build_service.dart`, `node_expander.dart` (+ `stockfish_expander.dart`, `maia_db_expander.dart` parts), `build_run.dart`, `frontier_queue.dart` |
| 2 | Value + select: ease, expectimax, CPL, trap scores, selection | `tree_ease.dart`, `tree_my_ease.dart`, `eca_calculator.dart`, `repertoire_selector.dart`, `node_selection.dart` |
| 2.5 | Deep verification of the selected moves | `repertoire_verifier.dart` |
| 3 | Extract lines, prune similar ones, export PGN / snapshots / traps | `line_extractor.dart`, `line_pruner.dart`, `pgn_export.dart`, `snapshot_export.dart`, `trap_extractor.dart` |

`line_pruner.dart` runs after extraction when `targetLineCount > 0`
(default 100): greedy weighted set cover over each line's
`LineCoverageUnit`s — keyed by our-move projection prefix (opponent moves
excluded), valued by reach probability × only-move sharpness — so lines
that answer different opponent deviations with the same our-moves collapse
to one representative. The build tree itself is never pruned by this; it is
an export-time view.

Phase 1 is the only phase that touches engines or the network. Phases 2–3
are pure functions over the tree — keep them that way; it is what makes
them unit-testable without fakes.

`BuildRun` holds all per-run state (id allocator, stats, cancellation,
pause gate). `TreeBuildService._startRun` must stay **synchronous up to the
re-entrancy guard** so overlapping `build()` calls fail loudly instead of
racing.

## The two numbers on every node

`BuildTreeNode` carries two probability-like fields with different jobs:

- **`cumulativeProbability`** — product of *opponent* move probabilities
  from the root (our moves multiply by 1.0). Feeds expectimax, selection,
  and extraction. This is a **valuation** input.
- **`searchPriority`** — `cumulativeProbability` further discounted at
  our-move alternatives (`ourAltDiscount` for non-incumbents). Orders the
  best-first frontier and scales Fast pruning. This is a **scheduling**
  signal only. It must never feed Phase 2 — if a change makes valuation
  depend on it, the repertoire quality becomes a function of search order.
- `searchPriority == -1.0` means "not set" (legacy trees); readers fall
  back to `cumulativeProbability` via `effectiveSearchPriority`.
- `searchPriorityDiscount` (the local edge discount) is **not serialized**;
  after a resume, a zero→positive transposition rebuild degrades to
  undiscounted priorities. Known wart, documented on the field.

## Probability conventions (do not renormalize)

Opponent children carry **raw** probabilities: Σpᵢ ≤ 1 over the emitted
subset. The uncovered remainder is handled by the expectimax **tail term**
(`eca_calculator.dart`): `V = Σ pᵢ·V(childᵢ) + (1 − Σpᵢ)·leafValue(node)`.
Renormalizing children to sum to 1 would silently bias V toward whatever
happened to be expanded. Dirichlet smoothing (`opponent_prior.dart`,
`p = (count + λ·maia) / (N + λ)`) replaces the counts→probability estimate,
not this convention.

## Eval sign zoo

Three conventions coexist; most historical bugs here are sign bugs:

- `BuildTreeNode.engineEvalCp` — **side-to-move** relative. Use
  `evalForUs(playAsWhite)` for "our" perspective.
- `EvalCache`, `lookupDbEvalWhite`, `DiscoveryLine.effectiveCp` —
  **White-POV**.
- `EvalResult.effectiveCp` (single evals, verifier) — **side-to-move**.

A child of an our-move White node is a Black-to-move position, so "+40 for
us" is stored as `engineEvalCp = -40`.

## Transpositions

`FenMap` maps a canonicalized FEN to one **canonical** node (the expanded
subtree) plus transposition leaves. Rules:

- A node whose position is already canonical elsewhere becomes a childless
  transposition leaf (`_resolveTranspositionOrRegister`).
- If the new path reaches the position with **higher** cumP,
  `propagateHigherCumP` (`tree_prune.dart`) rescales the canonical subtree
  by the ratio — or, when the old cumP was 0, rebuilds cumPs from edge
  probabilities. Re-enqueued nodes are re-sifted in place by the indexed
  heap (`frontier_queue.dart`), never duplicated.
- Expectimax runs **two passes** so transposition leaves visited before
  their canonical borrow the corrected value. Chains of borrows longer
  than one hop may not fully converge — accepted truncation, C parity.
- Selection, extraction, and verification all resolve transpositions with
  a **cycle guard** (`visited` set of canonical FENs) — a redirect to a
  shallower node would otherwise recurse forever.

## Coverage guarantee (no silent holes)

Any opponent reply whose **local** probability ≥ `coverMinProb` must have a
repertoire answer. Enforced twice:

1. During expansion: such replies bypass *every* filter in
   `addOpponentChildren` (budgets, floors, mass target, child caps).
2. End of build: `_coverageSweep` finds dangling our-turn leaves and either
   coverage-expands them (one evaluated answer, no subtree) or removes them
   so their mass returns honestly to the tail term.

Coverage-floored nodes sit below `minProbability`; selection and extraction
have matching `covered` checks so those answers survive to the PGN. If you
add a filter anywhere in the fan-out or selection path, it must have a
coverage-floor bypass.

## Fast vs Pure search

Pure = exhaustive FIFO BFS at full width. Fast = best-first (max-heap on
`searchPriority`) plus priority-scaled pruning — an *anytime* algorithm:

- Hot/warm/cold zones (`fastWarmPriority` / `fastColdPriority` in
  `generation_config.dart`) shrink MultiPV, halve the eval-loss window, and
  halve opponent fan-out in cold subtrees.
- Our-move alternatives more than `fastAltGapCp` behind the incumbent stay
  **evaluated leaves** (selection still sees them; the verifier deep-checks
  whatever wins). At most `fastMaxExpandedAlts` alternatives get subtrees.
- The first `openingWidthPlies` of our moves are exempt: wide MultiPV
  floor, full window, no alt gate (a narrow early fan-out can never be
  recovered later).
- Trappy selection disables the alt gate entirely — worse-eval moves are
  the point and need searched subtrees.

Search priorities shape **which nodes exist**, never how they are valued.

## Verification pass (Phase 2.5)

`RepertoireVerifier` re-evaluates every selected move at
`resolvedVerifyDepth`, demotes moves that lose more than `maxEvalLossCp`
against the best deep-checked sibling, then re-runs expectimax + selection
and verifies the new spine (max 3 passes; deep evals cached across passes).
It changes evals and selection only — never tree structure. Caveats:

- If pass 3 still demotes, the final re-selection is **not** re-verified
  but the report still says `completed` — the "depth guarantee" is
  best-effort in that edge case.
- `completed == false` (no engine / cancelled) means the guarantee does
  not hold; the session controller surfaces this in the run summary.

## Danger zones — checklist before you change things

- Don't renormalize opponent probabilities (tail term breaks).
- Don't let `searchPriority` feed expectimax/selection.
- Don't add a fan-out or selection filter without a coverage-floor bypass.
- Don't mark `explored = true` before expansion fully finishes (resume
  relies on `explored == false` meaning "safe to redo").
- Don't make `_startRun` (or anything before it in `build()`) async.
- Don't bypass `FrontierQueue.add` idempotency — priorities rescaled while
  queued must re-sift, not duplicate.
- Mind the sign zoo when moving evals between caches and nodes.
- New `ChangeNotifier` services in the pipeline need `SafeChangeNotifier`
  (see CLAUDE.md).

## Test map

All in `test/services/generation/` unless noted:

- Build loop control flow (headless, real `TreeBuildService.build`):
  `tree_build_invariants_test.dart`
- Expanders + fan-out with scripted engine/Maia fakes (`engine_fakes.dart`,
  `MaiaFactory.testOverride`): `node_expander_test.dart`
- Verifier demote/re-select loop: `repertoire_verifier_test.dart`
- Frontier heap (idempotent add, re-sift, determinism):
  `frontier_queue_test.dart`
- Expectimax / tail term / novelty: `eca_calculator_test.dart`
- Selection modes, coverage floor, setup bias, idempotency:
  `repertoire_selector_test.dart`, `setup_bias_test.dart`,
  `node_selection_test.dart`
- Smoothing math: `opponent_prior_test.dart`
- Fast-zone scaling + config round-trips: `search_algorithm_test.dart`
- Prune + cumP propagation: `tree_prune_test.dart`
- Full Phase 2→3 pipeline on synthetic trees:
  `select_then_extract_test.dart`, `line_extractor_test.dart`
- Session controller progress/dispose:
  `test/core/generation_session_controller_test.dart`
