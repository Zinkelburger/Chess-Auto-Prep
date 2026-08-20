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
| 3.5 | Ask the engine how each losing reply is punished, and what the moves the book leaves out run into | `course/refutation_prober.dart` |
| 3.5 | Compose the surviving lines into a course: chapters, ECO names, model games | `course/` |

`line_pruner.dart` runs after extraction when `targetLineCount > 0`
(default 100): greedy weighted set cover over each line's
`LineCoverageUnit`s — keyed by our-move projection prefix (opponent moves
excluded), valued by reach probability × only-move sharpness — so lines
that answer different opponent deviations with the same our-moves collapse
to one representative. The build tree itself is never pruned by this; it is
an export-time view.

Phase 1 is the only phase that touches engines or the network. Phases 2–3.5
are pure functions over the tree — keep them that way; it is what makes
them unit-testable without fakes. (Phase 3.5 loads the bundled ECO book, an
asset read, and degrades to move-based names when it is unavailable.)

## Course composition (`course/`)

A repertoire tree flattened into root-to-leaf paths is what a machine wants
and not at all how a person studies one. Phase 3.5 re-imposes the structure
the flattening destroyed:

| File | Job |
|---|---|
| `chapter_planner.dart` | Cut the line list at branch points until every chapter is between `minLinesPerChapter` and `maxLinesPerChapter`. Branches too small to be chapters are swept into one "rare sidelines" bucket. Pure list surgery — no chess. |
| `opening_namer.dart` | Deepest ECO-book hit along a move sequence (FEN-keyed, so transpositions name correctly), plus move-reference formatting (`6.Be3` / `6...Bg7`). |
| `chapter_titles.dart` | Course title, chapter names, variation names. Strips the opening-family segments every chapter shares — a Maroczy course does not repeat "Sicilian Defense: Accelerated Dragon" twelve times — then disambiguates collisions with the defining move. |
| `model_game_selector.dart` | Picks database games that follow the *selected* repertoire (our moves must be the chosen ones), ranked by follow depth, then result from our side, then rating; round-robins over variations so a course covers its chapters instead of showing six wins in one line. |
| `course_composer.dart` | Assembles everything into `PgnGameSpec`s. |

**Chapters are headers, not variation trees.** Each line stays its own PGN
game and the chapter is named in `[White]`, the variation in `[Black]`, with
`[Result "*"]` — the format `RepertoireService.detectHeaderChapters` already
reads. This is deliberate: `parseRepertoirePgn` follows `mainline()` only, so
folding a chapter's lines into one game with variations would silently reduce
the chapter to a single trainable line. Any change here must keep
`course_composer_test.dart`'s round-trip through `RepertoireService` green.

Model games carry `[Result "*"]` for the same reason — a decisive result would
drop them out of chapter detection — with the real game preserved under
`ModelGame*` tags. Those tags are also the *marker*: `RepertoireLine.
isModelGame` reads them back, and the trainer, the deviation walker and
`matchingBookLines` all skip such lines. A model game is somebody else's moves
in a file full of yours — drilling it, or counting it as your book when your
own games are checked, is wrong in both directions.

A model game is annotated at exactly one move: where it leaves the
repertoire. `ModelGameSelector` records the departure while it follows the
game through the tree (`ModelGameDeparture`): if *our* side departed, the
composer writes `{Our repertoire: 10...Qb6}` on the game's move — `… —
improves on 10...Nf6 (+0.35)` when the improvement probe backed that exact
departure — and hangs our mainline off it as a variation; if the opponent
departed, `{Outside the repertoire — prepared here: …}`. The same movetext is
emitted a second time as real games (`ComposedCourse.modelGamePgns`) and the
session controller writes it to `<repertoire>_model_games.pgn` beside the
course, for the PGN viewer; the in-course chapter stays the study copy.

**Nothing writes prose comments.** A generated comment nobody asked for is
noise a reader learns to skip, which costs the annotations that do carry
information (`[%eval]`, `[%maiaProbability]`, …). Where the export used to
explain in words that a line ended because we were already winning, it now
*shows* it: `RefutationProber` asks the engine how the position is won and the
punishment is written as a sideline on the losing move, repeating that move so
it reads as a continuation rather than an alternative. The mainline still ends
where the repertoire ends, so nothing new becomes trainable.

The same prober answers the other question a reader asks — "why isn't the
natural move here?" — in `probeAlternatives`. The tree cannot answer it: our
children are all inside the eval-loss window (default 50cp), so a *refuted*
move of ours was never a child, and their rejected tries sit below the Maia
candidate floor. So the pass brings its own move source (Maia's policy, or the
game database when Maia is unavailable), skips whatever the tree already
holds, and searches the position after each candidate. Only a move that costs
the side playing it at least `minLossCp` is written, as an alternative sideline
carrying `?`/`?!` and a `[%loss]` token — a move that turns out to be playable
drops out, because "we don't play this" about a perfectly good move is a lie.
`LineChoice` (from `line_extractor.dart`) is what carries the position, its
best available eval and its known moves out of extraction; it is keyed by FEN
so lines sharing a prefix share one search.

Both passes are capped, deduplicated and best-effort: no engine, no move
source, a cancelled run or a failed search costs variations, never the export.

## Export (`export/`)

`writePgnGame` is the **only** PGN emitter in the pipeline. There used to be
two (`LineExtractor.exportPgn` and `pgn_export.buildRepertoirePgnEntry`) with
separately maintained copies of the annotation logic, which is exactly how
they drifted. `MoveAnnotation` carries everything the tree knows about a move
— eval, ease, naturalness, practical score, recency — and
`MoveAnnotationDetail` decides how much of it reaches the file. Absent fields
are omitted rather than defaulted: an unmeasured score must not read like an
even one.

## Where human-practice data comes from

Two sources. `BuildMode.dbExplorer` scans the user's own PGN files
(`pgn_freq_map.dart`, below). Every other mode consults the **master-games
book** (`services/master_games/`, TWIC in SQLite) through `BuildRun.
masterBook` when the database is downloaded and `useMasterGames` is on, and
Maia otherwise. The Lichess Explorer fetch path is mothballed app-wide
(`ProbabilityService` returns null unconditionally) — `useLichessDb`,
`useMasters`, `speeds`, `ratingRange`, `minGames` and `maiaOnly` on
`TreeBuildConfig` are inert and survive only because the audit/holes/tricks
features still build configs with them.

**Master practice as the guide.** With a book in use the build treats a
position as *master practice* when it has at least `masterMinGames` book
games (`BuildRun.isMasterPractice`), and:

- opponent replies at book positions are book frequencies Dirichlet-blended
  with Maia (`opponent_prior.dart`); at off-book positions they are Maia
  alone, capped at `offBookOppMaxChildren` (`NodeExpander._offBookCap`) so
  the node budget goes to depth where there is practice rather than breadth
  where there is none — the coverage floor still bypasses the cap;
- our-move nodes always get the book's `kMasterCandidateCount` most-played
  moves as eval-gated candidates (`injectMasterCandidates`), so selection
  can choose what masters play even when MultiPV omits it — it still
  decides on eval;
- the ply cap is `maxPly`, plus `masterDepthBonusPlies` while the position
  is still master practice (`BuildRun.plyCapAt`, checked per node in
  `_processBuildNode`) — a book line runs deeper, a Maia-only sideline stops
  at `maxPly`.

No database, or a position the book has never seen, degrades to exactly the
Maia-only behaviour. The book is indexed to `kBookMaxPly` (30), which bounds
the depth bonus on its own.

`pgn_freq_map.dart` is therefore the app's model of human practice: per move,
counts **plus** win/draw/loss, mean rating, and the last year played, with a
bounded reservoir of the strongest games retained whole
(`TopGamesReservoir`) so model-game selection needs no second pass over the
source files. Retention deliberately runs on its own terms: it continues past
`maxPly` (statistics stop at the build depth; a model game truncated there
would be ten moves of opening and nothing to illustrate), keeps its own rating
floor, and is sized well above `modelGameCount` because retention ranks by
rating while selection needs games that *follow this repertoire*.
`pgn_freq_parser.dart` does the scanning;
`pgn_freq_cache.dart` persists it in a versioned, length-prefixed format —
a stale or corrupt cache is a miss, never a wrong answer.

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

**One deliberate exception:** `TreeBuildConfig.rootReplyExclude`, applied at
`ply == 0` only, drops replies *before* the bypass. It is not a fan-out
filter but an ownership boundary: the planner (`features/planner`) cuts
sibling chapters at an opponent tabiya — "QGD vs 3.Nc3", "vs Catalan" — and
a "sidelines" chapter rooted at the same position must leave those replies
to the chapters that own them, or two chapters build the same lines. The
hole is not silent: every excluded reply is the root of another chapter in
the same plan. Nothing else may skip the bypass.

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
- Chapter cutting, naming, model games, and the composed PGN (including the
  round-trip back through `RepertoireService`): `course/` subdirectory
- Annotation rendering: `export/move_annotation_test.dart`
- Frequency-map scanning (results, ratings, recency, game retention):
  `pgn_freq_map_test.dart`; cache round trip and every invalidation path:
  `pgn_freq_cache_test.dart`
- Persisted config shape (adding a key is safe, removing one is not):
  `generation_config_wire_format_test.dart`
