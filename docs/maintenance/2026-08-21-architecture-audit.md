# Architecture & maintainability audit — 2026-08-21

Produced by a multi-agent audit of `lib/`. Every claim below carries file:line
evidence. The bug fixes and the lint sweep are applied; the *structural*
refactors in "Recommended sequence" are proposals, not applied.

## Done in this pass

**Lint debt.** `dart fix --apply` — 271 mechanical fixes across 99 files
(`prefer_const_constructors` x148, `prefer_initializing_formals` x27,
`prefer_const_declarations` x24, `annotate_overrides` x18, ...).
Analyzer went from **274 issues to 15**, still 0 errors and 0 warnings.

**Bugs 1-4, 6, 7 and 8 below are fixed**, each with a regression test that was
verified to fail against the old code. See "Bug fixes applied" for details.
Bug 5 was examined and deliberately left alone.

Verified after every change: `dart format` clean, `flutter analyze lib test`
0 errors / 0 warnings, **2442 tests pass**.

## Bug fixes applied

1. **`promoteVariation` retargeted the cursor** (`lib/core/repertoire_controller.dart`).
   The audit found a missing `_syncOpeningTree()`; the defect was worse.
   `MoveTree.promoteVariation` does `removeAt(i)` + `insert(0, node)`, which
   shifts *every* sibling below `i` up by one — so a cursor parked on an
   earlier sibling silently came to point at a different move. The old code
   only repaired the cursor when it sat exactly on the promoted path.
   Fixed by remembering the cursor as a **move sequence** and re-resolving it
   after the reorder, which is stable under any reshuffle.
   Reproduced first: promoting `g6` moved a cursor on `e6` onto `g6`.
2. **The cursor/opening-tree desync class, closed by construction.** `_path` is
   now a getter/setter pair over a private `_cursor`, and the setter always
   re-syncs the opening tree. All 15 assignment sites (12 in the controller,
   3 in the persistence part) go through it, and the 12 now-redundant explicit
   `_syncOpeningTree()` calls were removed. Every site was checked to assign
   `_tree` *before* `_path`, which the sync reads.
3. **Lines-browser index staleness, closed by construction.** `_repertoireLines`
   is now a getter/setter pair that stores `List.unmodifiable(value)`, so the
   list can only be *replaced*, never edited in place — an in-place `add` or
   `[i] =` now throws instead of silently leaving `OpeningTreeWidget`
   (`opening_tree_widget.dart:95` compares list identity) showing stale rows.
   `appendNewLine` and `appendMoveToExistingLine` were rewritten to swap.
   `appendNewLines` builds into one scratch list and swaps once, so a bulk
   append pays a single copy rather than one per entry.
4. **"Clear filters" undone by its own debounce**
   (`repertoire_outline_panel.dart`). Extracted `_clearFilters()`, which
   cancels the pending timer before clearing. Widget test verified to fail
   against the old code.
5. **Two 2-second busy-polls replaced with the existing `awaitLoaded()`
   completer** (`repertoire_screen.dart`, `_openOutlineLine` and
   `_generateIntoChapter`). The poll capped at 2s and fell through with
   `repertoireLines` empty, opening the generation dialog on the wrong
   position. Both sites now also re-check `mounted` after the await.
6. **Outline-sync cache race** (`repertoire_screen.dart`). `_outlineChapterSeen`
   was written before the `await` and `_outlinePgnSeen` after it, so a
   notification arriving mid-flight saw a half-updated key and started a
   duplicate `open()`. Both halves are now claimed up front.
   (The `identical()` String comparison was examined and kept — for immutable
   Strings it can only ever over-refresh, never go stale.)
7. **PGN header escaping unified.** `escapeHeaderValue` moved to
   `lib/utils/pgn_utils.dart`, beside its inverse `extractHeaderValue`. The
   four copies now delegate — including `master_games_db._tag`, which escaped
   `"` but **not** `\`, producing malformed PGN on backslashed values. Five
   tests cover the ordering rule (backslashes must double *before* quotes are
   escaped).
8. **Dead code removed, ~250 lines.** `RepertoireService.createTrainingQuestions`
   / `filterQuestions` / `shuffleQuestions`, and the now-unreachable
   `RepertoireLine.createTrainingQuestion` + `TrainingQuestion` class behind
   them; `lib/models/chess_game.dart` (`ChessGameModel`, zero importers, and
   the buggiest of the three movetext tokenizers). The three dead
   `InteractivePgnEditor` params turned out to be a **three-level**
   pass-through chain, not the two the audit found: removed from
   `interactive_pgn_editor.dart`, `edit_main_zone.dart`,
   `pgn_with_analysis_pane.dart`, `study_side_pane.dart` and
   `repertoire_screen_tabs.dart`, plus four newly-unused imports.

**Deliberately not changed:** the `EngineSettings.instance.probabilityStartMoves`
write at `repertoire_screen.dart` (bug 5 in the original list). It is set on
*every* repertoire switch, so it cannot go stale between repertoires, and the
field is a persisted engine setting deliberately mirroring the active
repertoire's root. "Never reset on dispose" is the intended behaviour here, not
a leak. Flagging rather than changing it.

## Original bug list (as found; see above for what was fixed)

1. **`RepertoireController.promoteVariation`** (`lib/core/repertoire_controller.dart:397-406`)
   mutates `_path` at :403 but is the **only** path-mutating method that never
   calls `_syncOpeningTree()` — the other 13 sites do. The opening-tree cursor
   goes stale after a promote. *Fix: funnel every path mutation through one
   `_setPath(TreePath)` that always syncs.*

2. **Lines-browser index goes stale.** `updateSelectedLineContent`
   (`repertoire_controller.dart:621-624`) documents that consumers rebuild their
   search indexes **only when the list identity changes** — but `appendNewLine`
   (:659) does `_repertoireLines.add(...)` in place and
   `appendMoveToExistingLine` (:707) does `_repertoireLines[i] = ...` in place.
   Both skip the identity swap the browser needs. `repertoireLines` also returns
   the raw mutable list.

3. **"Clear filters" is undone by its own debounce.**
   `lib/features/repertoire/widgets/repertoire_outline_panel.dart:236-244`
   clears the field and `setState`s `_search = ''` but never cancels `_debounce`.
   Type `xyz`, clear within 200 ms → the timer fires (:109-111) and restores
   `_search = 'xyz'` against an empty field. Unrecoverable without retyping.

4. **Generation dialog can open on the wrong position.**
   `lib/screens/repertoire_screen.dart` waits for load two incompatible ways:
   `_controller.awaitLoaded()` (:515, :521, :533) vs. a busy-poll
   `for (var i = 0; i < 40 && _controller.isLoading; i++)` duplicated at
   :690-692 and :712-714. The poll caps at 2 s and falls through with
   `repertoireLines` empty → `_commonPrefix` returns `[]` (:717).

5. **Static mutable state written from `setState`, never reset.**
   `repertoire_screen.dart:566` — `EngineSettings.instance.probabilityStartMoves
   = _controller.rootMoves;` with no reset on dispose.

6. **`_outlinePgnSeen` uses `identical()` on a String** as a change token
   (`repertoire_screen.dart:600, :606`); the three-field outline cache is
   written at three different times across an `await` (:601 sync, :603-609 async).

7. **Dead field / dead params (zero behaviour change to remove):**
   - `plan_build_screen.dart:119 _reviewConfig` — never assigned, read once at :1201.
   - `InteractivePgnEditor.trapIndex` (:80), `.boardPreview` (:83),
     `.currentRepertoireName` (:76) — read nowhere; passed anyway from
     `edit_main_zone.dart:75,87,88` and `study_side_pane.dart:70`.
   - `RepertoireService.createTrainingQuestions` (:545-577), `filterQuestions`
     (:581-599), `shuffleQuestions` (:602-606) — **69 lines, zero callers** in
     `lib/` or `test/`.
   - `lib/models/chess_game.dart` (`ChessGameModel`) — no references in `lib/`.

8. **`master_games_db.dart:156`** `_tag` escapes `"` but **not** `\` — unlike the
   three other copies of header escaping. Malformed PGN on backslashed values.

## God classes, by effective size (`part` files hide the real number)

| Unit | File | Effective class | Verdict |
|---|---|---|---|
| `_PgnViewerScreenState` | `screens/pgn_viewer_screen.dart` 1238 | **2296** (+3 parts) | `part` shrinks one class |
| `_RepertoireScreenState` | `screens/repertoire_screen.dart` 1129 | **2440** (+3 parts) | `part` shrinks one class |
| `GenerationSessionController` | 1525 | 1525 | 24 mutable fields, 41 methods |
| `PgnViewerController` | `core/pgn_viewer_controller.dart` 856 | **1341** (+3 parts) | `part` shrinks one class |
| `TreeBuildConfig` | 1135 | 1135 | 71 fields × 4 hand-kept sites |
| `_PlanBuildScreenState` | `features/planner/widgets/plan_build_screen.dart` | **1159** | 34 methods, 20 `setState` |
| `TrainingSessionController` | 1107 | 1107 | 35 assignable fields |
| `RepertoireService` | 1092 | 1092 | 6 responsibilities |
| `TreeBuildService` | 746 | **1152** (+ `extension on`) | 3rd algorithm bolted on |
| `RepertoireController` | 736 | **1072** (+ mixin part) | 20 abstract accessors |
| `_GenerationConfigAdvanced` | `widgets/generation/generation_config_form_advanced.dart` | 867 | mixin with **0 fields** |

`node_expander.dart` is the model to copy: its `part` files declare *separate
types* (`StockfishExpander`, `MaiaDbExpander`) — exactly CLAUDE.md:72-77.
Four other `part` splits violate it by adding members to one class;
`pgn_viewer_screen_panes.dart:9-31` re-declares **22 abstract host members**
purely to see them, which is the clearest proof the split is fake.

## Longest methods

`_exportSection` 257 (`generation_config_form_advanced.dart:569-825`) ·
`build` 221 (`repertoire_screen.dart:908-1128`, max nesting **14**) ·
`_keyBindings` 190 (`pgn_viewer_screen.dart:996-1185`, rebuilt per key event) ·
`buildFromPgnFreqMap` 188 (`tree_build_db_explorer.dart:17-204`) ·
`_buildMoveRows` 163 (`interactive_pgn_editor.dart:618-780`) ·
`_buildGameTab` 160 (`pgn_viewer_screen_panes.dart:312-471`) ·
`_buildStepCard` 157 (`plan_build_screen.dart:890-1046`) ·
`_moveChoiceSection` 151 (`generation_config_form_advanced.dart:309-459`) ·
`_buildSidePanel` 146 · `_extractDfs` 142 (`line_extractor.dart:305-446`, 9
named params, ~6 nesting levels) · `build` 139 (`tree_build_service.dart:218-356`) ·
`_buildTrainTab` 128 (`repertoire_training_screen.dart:600-727`) ·
`parseRepertoirePgn` 124 (`repertoire_service.dart:64-187`, **shadows `i`** at
:100 vs :114).

## Cross-cutting duplication (largest clusters)

1. **Numbered movetext, 14 hand-rolled copies** of `if (i.isEven) buf.write('${i ~/ 2 + 1}.')`
   while the documented canonical `buildNumberedMovetext`
   (`utils/movetext_builder.dart:27`) sits unused by all of them.
   Byte-identical pairs: `plan_controller.dart:463` ≡ `plan_build_screen.dart:419`;
   `merge_conflict_sheet.dart:193` ≡ `trap_line_info.dart:157`;
   `eval_tree_details_pane.dart:578` ≡ `repertoire_tree_explorer.dart:639`.
   Full list in the "movetext" cluster below.
2. **~17 hand-rolled FEN field reads** instead of `fen_utils.dart`'s
   `isWhiteToMove` / `fullMoveNumber` / `normalizeFen` — several in files that
   *already import* `fen_utils.dart` and use it on the adjacent line
   (`engine_move_row.dart:193`, `inline_engine_bar.dart:527`, `plan_controller.dart:819`).
   Three can throw `RangeError` on a short FEN where the helper cannot:
   `plan_build_screen.dart:900`, `:1098`, `game_analysis_controller.dart:440`.
   A 4th spelling, `fen.contains(' w ')`, appears at 7 more sites.
3. **`tryParseFen` re-implemented privately 5×**, byte-identical bodies:
   `pgn_viewer_controller.dart:821`, `move_tree.dart:450`,
   `build_by_playing_queries.dart:81`, `skeleton_plan.dart:359`,
   `board_editor_controller.dart:253`. Three more are the same wrapper with a
   fallback (`repertoire_controller.dart:115`, `repertoire_service.dart:314`,
   `repertoire_screen_session.dart:305`).
4. **Move-number labelling (`3. Nf3` / `3...Nd2`) — 8 copies with 3 different
   arithmetic spellings** (`ply ~/ 2 + 1` on 0-based vs `(ply + 1) ~/ 2` on
   1-based) that must stay in agreement. Latent off-by-one.
5. **Three movetext tokenizers and three header parsers**, where the
   non-canonical copies are demonstrably buggier: `chess_game.dart:85-105`
   (`RegExp(r'\d+\.')` misses `3...Nf6`), `chess_game.dart:38-42`
   (`[^"]+` silently drops `[Site ""]`), `position_analysis.dart:214-221`
   (byte copy of `pgn_utils.extractHeaderValue`).
6. **4-field FEN reducer re-implemented 3×** as `split(' ').take(4).join(' ')`
   (`move_tree.dart:283`, `audit_board_annotations.dart:21,25`) — and it behaves
   *differently* from `canonicalizeFen4` on runs of multiple spaces. That
   helper's doc comment declares it must have exactly one implementation
   because it feeds persistent cache keys.
7. **Header-value escaping 4×** (`chapter_naming.dart:24`,
   `tactics_pgn_codec.dart:39`, `tactics_solution_pgn.dart:16`,
   `master_games_db.dart:156` — the buggy one).
8. **Five hand-rolled generation/epoch tokens with ~35 manual staleness checks**:
   `PlanController._epoch`, `TrainingSessionController._lineGeneration` and
   `._loadGeneration`, `PgnViewerController._sliceEpoch`,
   `TreeBuildService`'s. One `GenerationToken` with a `guard<T>()` helper in
   `lib/utils/` removes all of them.
9. **Hand-maintained parallel reset blocks that must agree:**
   `PgnViewerController` 3 blocks (:372 15 assignments, :443 15, :479 20);
   `TrainingSessionController` 2 blocks (`startLine` :652 17 fields,
   `stopSession` :779 12 — omits 7 of them).
10. **`StockfishPool` warm-up block copy-pasted 5×** verbatim in
    `generation_session_controller.dart` (:721, :915, :958, :1006, :1085).
11. **Promotion-move enumeration duplicated** verbatim:
    `opening_tree.dart:775-788` ≡ `move_input_widget.dart:184-196`.
12. **Duplicated name-entry dialog 3×**: `repertoire_list_body.dart:407-517` ≡
    `:617-696`, plus `snapshot_export_dialog.dart:50`.

## Layering

`grep -rlE "import '.*(widgets/|screens/)" lib/core lib/models lib/services lib/utils`
now returns **empty** — the exception CLAUDE.md:64 documents
(`utils/board_shape_comments.dart`) has been fixed. **CLAUDE.md should be
updated: the rule now holds with no exceptions.**

One violation of the rule's *spirit* outside the grep's scope:
`lib/features/repertoire/controllers/build_launcher.dart:23-24` imports
`widgets/build_by_playing/build_by_playing_form.dart` and
`widgets/games_repertoire/games_source_form.dart`. Widen the grep to
`lib/features/*/controllers lib/features/*/services lib/features/*/models`.

## Test-coverage gaps that set refactor risk

**No test at all:** `pgn_viewer_screen.dart` (2296 effective lines),
`repertoire_training_screen.dart` (949), `interactive_pgn_editor.dart` (887),
`generation_config_form*.dart` (2255 across 7 files), `repertoire_list_body.dart` (908).
**Thin:** `pgn_viewer_controller_test.dart` 261 lines for a 1341-line class;
`repertoire_outline_panel_test.dart` 7 tests for 1425 lines (drag-and-drop, the
folder menu, both pickers and section rows untested); `RepertoireService`
12 tests for 1092 lines.
**Good:** `training_session_controller_test.dart` (1208 lines),
`node_expander_test.dart` (945, 21 tests), `line_extractor_test.dart` (27 tests),
`tree_build_invariants_test.dart` (34 tests) — these are the safe places to cut.

## Recommended sequence (value ÷ risk, highest first)

| # | Change | Risk | Payoff |
|---|---|---|---|
| 1 | Delete dead code: `RepertoireService:545-613`, 3 `InteractivePgnEditor` params, `_reviewConfig`, `ChessGameModel` | nil | 6 files, −180 lines |
| 2 | Fix bugs 1–3 above (`_setPath` funnel, identity-swapping `_replace`, cancel `_debounce`) | low | 3 real bugs |
| 3 | `MoveAnnotator` out of `LineExtractor:520-665` (9 pure fns, zero owner state) | low | best-covered code in repo |
| 4 | `EnrichmentRunner` + 4 passes out of `GenerationSessionController:901-1105` | low | −160 lines, −4 fields, kills the 5× pool block |
| 5 | Route the 14 movetext copies + 17 FEN reads + 5 `tryParseFen` clones through existing helpers | low | −250 lines, fixes 3 `RangeError`s |
| 6 | `generation_config_form_advanced` → knob data + `GenerationKnobs` bag | low | 867→~120, first test seam |
| 7 | `repertoire_list_body` → `showNameEntryDialog` + `RepertoireLibrary` + `LibraryCard` | low | 908→~250 |
| 8 | `plan_build_screen` → 4 card widgets + `StartMovesEditor` | low | 1159→~500 |
| 9 | `repertoire_training_screen` panels take the controller, not 37 props | low | kills prop-forwarding tax |
| 10 | `LineSession` value object in `TrainingSessionController` (one reset, not two) | med | removes a bug class |
| 11 | `MovetextRenderer` out of `interactive_pgn_editor` — **write its test first** | med | kills the 4-site manual cache invalidation |
| 12 | `PgnViewerHandoff` + `DeviationBanner` out of `pgn_viewer_screen` | med | first tests for 2296 lines |
| 13 | `PgnCollection` value object in `PgnViewerController` (kills 3 reset blocks) | med-high | thin coverage |
| 14 | `TreeBuildConfig` field-descriptor table — **must keep `toJson` byte-identical**, `generation_config_wire_format_test.dart` guards it | med | −370 lines of repetition |
| 15 | Promote DB-explorer to a real `BuildAlgorithm`; then retire the 4 fake `part` splits | high | **the main item still outstanding** |

---

# Code review of the working-tree diff (`/code-review high`)

Reviewed: working tree vs `origin/main`, ~148 files. Most of it is mechanical
lint churn; the substantive changes are the removal of on-the-fly expectimax in
favour of a read-only "from built tree" pane, transposition merging in
`LineExtractor`, `FenMap.registerExpanded` + `addArrivalCumP` on build resume,
and the `RepertoireController` fixes above.

**Caveat:** the tree changed *during* the review — another Claude session was
editing `lib/services/generation/` concurrently (`propagateHigherCumP` was
renamed to `addArrivalCumP` mid-review). Findings 2-5 landed in that in-flight
code. They were left alone in the first pass and fixed in a second pass once
that session had been quiet for 20 minutes.

## Fixed

**R1. Unevaluated opponent replies rendered as forced mate.** Two independent
defects compounding, both fixed with regression tests:

- `expectimax_line_service.dart` — `expectimaxLinesForAllMoves` passes
  `limit: null`, so the opponent branch listed *every* child. Unlike the
  our-move branch directly above it, it did not filter `!child.hasExpectimax`.
  `BuildTreeNode.expectimaxValue` defaults to `0.0`, so a node the build never
  evaluated read back as a lost position. Opening the expectimax pane on a
  paused or partial build at an opponent-to-move node listed every unexplored
  reply as a forced loss. Fixed by applying the same gate to both branches.
- `utils/ease_utils.dart` — `expectedCpFromWinProb` saturated at ±9999, but
  `kMateCpThreshold` is 9000, so `formatPackedEval` ran the saturated value
  through `cpToMate` and displayed **`#1` / `-#1`**. This hit legitimately
  decided positions too (`v >= 0.99`), not just unevaluated ones — at three
  display sites (`expectimax_lines_pane.dart`, `repertoire_analysis_dock.dart`).
  Fixed by capping at `kMateCpThreshold - 1`: this is a heuristic score derived
  from a probability and must never land in the range display code reads as a
  proven mate. The mid-range curve is unchanged.

## Also fixed (second pass)

**R2. `FenMap.registerExpanded` now re-seeds the transposition equivalence
lists, not just the canonicals.** Seeding `_canonical` alone was not enough:
`addArrivalCumP` forwards a new arrival's reach through a leaf only when that
leaf is a *registered* transposition, checked against `getTranspositions`. With
that map empty on resume the walk stopped at every saved leaf instead of
forwarding into its canonical, so a canonical whose true reach now cleared
`minProbability` was never re-queued, and the coverage sweep under-counted
reach and deleted holes it should have answered. A second pass registers every
**explored** childless node whose FEN has a canonical elsewhere — exactly what
`_resolveTranspositionOrRegister` produced last session. Unexplored frontier
leaves are deliberately excluded (they contribute their full reach when the
build processes them; registering them would double-count), and terminal or
depth-capped leaves are skipped by the canonical-identity check. Adds no reach
of its own, because arrival mass is only ever added when `addTransposition`
reports a leaf as *newly* registered.

**R3. `LinePruner` now pins the owner of every kept transposition stub.** A stub
ends with "Transposes to 1. d4 ..." and deliberately omits the continuation. The
greedy scored stub and owner independently, so with `coverageTarget < 1.0` the
prefix could keep the stub and drop the owner — leaving the book naming a move
order it does not contain and the shared continuation taught nowhere. Pinning
iterates to a fixed point (a pinned owner may itself be a stub) and may exceed
`targetCount`: an owner teaches strictly more than the stub referencing it, so
honouring the cap by leaving a dangling reference is the worse book.

**R4. Merged-line probability no longer inflated.** `_extractDfs` now threads
path reach the same way `_ownerDfs` already did — unchanged across our own move,
scaled by `moveProbability` across the opponent's — and both merge branches emit
that instead of reading `cumulativeProbability` off the node. The old code's
comment ("the build propagates the highest arrival") stopped being true when
`addArrivalCumP` replaced max-propagation with summing; when the merging arrival
was itself the canonical node, the stub was credited with every other move
order's mass as well, which then drove the pruner's coverage accounting, the
`rankLinesByImportance` sort, and the exported percentage. The two merge
branches also disagreed with each other; they now use one rule.

**R5 (first pass). Dangling transposition pointers are withdrawn rather than
exported.**
`LineExtractor.withdrawDanglingTranspositions` runs as the last step before
ranking in both export paths, and drops any pointer naming a move order no
surviving line plays — the residue R3's pinning cannot reach, plus the
cycle-guard divergence between the two traversals (they carry independent
`visited` sets, so a position whose owner path is cut in pass 2 can have both
arrivals stop). `MoveAnnotation.withoutTransposition` is the exact inverse of
`withTransposition`, so prose that was already on the annotation survives.
`danglingTranspositions` reports the count, and the controller logs it, so the
condition is never silent. This makes the output honest; the traversal divergence
itself is fixed by the repair pass below.

## FEN handling made defensive (the "hand-rolled reads")

`lib/utils/fen_utils.dart` is now the single reader, and every helper in it is
total — none throws, none needs the caller to check the field count first.
Added `plyFromFen`, defined purely from `fullMoveNumber` and `isWhiteToMove` so
it can never contradict them: `ply.isEven == isWhiteToMove(fen)` and
`ply ~/ 2 + 1 == fullMoveNumber(fen)` hold on *every* input, malformed included.

Swept onto the canonical helpers:

- **5 sites that could throw `RangeError`** on a short FEN —
  `plan_build_screen.dart` (x2), `game_analysis_controller.dart`,
  `plan_controller.dart`, `plan_data_source.dart`.
- **3 hand-rolled start-ply computations** — `engine_move_row.dart`,
  `inline_engine_bar.dart`, `expectimax_lines_pane.dart`. Two of the three
  already imported `fen_utils` and called `isWhiteToMove` on the adjacent line
  while inlining the full-move parse.
- **7 `fen.contains(' w ')` substring hacks** — `hole_hunt_service.dart` (x4),
  `trick_hunt_service.dart`, `trick_scoring.dart`,
  `repertoire_audit_service.dart`.
- **6 more side-to-move reads** — `move_tree.dart`, `opening_tree.dart`,
  `repertoire_merge.dart`, `opening_tree_widget.dart`,
  `static_board_thumbnail.dart`, `expectimax_lines_pane.dart`.
- **3 re-implementations of the 4-field reducer** as
  `split(' ').take(4).join(' ')` — `audit_board_annotations.dart` (x2),
  `move_tree.dart`. These behaved *differently* from `canonicalizeFen4` on runs
  of multiple spaces, and that helper's own doc says it must have exactly one
  implementation because it feeds persistent cache keys.
- **6 `tryParseFen` clones** — `move_tree.dart`,
  `build_by_playing_queries.dart`, `skeleton_plan.dart`,
  `pgn_viewer_controller.dart`, `board_editor_controller.dart`,
  `position_analysis_widget.dart` — plus two more that were the same wrapper
  with a fallback (`repertoire_controller.dart`, `repertoire_service.dart`).
- **2 hand-rolled full-move parses** — `line_extractor.dart`,
  `pgn_comment_utils.dart`.

New `test/utils/fen_utils_test.dart` (13 tests) covers the helpers, including a
property check that the three agree with each other across well-formed and
malformed input.

**Left alone, deliberately:**
`isWhiteToMove`'s "malformed reads as *not* White" fallback. An attempt to make
the family fall back to the standard start was caught by
`test/services/fen_move_validation_test.dart`, whose whole purpose is to pin
adversarial-input behaviour so a refactor cannot change it silently. That guard
was right and `plyFromFen` was reconciled to it instead.
`board_editor_controller`'s 6-field decompose (a real editor, not a duplicate),
`trap_line_builder._samePosition` (a documented whitespace-tolerant 2-field
comparator), `tactics_import_analysis._isOpeningFen` (returns false on an
unknown move number by design), `repertoire_screen_session._positionFromFen`
(logs the parse exception, which the shared helper discards), and
`pgn_parsing_service._positionFromHeaders`, which throws **on purpose** — its
doc says replay helpers catch it to skip an unparsable game.

## R5, structurally fixed (third pass)

The withdrawal pass made the output honest; it did not stop the coverage loss.
The cause is that `_ownerDfs` explores paths `_extractDfs` does not — the owner
walk never stops at a merge, so it can hand a position's continuation to an
arrival the extraction walk cannot reach. `extract` now **walks, checks, and
repairs**: after each traversal it looks at every deferral the walk made and,
where the named owner's move order is not actually in the output, hands
ownership back to the arrival that deferred, then walks again. Each round
strictly increases the number of positions owned by a reachable arrival, so it
converges; `_maxOwnershipRepairs` is a backstop for a pathological tree and
`withdrawDanglingTranspositions` still cleans up anything left (a genuine
cycle, for instance).

The invariant is now tested directly across five tree shapes: every
`transposesInto` names a move order some emitted line plays, and the shared
continuation is still taught exactly once.

## Duplication removed

**Numbered movetext: 16 hand-rolled copies now go through
`buildNumberedMovetext`.** The blocker was that two *different* formats were in
use — `1. e4 e5` and compact `1.e4 e5` — with roughly half the copies in each,
so a blanket sweep onto the canonical helper would have silently reformatted
half the app. The helper now takes `compact:`, which keeps one serializer
rather than one per style, and every copy routes through it:
`pgn_utils.formatMovesForSearch`, `repertoire_service._movesToPgnMoveText`,
`trap_line_info.movesText`, `merge_conflict_sheet._lineLabel`,
`audit_finding.movePathString`, `audit_config_panel._moveSequenceLabel`,
`opening_review.formatNumberedSans`, `opening_tree_widget._movetext`,
`master_games_importer._compactMovetext`, `plan_controller._label`,
`plan_build_screen._movesLabel` (byte-identical to each other),
`repertoire_outline.preview`, `eval_tree_details_pane` and
`repertoire_tree_explorer` (also byte-identical, and both re-derived the
`whiteToMoveFirst` handling the helper already had), plus
`opening_tree.getMovePathString` and `.currentMovePathString`.

**`formatMoveAtPly` moved to `movetext_builder.dart`** beside the serializer it
has to agree with, and `audit_finding._sanWithMoveNumber` now delegates to it.

## Extracted: `MoveAnnotator`

`lib/services/generation/export/move_annotator.dart` — everything said *about* a
move (eval, difficulty, forced-ness, the natural alternative's cost, the
opponent's error) is now a collaborator with its own constructor, taking
`playAsWhite` and `maxEvalLossCp` **by value** rather than a config reference:
the extractor never reassigns them mid-run, so a snapshot cannot desync (the
supplier-callback rule in CLAUDE.md applies to owner state that *is*
reassigned). `LineExtractor` drops from 865 to 704 lines and the annotator gets
11 unit tests that need no tree traversal — the seam the extraction was for.

## Single-move labels, unified

The `3. Nf3` / `3... Nf6` cluster is now three composed helpers in
`utils/movetext_builder.dart`, so the dot rule has exactly one home:

- `moveNumberAtPly(ply, {startMoveNumber})` — 0-based ply to move number.
- `moveNumberLabel({moveNumber, isWhite})` — just the `3.` / `3...` prefix,
  for widget rows that render it in its own `Text`.
- `formatNumberedMove(san, {moveNumber, isWhite, compact})` — for callers that
  already hold the number and side authoritatively.
- `formatMoveAtPly(ply, san, {compact, startMoveNumber})` — composes the two.

Each site's convention was established from its own source before converting,
and each conversion is byte-identical:

| Site | Convention | Style |
|---|---|---|
| `move_display.notation` | holds `fullMoveNumber` + `isWhiteMove` | spaced |
| `opening_namer.formatMoveReference` | 0-based ply + `startMoveNumber` | compact |
| `draft_repertoire_writer.lastMoveLabel` | 1-based move *count* (`ply = depth - 1`) | compact |
| `game_analysis_chart` tooltip | 1-based `MoveEval.ply` | spaced |
| `game_analysis_tab` row | 1-based ply, authoritative `isWhiteMove` | prefix only |

An earlier note here claimed `draft_repertoire_writer` inverted the dots. It
does not — `depth` is a move *count*, not a 0-based index, so `depth.isOdd`
correctly means White. Reading it as an index is exactly the off-by-one this
cluster invites, which is why each site was checked rather than swept.

23 tests cover the helpers, including that `formatMoveAtPly` agrees with
`formatNumberedMove` at every ply and that both 1-based conventions convert by
subtracting one.

**Still not converted, deliberately:**
`compact_tree_outline._formatMoveLabel` renders White spaced (`1. e4`) and
Black compact (`1...e5`) — the two branches disagree with each other. Picking
either changes what one of them looks like, and the widget has no test, so it
needs a look at the rendered outline rather than a guess.
`repertoire_service._formatNextSan` numbers only White moves and returns bare
SAN for Black: it appends to existing movetext where the number is implied, so
it is not a move label at all.

The remaining `~/ 2 + 1` hits are **span renderers** (`clickable_move_line`,
`tactics_training_panel`, `hoverable_move_chips`, `line_item_row`,
`draft_tree_view`) that emit widgets rather than a string, so they need the
numbering *rule*, not the serializer, and `best_effort_position`, which builds
a FEN's fullmove field.

## Extracted: `EnrichmentRunner`

`lib/services/generation/course/enrichment_runner.dart` — the four post-build
passes (refutations, engine tails, alternatives, master improvements) were the
same six steps four times over: check the config switch, build a prober, stop
if there is nothing to probe, warm the engine pool, probe while reporting
progress, record the count. Only two of the six differed.

The runner owns the shared five; each phase is now ~25 lines of what makes it
different. `GenerationSessionController` drops from 1525 to ~1430 lines and the
`StockfishPool` warm-up block goes from **five copies to one** — the fifth was
in the verification pass, which now shares it too.

The four `lastXCount` fields are gone. They were written as a side effect of
each phase and read ~150 lines later by the run-summary builder, so a new pass
could be added without its count ever being wired up. Recording the count is
now part of running the pass, and `countOf(EnrichmentPass)` is the only way to
read one; the public `lastRefutationCount` getters still work.

`EnrichmentPass` is an enum, not a string key. 14 tests pin the contract that
matters: a pass that is **switched off, has nothing to do, is cancelled, or
throws** all look identical to the caller — no findings, no engine started, no
count, and never an exception. A failing pass costs its own output and nothing
else; the export always goes ahead.

## `PgnViewerController`: three reset blocks became one

`loadFile`, `loadPgnContent` and `closeFile` each carried a hand-written block
of 15, 15 and 20 assignments that had to agree. Adding a field meant
remembering all three. They now share `_adoptCollection`, and the
perspective-detection block that `loadFile` and `loadPgnContent` held verbatim
is `_perspectiveFor`.

`closeFile` had been clearing `sliceProtagonist` and `protagonistFixedSide` by
hand; `_adoptCollection` with no entries nulls exactly those, so the special
case is gone. It passes a **mutable** empty list rather than `const []` —
`allGames` is assigned as given rather than copied, and sorting reorders these
lists in place. Two tests pin that, including one for the protagonist fields
that nothing covered before.

## Long methods split

`_exportSection` (**257 lines**, the worst method in the codebase) held five
unrelated domains in one list literal: coverage, chapter grouping, master
games, refutations, alternatives. Each is now its own builder, still composed
into one visible section because that is how the reader thinks of them.
`_moveChoiceSection` (152) split the same way into mode, setup moves, the eval
window, and relative-eval. The longest method in that file is now 99 lines.

## R2-R5 as originally found (all now fixed; see above)

Kept for the record — the reasoning that motivated each fix. "Suggested fix"
notes below describe what was subsequently done.

**R2. `FenMap.registerExpanded` seeds canonicals but not the transposition
equivalence lists, so resumed builds lose transposition-chain mass.**
`TreeBuildService.build` always constructs a fresh `FenMap()`; on resume only
`registerExpanded` runs, which calls `putCanonical` and skips childless nodes
entirely. Every transposition leaf registered in a previous session is absent
from `_equivalents`. Consequences: (a) `_registeredCanonicalOf` returns null
for those leaves, so a new arrival's reach stops at the stub instead of
forwarding into its canonical — the "chains stay consistent to any depth"
guarantee holds only within one session, and a canonical whose true reach now
clears `minProbability` is never re-queued; (b) the coverage sweep's
`getTranspositions` under-estimates `maxProb`, so a hole reachable mainly
through an old transposition arrival is deleted rather than answered.
*Suggested fix:* after `registerExpanded`, walk again and `addTransposition`
every childless node whose FEN already has a canonical — registering them adds
no mass, since arrival accumulation is only driven from
`_resolveTranspositionOrRegister`.

**R3. A transposition note can point at a line the export does not contain.**
`LineExtractor` emits a position's continuation only under the owning arrival
and gives every other arrival a `transposesInto` note naming the owner's move
order. But `LinePruner.prune` runs afterwards with `targetCount` /
`coverageTarget`, and with `coverageTarget < 1.0` the greedy is truncated to a
prefix. If the owner line falls outside that prefix, surviving lines read
"Transposes to 1. d4 ..." for a move order that is not in the PGN, and the
shared continuation is taught nowhere. Nothing pins the owner line in the
pruner's output.

**R4. Merged-line `probability` is inflated and its justifying comment is now
false.** The comment says "the build propagates the highest arrival", but
`addArrivalCumP` replaced max-propagation with *summing* every arrival's reach
into the canonical subtree. When the merging arrival is itself the canonical
node — it can be; ownership is decided by reach, not by
`cumulativeProbability` — the emitted `probability` is the sum over all move
orders rather than its own path's. A position reached canonically via a rare
order (0.001) and via a transposition leaf (0.20) is emitted with 0.201, which
then drives `LinePruner`'s coverage-mass accounting and `rankLinesByImportance`.
The sibling merge branch passes no `probability` at all and inherits
`leaf.cumulativeProbability`, so the two merge paths also disagree.

**R5. Ownership is decided across two independent traversals with different
cycle guards.** `_ownerDfs` and `_extractDfs` walk the same tree, but pass 2
cuts paths pass 1 explored. When the owner path is itself cut at an ancestor,
the continuation survives only because the other owner re-enters the same node
objects — with a *different* `visited` FEN-path set. If `isTranspositionCycle`
fires on that alternative route where it did not fire on the original, both
arrivals stop and the continuation is emitted nowhere, with no "Transposes to"
note either (merge requires `!cycle`). Silent coverage loss rather than a
visible error. *A post-extraction assertion that every `transposesInto` move
order matches an emitted line would catch this and R3 together.*

---

# Follow-up, 2026-08-23 — the repertoire builder

A focused pass over the repertoire builder (generation pipeline, config, form,
session controller, screen). Verified after every change: `dart format` clean,
`flutter analyze lib test` 0 errors / 0 warnings, **2793 tests pass**
(2730 before, +63 new).

## The bug this pass was for: a 14-field hole in the config contract

The audit counted `TreeBuildConfig`'s **five** in-class sites. It missed that a
knob does not reach a build through JSON — it reaches it through the form,
which adds **three more** hand-kept sites: a control in the state base, a line
in `_applyInitialConfig`, a line in `toConfig`. Nothing guarded those three.

`toConfig` constructed a **fresh** `TreeBuildConfig`, so:

- a field missing from `toConfig` reverted to its constructor default on every
  build started from the form;
- a field missing from `_applyInitialConfig` reverted the moment the form was
  reopened on a saved config, a preset, or `GenerationSessionController
  .lastConfig` (which `repertoire_generation_tab.dart:285` passes as
  `initialConfig` — the live path).

**Fourteen fields were in that state.** Six had no mention in
`lib/widgets/generation/` at all (`maxNodes`, `maiaMinProb`, `masterMinGames`,
`engineTailDepth`, `improvementMinGainCp`, `rootReplyExclude`); eight more were
published by `EvalSourcesSection` through getters that had **no matching
setter**, so the section could report its eval-source settings into every built
config but could never be told what they were (`enableLocalChessDb`,
`localChessDbPath`, `enableChessDbApi`, `chessDbApiDailyQuota`,
`chessDbApiConcurrency`, `enableExtEvalSubtreeSkip`, `minAcceptableEvalDepth`,
`batchEvalLookups`).

### Fixed by construction, not by listing

`toConfig` now builds on a stored `_seedConfig` with `copyWith`. Every field
with a control is passed explicitly and wins; every field without one is
*carried*. That inverts the failure mode: a knob added to `TreeBuildConfig` and
wired into the build but never given a widget is now preserved rather than
reset. `EvalSourcesSection.applyConfig` supplies the missing setter half, seeded
from the same post-frame callback the skeleton card already used (both are
`Offstage` children whose state does not exist during `initState`).

`rootReplyExclude` is the one field `toConfig` now clears **on purpose**:
`PlanRunner` sets it per build point and `NodeExpander` reads it only at ply 0,
so it describes one specific build root. Carrying a plan point's exclusions
into a hand-started build on a different root would narrow it silently.

### Guarded

`test/widgets/generation/generation_config_form_roundtrip_test.dart` — 13
tests. The lead test mutates every serialized field, drives it through a real
mounted form, and requires it back; `_knownLossy` documents each deliberate
transform with its reason (checkbox-quantised knobs, values owned by
`EvalDatabaseSettings`, the host-clamped thread count, the derived `best_first`,
the per-request `root_reply_exclude`, the JSON-blob skeleton plan). Each of
those transforms also gets its own positive test, so "lossy" never means
"unchecked".

**Both halves were verified to fail against the old code**, independently:
reverting the seed-based `copyWith` reports the five carried fields; reverting
`applyConfig` reports six eval-source fields.

### The blind spot that remains

The generic JSON round-trip test drives the *serialized map*, so a field
forgotten in `toJson` has no key to mutate and slips through every check — it
runs the build, never persists, and reverts on the next resume.
`tree_build_config_roundtrip_test.dart` now pins the exact serialized key set
so that omission fails loudly. Dart has no reflection, so closing it *by
construction* means codegen (`json_serializable`) — a real option, but a
dependency decision rather than a refactor. A field-descriptor table was
considered and rejected: Dart's named parameters mean it could only drive
`toJson`, leaving the constructor, `fromJson` and `copyWith` untouched while
adding a fourth parallel list.

## Breakups landed

- **`AdvancedSettingsDialog`** (`widgets/generation/advanced_settings_dialog
  .dart`) — 176 lines of dialog chrome out of `_GenerationConfigAdvanced`
  (940 → 764). It touched zero form state, so it is now a real widget taking
  `List<AdvancedSection>`, with 11 tests covering what could not be reached
  before: the 860px TOC breakpoint, that a refresh rebuilds *every* section
  (a knob in one card enables a field in another), that cards stay mounted so
  `Scrollable.ensureVisible` can reach an off-screen anchor, and that `show()`
  completes only on dismissal.
- **`RepertoireLineIds`** (`services/repertoire_line_ids.dart`) — the seven
  scattered id functions out of `RepertoireService` (1018 → 987), with 22
  tests. They had no service state and carried an invariant spanning them: the
  id the parser assigns and the id a file edit looks a game up by must be the
  same rule. The collision rule and its two appliers sat 400 lines apart.
  **Non-obvious rule preserved:** `forNewLine` tries the stable id first (it
  predicts what a reload will assign) while `resolveCollision` escalates
  straight to the hash — because a colliding id may be a *header* id, in which
  case the stable id was never tried and returning it would hand the line a
  different id than the one already saved against it. These ids key training
  progress; changing them is a data migration.
- **17 `progressX` pass-through getters** deleted from
  `GenerationSessionController` (1474 → ~1430). They forwarded to a field that
  was already public, so a new progress field was invisible to the jobs panel
  until someone added an eighteenth. 42 call sites now read `.progress.x`.
  Note `progressEtaSec` was the one whose name differed from its target
  (`etaDepthSec`).

## Deliberately not attempted, with reasons

- **`_RepertoirePersistence` → a real collaborator.** The clearest remaining
  instance of the fake-`part` violation: 20 abstract host accessors re-declared
  so a mixin can see private state. But its 336 lines make ~70 writes to host
  state, and the load path has exactly **one** staleness/race test. The right
  shape is a `RepertoireLoader` returning a `LoadedRepertoire` the controller
  applies — it needs characterisation tests for the `_loadGeneration` guard and
  `awaitLoaded()` first, and CLAUDE.md forbids running integration tests
  locally.
- **`tree_build_db_explorer` → a real `BuildAlgorithm`.** Still the right call
  (two entry points, `buildFromPgnFreqMap` vs `build`, dispatched by an `if` on
  `config.buildMode` in `_buildTreePhase:618`; the `maxNodes` cap is checked in
  both). Left alone this pass: the audit rates it high risk, and the working
  tree carries ~100 uncommitted files from other work.

  Worth recording: `SearchAlgorithm` (fast/pure) is **not** what dispatches —
  it is read once at `node_expander.dart:673`. `BuildMode` is. Two knobs read
  as "algorithm" and neither is a polymorphic seam.

## Working-tree caveat

This pass ran against a tree with ~100 uncommitted files (a tactics→features
migration and a new `engine_tournament` feature) and a **concurrent editor**:
files under `lib/features/tactics/` and `lib/features/games/` changed
timestamps mid-session, and one analyzer run went red on a half-written
`eval_series_annotator.dart` before going clean again. Nothing here was
committed. Changes were kept to files with no in-flight diff; in particular the
`RepertoireService` *parser* was left alone, because colour inference and
model-game detection are being actively edited there.

# Follow-up, 2026-08-24 — the repertoire load path

The `_RepertoirePersistence` item the 2026-08-23 pass deferred, taken with the
characterisation tests it was waiting on. Verified after every change:
`dart format` clean, `flutter analyze lib test` 0 errors / 0 warnings,
**2822 tests pass** (2796 before, +26 new).

## Characterisation first

`test/core/repertoire_load_test.dart` — 21 tests written and run **against the
unchanged code** before anything moved, on an in-memory `StorageService` whose
reads can be held open so two loads interleave deterministically. They pin what
the load path actually did, including the parts that read like accidents and
had to be preserved:

- a **missing file** clears the PGN, opening tree and lines but *keeps the
  `// Color:` / `// Root:` headers of the last load* — the missing-file branch
  never re-derives them;
- an **empty file** is not the same as a missing one: it yields an empty
  `OpeningTree`, not a null one;
- a **read failure** reports through `loadError`, and the next successful load
  clears it;
- `awaitLoaded()` resolves immediately when idle, is held for the duration of a
  load, and — the guard that matters — is **not** released by a *superseded*
  load, whose `finally` deliberately skips `_setLoading(false)`;
- the `// Color:` / `// Root:` upsert rules: replace in place, collapse
  duplicates, insert above the first `[Event ]`, prepend when there is none;
- `importPgnContent`'s separator arithmetic and its 0-return on a missing file.

Only then did anything move. All 21 still pass unchanged.

## Extracted: `RepertoireLoader`

`lib/core/repertoire_loader.dart` (259 lines) — `read()` (does the file exist,
and what is in it) plus `build()` (opening tree, headers, parsed lines), both
free of controller state. `build` returns a `LoadedRepertoire`; the controller
applies it or drops it whole.

That is not a tidiness argument. The derivation spans **two isolate hops** —
`OpeningTreeBuilder.buildTree` and the `compute` line parse — and the old code
wrote controller state as it went, so a repertoire switch during either hop let
the losing load land its half anyway:

- `_parseRepertoireLines` assigned `_repertoireLines = await compute(...)`
  **before** checking the generation. A superseded load overwrote the winner's
  lines with its own.
- Its `catch` and `_buildOpeningTree`'s `catch` were unguarded too, so a
  superseded load that *failed* cleared the winner's lines and opening tree.

Now there is exactly one write point, `_applyLoaded`, behind one epoch check.
Verified by reverting: moving `_applyLoaded` back above the guard fails
`the winner keeps its lines, tree and headers`.

**`headers` is nullable on purpose.** Null means "the PGN never parsed far
enough to determine them" — missing file, read failure, tree-build error — and
`_applyLoaded` then keeps the headers it has rather than resetting to a guess.
That reproduces the old behaviour exactly; a non-nullable field with defaults
would have silently flipped a Black repertoire to White on a failed reload.

**`restoreRepertoireFromPgn` now claims a generation** (it did not before), so
an undo cannot have a mid-flight load of a *different* repertoire land on top
of it. That introduces a hazard worth naming: claiming the epoch suppresses the
in-flight load's own `_setLoading(false)`, so the restore owes any
`awaitLoaded()` waiters theirs — otherwise the completers never fire and
`repertoire_screen`'s two `awaitLoaded()` call sites hang forever. The `finally`
that pays that debt has its own test, verified to fail without it.

## The `part` mixin is gone

`repertoire_controller_persistence.dart` is deleted, not shrunk. Its 20 abstract
host accessors — the re-declarations that existed only so a mixin could see the
class's private state — went with it; the 14 now-meaningless `@override`
annotations on the controller's own fields went too.

`RepertoireController` is now **955 lines** and says so. It was 780 + a 336-line
`part`, which is the point the audit made about parts hiding the real number.
The reduction is real (1116 → 955 for the same responsibilities, with ~200 lines
of derivation moved to a collaborator that has its own tests), but the class is
still the largest thing in `core/` and still the next candidate. What is left in
it is genuinely controller-shaped: cursor, tree, line list, file lifecycle.

## Not attempted, again

`tree_build_db_explorer` → a real `BuildAlgorithm`. Same reasons as the previous
pass, plus the same working-tree caveat below.

## Working-tree caveat

Another session was committing to `main` throughout this pass — `HEAD` moved from
`38f1995` to `951c6a5` (four commits) mid-run, and `lib/core/pgn_viewer_controller
.dart`, `lib/features/tactics/widgets/` and `lib/features/games/widgets/` all
changed under it. One of those commits swept an in-progress version of the new
test file into `HEAD`. Nothing here was committed, and no file with an in-flight
diff from that session was touched.
