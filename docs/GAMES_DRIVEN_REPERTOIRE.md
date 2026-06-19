# Games-Driven Repertoire — Design Note

**Status:** first implementation landed 2026-06-19 (overnight build). Core
engine + shared library + a working UI flow are committed, tested headlessly,
and compile. **Not yet GUI-smoke-tested** (no display on the build host) and
some of the design below is deliberately deferred — see "Implementation status"
at the bottom.

A plan to add the ability to **build and maintain a repertoire from the games you
actually play**, instead of only from explorer/theory. This is purely **additive**:
the existing explorer-based generation algorithms, extend/fill, PGN editing,
commenting, engine, audit, and coverage all stay exactly as they are. We add new
*faucets* into the repertoire, not a new plumbing system.

Companion docs: [`COMPONENT_MAP.md`](COMPONENT_MAP.md) (current implementation),
[`FUTURE_FEATURES.md`](FUTURE_FEATURES.md) (backlog), [`ALGORITHM.md`](ALGORITHM.md)
(generation pipeline).

---

## Motivation

Three pain points the user raised:

1. **No way to see where you deviate from your repertoire.** Given your games, you
   want to know where you (or your opponent) left the book.
2. **Repertoire is built from theory, not from what you play.** The useful starting
   point is "generate lines from the games I already play," not a course/book.
3. **Three separate downloaders.** Tactics, Position Analysis ("player weakness
   finder"), and now repertoire all download a player's games into their own
   on-disk stores, each with its own "last N / since date" controls. No sharing.

## Key insight: it's one loop, not three features

"Build a repertoire from my games" and "review where I deviate" are the **same
operation** — walk my games against my repertoire tree and collect the off-book
moves. The only difference is whether the tree starts **empty** (everything is new
→ this is the *bootstrap*) or **populated** (only deviations surface → this is the
*maintenance review*). Same engine, same UI surface.

The "deviation report" is not a separate screen — it is just the screen you look at
while accepting lines. Bootstrapping = accept a lot at once. Maintaining = accept a
few occasionally.

---

## Architecture (additive)

### 1. Shared Games library — *build this first*

One downloader, one on-disk store, one filter (`last N games` / `since date` /
time controls), read by **all three** features (tactics, weakness finder,
repertoire). Pure infrastructure — it does not know what a repertoire is.

- Today the download paths are split across `analysis_games_service.dart` (weakness
  finder, has its own store + chess.com archive walking + `monthsBack`/`maxGames`
  modes) and `tactics_import_service.dart` (tactics). These should converge on the
  shared library.
- The filter semantics ("N most recent OR from date till now", exclude bullet, time
  controls) should be defined **once** and reused.

### 2. Build-from-games generator → produces a **Draft**

A new generation *source* that sits alongside the existing explorer algorithms in
the same generation menu. Point it at games (from the shared library) and it
extracts the lines you actually play.

Output is a **Draft**: a normal repertoire-library entry flagged `draft`. It rides
the existing `repertoire_selection_screen` rails — no new storage concept. This is
why the user wanted a *separate reviewable PGN set* rather than auto-merge into the
active tree.

### 3. The Draft tab — contextual, not a new tab

The repertoire screen's tools area is a **2-tab toggle** today
(`_toolsTabController = TabController(length: 2)` in `repertoire_screen.dart`):
**PGN** (movetext editor) and the generation/**Lines** tab.

When a build-from-games session starts, the **Lines tab swaps its content to
"Draft"** — the prune/review surface. When you merge or discard, it reverts to
Lines. No new permanent tab, no new column, nothing added to the chrome. This is
how it "dominates the screen" without cluttering it.

The Draft surface is the **opening tree as both map and eraser**:

- Built from games via the existing `OpeningTree` / `OpeningTreeNode`
  (`lib/models/opening_tree.dart`) — the same model the weakness finder builds per
  side (`_whiteTree` / `_blackTree`). Nodes carry `gamesPlayed / wins / draws /
  winRate`.
- Rendered with the existing `opening_tree_widget.dart` +
  `lib/widgets/opening_tree/`, **coverage-annotated** via the existing
  `coverage_annotation.dart` / `CoverageController`:
  - green — already in your repertoire
  - your off-book moves — drift from prep / new ideas
  - opponent off-book moves — gaps you have no answer to
  - (the coverage annotator already does "in repertoire vs not" — this *is* the
    deviation highlight, already built)
- **Prune** (the main NEW interaction): collapse onto a node, discard → the whole
  subtree of games beneath it vanishes from the draft. "I don't play the French" →
  discard the `1.e4 e6` node. Plus filters: min games, win-rate, depth.
- **Side-aware**: the diff is always in the context of one side's repertoire. For
  the White repertoire it walks games where you had White; "your moves" = White's
  moves; "opponent off-book" = a Black reply you have no answer to.

### 4. Everything else works on the Draft for free

Because a draft **is** a repertoire, the full editing suite applies with no new
widgets:

- **PGN edit / comment** → the PGN tab, unchanged.
- **Engine** → the `EditContextZone` engine panel (already a toggle-chip panel).
- **Audit** → existing `AuditSessionController` + findings bottom-pane flags
  missing/weak moves in the lines you kept.
- **Coverage** → existing `CoverageController` annotation.

### 5. Merge with conflict-flagging

Merge = **union the draft tree into the target tree**:

- Walk the draft, `addChild` each move onto the target
  (`MoveTree.addChild` returns whether it landed as mainline). Identical prefixes
  dedup automatically; a divergent move lands as a new **sibling**.
- **Conflict** = any node that gained a second child during the merge → tag it.
- **Resolve** = the user picks which move is mainline vs sideline using the existing
  `MoveTree.promoteVariation` / `RepertoireController.promoteVariation` gesture
  (audit + coverage help judge which is better). First child = mainline by
  convention; both moves live in one line until resolved.

No new tree surgery required.

### 6. Extend (later) — a second faucet, same pipeline

"Fill / extend from explorer theory at a chosen position" is a **different source,
same plumbing**: it pours into the same Draft → review (prune/audit/edit) → merge
pipeline. Once the Draft surface and merge step exist, extend is cheap to add and
adds no new UI surface.

---

## Net new surface

- **Infra:** shared Games library (download + store + filter).
- **UI:** one generation-menu item ("Build from games") + one contextual tab-state
  (Lines → Draft) + the prune-subtree gesture + tree→PGN materialization.
- Everything else (download archive walking, OpeningTree build, tree widget,
  coverage annotation, PGN/comment/engine/audit editing, addChild/promoteVariation
  merge) is **reuse**.

## Suggested sequencing

1. **Shared Games library** (foundation; migrate tactics + weakness finder + repertoire onto it).
2. **Build-from-games → Draft** (the new generation source + Draft library entry).
3. **Draft tab** (contextual Lines→Draft swap; coverage-annotated opening tree; prune gesture; tree→PGN).
4. **Merge with conflict-flagging** (union + tag + promoteVariation).
5. **Extend** faucet (later).

## Open questions / deferred

- Exact prune-filter set (min games / win-rate / depth) and defaults.
- Draft materialization granularity (whole tree vs per-line accept).
- How drafts are labeled/listed in `repertoire_selection_screen` and cleaned up
  after merge.

---

## Implementation status (2026-06-19)

### Built, tested headlessly, and compiling
- **Core engine** `lib/services/games_repertoire/`:
  - `repertoire_diff.dart` — classify games tree vs repertoire per side.
  - `games_draft.dart` — GamesDraft: prune subtree, filters, materialize→MoveTree.
  - `repertoire_merge.dart` — union draft into target, flag my-side conflicts.
  - 8 unit tests (`test/services/games_repertoire/`), all green.
- **Shared games library** `lib/services/games_library/`:
  - `game_filter.dart` — GameRecord parse, speed classification, GameSelection
    (last-N / since / time-controls), de-dup. 5 unit tests, green.
  - `games_library_service.dart` — per-(platform,username) cache + injected
    fetchers (Chess.com via existing AnalysisGamesService; Lichess via games
    export API).
- **UI** `lib/widgets/games_repertoire/`:
  - `draft_tree_view.dart` — coverage-coloured prunable tree + legend.
  - `merge_conflict_sheet.dart` — pick mainline/sideline at each conflict.
  - `build_from_games_dialog.dart` — full flow, launched from a new toolbar
    button (`_buildFromGames`) in `repertoire_screen.dart`.
  - `RepertoireController.mergeDraft` is the merge entry point.
- Full app builds (`flutter build linux --debug`); full suite 492 tests pass;
  `dart analyze` clean on all new/changed files.

### NOT done / deviations from the design above (deliberate, blind-build risk)
1. ~~Delivered as a full-screen dialog~~ **DONE: now the inline Lines→Draft tab.**
   A small source-form modal (`games_source_form.dart`) starts the session; the
   review/prune/merge surface (`draft_review_pane.dart`) renders inline in the
   second tools tab, which relabels "Lines"→"Draft" while active. Driven by
   `_activeDraft`/`_buildingDraft` in `repertoire_screen.dart`. Widget tests in
   `test/widgets/games_repertoire_widgets_test.dart` verify prune + the conflict
   flow headlessly.
2. ~~Merges straight into the active repertoire~~ **DONE: drafts can also be
   saved.** The inline review pane now has a "Save" button beside "Merge" that
   writes the draft as a re-openable repertoire-library entry
   (`draft_repertoire_writer.dart`, round-trip tested through
   `RepertoireService.parseRepertoirePgn`). Merge-after-review is still the fast
   path; Save is the "stash for later" path.
3. **Shared library is only used by the new flow.** Tactics + weakness-finder
   still use their own downloaders; migrating them onto `GamesLibraryService` is
   the remaining half of "download once, share across 3 features." (Deferred —
   touches two unrelated, working features; do with the app running.)
4. ~~Lichess fetcher unverified~~ **DONE: both fetchers verified against live
   APIs** via `tools/verify_games_fetch.dart` — Chess.com (hikaru, 434 games)
   and Lichess (DrNykterstein, 20 games) parse, classify speeds, parse dates,
   and filter correctly. **Audit/engine/comment-on-draft** and the **Extend
   faucet** remain unwired (deferred enhancements, not blockers).

### Suggested next session (needs the app running)
- Smoke-test the flow end-to-end (real download, tree render, prune, merge,
  conflict resolution) and fix UX papercuts.
- Promote the dialog into the contextual Lines→Draft tab.
- Persist drafts as flagged library entries; point audit/engine at them.
- Migrate tactics + weakness-finder onto GamesLibraryService.
