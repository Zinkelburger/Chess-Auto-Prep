# Component Map

**Source of truth for what is currently implemented** in the Chess Auto Prep Flutter/Dart app. Use this document to audit behavior, trace data flows, and plan fixes.

| Document | Purpose |
|----------|---------|
| **This file** | Current implementation — screens, services, widgets, tests |
| [`FUTURE_FEATURES.md`](FUTURE_FEATURES.md) | Backlog only — not yet built or incomplete |
| [`ALGORITHM.md`](ALGORITHM.md) | Flutter expectimax / tree-generation pipeline |
| [`../tree_builder/ALGORITHM.md`](../tree_builder/ALGORITHM.md) | C `tree_builder` CLI pipeline (incl. db-explorer) |
| [`tree-display-architecture.md`](tree-display-architecture.md) | Eval-tree graph performance principles |
| [`OPPONENT_PREP.md`](OPPONENT_PREP.md) | MCP server: tournament identity/pairing **and** PGN opening-tree query |

Last reviewed against `lib/` and `tree_builder/` (June 2026, post 7-phase remediation). When you change code, update the matching section here.

---

## Table of contents

1. [Architecture overview](#architecture-overview)
2. [Entry points & navigation](#entry-points--navigation)
3. [Major data flows](#major-data-flows)
4. [Directory reference](#directory-reference)
5. [Test coverage map](#test-coverage-map)
6. [External & non-Flutter components](#external--non-flutter-components)
7. [Audit gaps](#audit-gaps)

---

## Architecture overview

| Layer | Role | Key packages |
|-------|------|--------------|
| **Screens** | Top-level routes / modes | `screens/` |
| **Widgets** | UI composition | `widgets/`, `features/*/widgets/` |
| **Features** | Domain-vertical modules (audit, browse, traps, coverage, eval tree) | `features/` |
| **Core** | Session controllers shared across repertoire UI | `core/` |
| **Services** | Business logic, engines, I/O | `services/` |
| **Models** | Immutable / serializable data | `models/` |
| **Constants / utils / theme** | Shared helpers | `constants/`, `utils/`, `theme/` |

**State management:** Provider (`ChangeNotifier`) — primarily `AppState`, `RepertoireController`, domain session controllers (`GenerationSessionController`, `AuditSessionController`, `CoverageController`), singletons (`EngineSettings`, `EngineLifecycle`, `EvalDatabaseSettings`).

**June 2026 remediation (7-phase refactor):** Repertoire metadata is typed (`RepertoireMetadata` replaces `Map<String, dynamic>`). `AppState` no longer tracks a global saved-games list. `RepertoireController` navigation funnels through `playMove` / `playMoveAtTreePath` (removed `userPlayedMove`, `_isInternalUpdate`). `GenerationSessionController.dispose()` stops an in-flight build. Lines browser uses typed `LineSortBy` / `LineMetricsFilter`, 300 ms search debounce, and lazy grouped `ListView.builder` rows. PGN editor memoizes move widgets and delegates clipboard/persist I/O to parent callbacks. Coherence FP-Growth runs in `Isolate.run`. `EngineLifecycle.enterGeneration` / `exitGeneration` are serialized via `_serialExec`. Startup failures surface via `runZonedGuarded` → `StartupErrorApp`; repertoire load failures via `RepertoireController.loadError`. Deleted unused `ease_calculator.dart`. New extractions: `GenerationConfigForm`, `RepertoireShortcuts`.

**Repertoire navigation model:** `RepertoireController` owns a `MoveTree` (editable PGN tree) and a `TreePath` cursor. All navigation goes through `controller.jump(path)`. `controller.awaitLoaded()` returns a Future that completes when the current load finishes (Completer-based); used by `repertoire_screen` for deep-link line navigation and generation seeding instead of listener polling. The PGN editor (`InteractivePgnEditor`) is a pure view that receives `tree` + `currentPath` as props and fires `onJump` / `onCommentChanged` / `onDelete` / `onPromote` / `onMakeMainLine` callbacks. Clipboard writes wired in `EditMainZone` via `onCopyToClipboard`; debounced line saves use `onAutoSave` (falls back to `onLineEdited`) and optional `onDirty`. The "Save to Repertoire" button and `onLineSaved`/`onPersistNewLine` callbacks have been removed — lines are auto-saved.

**PGN context menu (right-click):** Uses Flutter's built-in `showMenu` API (Overlay-based, avoids Stack/Positioned layout issues). Menu items: Add Comment (focuses comment TextField), Promote Variation (non-mainline only), Make Main Line (recursive promote to root, non-mainline only), Duplicate Line (copies full line to clipboard), Copy PGN from Here, View in Lines (existing-line only; switches to Lines tab), Delete from Here. When the context menu is open, all moves from root to the right-clicked position are highlighted (blueGrey background). Delete from Here pushes an undo snapshot via `RepertoireWriter.pushUndo()`, making it reversible with Ctrl+Z.

**Line deletion:** `RepertoireService.deleteLine(filePath, lineId)` removes a game from the PGN file on disk. `RepertoireController.deleteLine(line)` calls the service and reloads. `LineItemRow` shows a trash icon with a confirmation dialog; callbacks thread through `LinesListPanel` → `RepertoireLinesBrowser` → `repertoire_screen`.

**Chess logic:** `dartchess` for rules/FEN; `flutter_chess_board` for display.

### Architecture invariants (do not regress)

These rules were added after the generation/traps remediation
(`docs/REFACTOR_PLAN.md`). Violating them reintroduces the "lines don't show"
and "infinite traps" class of bugs.

1. **One owner of the generated tree.** `GenerationSessionController` holds a
   single `GeneratedRepertoire` bundle (`lib/core/generated_repertoire.dart`)
   containing the tree, `FenMap`, eval-tree snapshot, and trap index. All of
   these are derived **once**, in `GeneratedRepertoire.fromTree`, the moment a
   tree is built — never inside a widget `initState`/`didUpdateWidget`.
2. **One definition of position identity.** Transposition keys and trap lookup
   both use `canonicalizeFen4` (4-field FEN). `TrapExtractor` dedups on it and
   `TrapIndexService` keys on it; they must stay in agreement.
3. **Every transposition-following traversal is cycle-guarded.** Any DFS that
   calls `resolveTransposition` / `getCanonical` and recurses into the resolved
   subtree must carry a path-scoped `visited` set keyed on `canonicalizeFen4`
   (see `LineExtractor`, `RepertoireSelector`). Iterative walks must be bounded
   by `maxPlies`/`maxPly`.

---

## Entry points & navigation

### Application bootstrap

```
main.dart
  ├─ EngineSettings.loadFromPrefs()
  ├─ EvalDatabaseSettings.instance.load()
  ├─ EvalCache.instance.init()  // SQLite eval + Maia cache ready for interactive writes
  ├─ EngineLifecycle.loadPersistedState()  // marks engine idle (no process spawn); workers created lazily on first eval
  ├─ DefaultPgnService.ensureExtracted()
  └─ ChessAutoPrepApp → MainScreen  (startup wrapped in `runZonedGuarded`; failures show [StartupErrorApp])
```

| File | Purpose |
|------|---------|
| `lib/main.dart` | `WidgetsFlutterBinding`, `FlutterError.onError`, `runZonedGuarded` startup, window manager, settings init, `EvalCache.instance.init()`, `MaterialApp` dark theme, `AppState` provider (`loadUsernames` on create) |
| `lib/core/app_state.dart` | Global mode enum, usernames, board position, builder↔trainer pending path/line handoff, `pendingGenerationPgnPaths` for PGN-viewer→builder seeding |
| `lib/screens/main_screen.dart` | `IndexedStack` of mode views; engine suspend/resume on leaving/entering interactive-engine modes and on `paused`/`hidden`/`detached` |

### App modes (`AppMode`)

| Mode | Screen | Primary use |
|------|--------|-------------|
| `tactics` | Embedded `_TacticsModeView` | Tactics from user's own games (Stockfish analysis + Maia line extension) |
| `positionAnalysis` | `AnalysisScreen` | Weak positions from user games |
| `repertoire` | `RepertoireScreen` | Opening repertoire builder |
| `repertoireTrainer` | `RepertoireTrainingScreen` | Spaced repetition training |
| `pgnViewer` | `PgnViewerScreen` | Standalone game PGN + inline engine |
| `study` | `StudyScreen` | Multi-chapter studies |
| `engineTournament` | `EngineTournamentScreen` | Engine-vs-engine matches, crosstable, per-game PGN |

Mode switcher: `widgets/app_mode_switcher.dart` — the app-bar *title* (`Tactics ▾`) opens a grouped, text-only menu (Train / Build / Analyse / Lab, order in `kAppModeGroups`); Ctrl/Cmd+1…7 follow the same order and are bound once in `MainScreen`.

#### App bar conventions (unified June 2026)

Every mode screen uses `Scaffold` + `AppBar` with consistent conventions:

- **`titleSpacing: 16`** on every `AppBar`.
- **`AppModeSwitcher` is the title** (leftmost); the app bar's right side holds one primary action, the overflow ⋮, and nothing else.
- **Toolbar buttons collapse** from text+icon to icon-only below `kToolbarCompactBreakpoint` (900 px).
- **Layout body splits** at `kCompactBreakpoint` (960 px) from side-by-side to stacked.
- **Action padding** is `right: 8` for all toolbar action widgets.
- **Shared constants** live in `constants/ui_breakpoints.dart`.

### Repertoire screen layout (right pane + bottom pane, redesigned June 2026)

Design principles (Chessable-style, Aug 2026): **what the repertoire contains** on the left (the outline: folders → chapters → lines, a real file structure), **the position** in the middle (board + PGN editor; no eval bar by design), **evidence about the position** on the right (Analysis panel: Engine | Database | Tree). **Bottom pane** = job output (Findings, Jobs/config) — collapsed by default. Generation and audit config are inline in the Jobs tab; the outline's chapter menu ("Generate lines into this chapter…") switches to that chapter, puts the board on the chapter's shared root, and opens it.

```
RepertoireScreen (composition root — wires controllers to widgets)
  ├─ RepertoireController (MoveTree + TreePath cursor, opening tree, lines)
  ├─ RepertoireOutlineController (features/repertoire/controllers) — the repertoire folder as
  │     OutlineFolder/OutlineChapter/OutlineLine; every edit hits disk then rebuilds
  ├─ GenerationSessionController (TreeBuildService, CoherenceService, tree/config/fenMap, job)
  ├─ AuditSessionController (RepertoireAuditService, result/liveFindings/progress, persistence, job)
  ├─ CoverageController (CoverageResult, progress)
  ├─ BoardPreviewController (hover preview FEN)
  ├─ JobManager (background generation/audit tracking)
  ├─ TrapIndexService
  │
  ├─ Wide (≥ kCompactBreakpoint):
  │     Row: Outline column (resizable, collapsible → "Chapters" strip, shortcut L)
  │          | Board (square, annotated)
  │          | PGN editor (PgnWithAnalysisPane) + NavControls
  │          | Analysis panel (resizable, collapsible → "Analysis" strip)
  │              TabBar: Engine | Database | Tree
  │                Engine: InlineEngineBar (E) over InlineExpectimaxBar (X)
  │                Database: RepertoireDatabasePane (live Lichess explorer)
  │                Tree: RepertoireTreePane (OpeningTreeWidget, optional explorer split)
  │       Outline column content = RepertoireOutlinePanel (default)
  │          | line-metrics view (old RepertoireLinesBrowser: coverage/ease/coherence/traps, via
  │            the header's metrics button, "Back to chapters" returns)
  │          | BuildSessionPane / DraftReviewPane while a session or draft is adding lines
  │       BottomPane (collapsed by default, full width): Findings | Jobs
  │
  ├─ Compact (<960px):
  │     Column: Board (flex 4) | ToolsColumn (flex 5): PGN (with engine bars) | Chapters | Tree
  │
  ├─ Inline config (in Jobs tab): Add lines ▾ → Generate… / outline chapter menu → RepertoireGenerationTab;
  │     Audit button / chapter menu → AuditConfigPanel
  ├─ RepertoireStatusBar (clickable badges → toggle bottom pane tabs)
  └─ optional TrapWalkthrough overlay
```

**Outline panel** (`features/repertoire/widgets/repertoire_outline_panel.dart`): header (repertoire name, "N chapters · M lines", metrics button, collapse, `+` menu: New chapter… / New folder…), search field, "At this position" filter chip; tree rows for folders (nestable, expand/collapse), chapters (active one highlighted; unfold to show lines; course-composer `[White]` sections shown as uppercase section headers), lines (name + move preview + ply count; model games italic). **Right-click / long-press menus**: folder → New chapter here…, New folder here…, Rename…, Move to…, Delete folder…; chapter → Open, Generate lines into this chapter…, Audit this chapter, Train this chapter, Rename…, Move to folder…, New chapter next to this…, Delete chapter…; line → Load on the board, Train this line, Rename…, Move to chapter…, Delete line…. **Drag & drop**: lines onto chapters (moves the game between files), chapters and folders onto folders (a folder cannot be dropped into itself). Names are validated once (`RepertoireOutlineService.validateName`). Line edits address games by file index (`RepertoireLine.gameIndex`) because the move-based line id truncates and collides for lines sharing a long prefix.

**Planner (`lib/features/planner/`, "Plan a build…")**: full-width planning mode (`PlanBuildScreen`, pushed as a route) that turns a few answers into chapters and then generates them all. `services/eco_trie.dart` lays the ECO book over itself as a SAN trie; `tabiyaScore = entriesBelow × distinctChildren` says whether a position is a fork worth asking about. `controllers/plan_controller.dart` walks from a start position: at *our-move* forks it asks (candidates from `services/plan_data_source.dart`: ECO names, **Maia** probability at the user's Elo (the probability of record — the Lichess explorer is never queried for probabilities, it is too slow and rate-limited), ChessDB eval; overlaid with `services/plan_knowledge.dart`: what the user's chapters already play — taken silently when unique — and what they play in their own Player Analysis games — pre-ticked, on by default); at *their-move* tabiyas it splits replies ≥ `chapterShare` into sibling chapters and cuts a "sidelines" chapter at the same root that excludes them (`TreeBuildConfig.rootReplyExclude`, honored in `node_expander.addOpponentChildren` at ply 0) so no two chapters build the same lines; out of book / `maxPly` it cuts a chapter. Flat chapters only (no sub-folders); duplicate names get the distinguishing move appended ("Queen's Gambit Declined · 4.Bg5"). Screen columns: plan so far | board (interactive in Start; clicking a candidate previews it) with Engine/Database tabs under it | question / coverage / review card. Review embeds `GenerationConfigForm` for engine settings; commit returns `PlanBuildResult` to the repertoire screen, whose `PlanRunner` (`controllers/plan_runner.dart`) creates the chapter files (via `RepertoireOutlineService`) then runs one `GenerationRequest` per chapter through `GenerationSessionController`, badging the outline ("queued", "building…").

**Toolbar**: title/breadcrumb (repertoire ▸ chapter switcher) · `Add lines ▾` (Generate with engine…, Build by playing, From my games…, Import PGN file…, Paste PGN…) · `Audit` · Train · ⋮.

**Key files:**
- `lib/core/generation_session_controller.dart` — owns the run and the generated-tree bundle; pause/resume/cancel survive dialog disposal; `dispose()` stops build. Progress UI state lives on `GenerationProgress`; mid-run line export lives on `SnapshotExporter`.
- `lib/core/audit_session_controller.dart` — owns `RepertoireAuditService` + audit state + persistence; pause/resume/cancel from any widget
- `lib/core/coverage_controller.dart` — owns coverage result + progress state
- `lib/widgets/layout/bottom_pane.dart` — resizable, collapsible, tabbed bottom pane (Findings/Jobs — the Lines list lives only in the side panel)
- `lib/widgets/engine/inline_expectimax_bar.dart` — compact toggleable expectimax PV display
- `lib/widgets/generation_config_dialog.dart` — legacy modal dialog (still importable but generation config now shows inline in Jobs tab)
- `lib/features/audit/widgets/audit_config_dialog.dart` — legacy modal dialog (audit config now shows inline in Jobs tab)
- `lib/features/audit/widgets/audit_findings_panel.dart` — findings list with category filter chips, auto-scaled to ~20 findings, bulk dismiss, keyboard navigation, and interrupted-audit resume banner; dismiss context menus use `showAnchorMenu` (shared with holes/tricks reports)
- `lib/features/audit/services/audit_persistence.dart` — centralized save/load for audit snapshots (result + config + resume state)
- `lib/widgets/layout/jobs_panel.dart` — jobs panel: one compact card per active generation/audit job (phase, live stats, threads/hash, progress bar, controls); completed jobs as simple tiles; no duplicate status banners
- `lib/widgets/repertoire_lines_browser.dart` — line search/filter/group browser; now the outline column's *metrics view*, not the default
- `lib/widgets/layout/board_zone.dart` — board wrapper, passes annotations
- `lib/widgets/chess_board_widget.dart` — board + annotation overlay (arrows, circles, labels)
- `lib/services/jobs/repertoire_job.dart` — background job manager; `RepertoireJob` includes `configSnapshot` (serialized `AuditConfig.toMap()`) for audit jobs

**Bottom pane (VS Code-style):** Collapsed by default (zero height). Auto-opens to Findings tab when audit starts, Jobs tab when generation starts. Tabs show badge counts. Resizable by dragging the top edge (min 120px, max 60% of screen height). Collapse via close button, `Escape` key, or double-click the drag handle. The `onClose` callback clears inline config flags so that reopening the pane does not show stale config forms. `Escape` both collapses the pane and resets inline gen/audit config state.

**Findings tab UX:** Category filter chips (Blunders/Inaccuracies/Missing/Weak/Dead Ends) with counts — multi-select toggles. Findings are sorted by reach probability (cumulative likelihood of the line occurring). The visible count is capped (default 20) and user-configurable via an inline text field in the status row; as findings are dismissed, lower-probability ones surface automatically. Each finding tile shows its reach probability right-aligned (e.g. "12.3%"). When capped, the status row reads "Top [N] of M · X% – Y% reach". Bulk dismiss via right-click context menu: dismiss similar, dismiss at depth, dismiss all of type. Keyboard: ↓/↑ to cycle findings (board navigates within full repertoire tree), D to dismiss current — routed through `RepertoireShortcuts` at the screen level (active when the Findings tab is open in the bottom pane), delegating to `AuditFindingsPanelState.selectNext()` / `selectPrevious()` / `dismissSelected()` via `GlobalKey`; ↑/↓ also work when the findings panel has focus. Selected finding is highlighted. Timestamp shows when saved results were generated.

**Line metrics view (outline column):** The old `RepertoireLinesBrowser` (search/filter/sort, coverage/ease/coherence columns, gap buttons) plus the Lines/Traps segmented toggle, reached from the outline header's metrics button; "Back to chapters" returns to the outline. The Traps view shows `TrapsBrowser` (default sort: Eval Drop, also Most Common/Trap%/Surplus) with mini board preview, per-reply stats with classification badges, and expandable detail cards. `BoardPreviewController` is threaded through; a `FloatingBoardPreview` overlay is mounted in the view's `Stack`.

**Tree tab (analysis panel):** The Tree tab shows `OpeningTreeWidget`, an interactive opening tree explorer built from the repertoire's PGN lines via the same `OpeningTreeBuilder` as the PGN viewer (`T`). Course-style `*` games fold RAVs in; frequency shows as **lines** when there is no W/D/L. The cursor is FEN-keyed: a different move order that reaches a known position still shows that position's continuations, and a position the PGN never reached still lists legal moves that transpose into book (marked `≈`). Navigates with back/forward and syncs with the board via `RepertoireController.userSelectedTreeMove` (plays from the board cursor so the user's move order is kept). When no opening tree is available (empty repertoire), shows an empty-state message.


**"Generate from here" button:** In the nav controls bar, a `+` icon button opens the generation dialog pre-seeded with the current position FEN.

**Board annotations:** `BoardAnnotation` model with `AnnotationBrush` (green/red/blue/yellow/purple). `_AnnotationPainter` renders arrows (shaft + arrowhead) and circles on a `CustomPaint` overlay above pieces.

**Keyboard shortcuts:** Handled by `RepertoireShortcuts` (letter keys suppressed while a text field has focus — see `lib/utils/keyboard_shortcut_utils.dart`):
- `E` — toggle engine (Engine tab of the analysis panel)
- `X` — toggle expectimax
- `L` — wide: collapse/expand the outline column; compact: PGN ↔ Chapters tab
- `F` — flip board
- `T` — toggle trap walkthrough at a trap position
- `S`/`↓`, `P`/`↑` — next/prev finding (Findings tab open) or trap-tour stop
- `D` — dismiss current finding (when Findings tab is open in bottom pane)
- `Ctrl/Cmd+Z` — undo last repertoire add
- `Ctrl/Cmd+Shift+V` — paste FEN from clipboard
- `Escape` — collapse bottom pane + clear inline config flags
- `←` / `→` — navigate moves; `Shift+←` / `Shift+→` — previous/next trap

Digit shortcuts (bottom-pane tab toggles `1`/`2`/`3`, edit-mode NAG `1`–`6`, star ratings, etc.) are **not** bound.

Breakpoints: `constants/ui_breakpoints.dart` (`kCompactBreakpoint=960`, `kWideBreakpoint=1100`).

Overflow menu (⋮): Import PGN (shortcut I), Switch color, Settings → `screens/settings_screen.dart`.

---

## Major data flows

### Repertoire load & edit

```
RepertoireListBody (embedded inline or in RepertoireSelectionScreen)
  → StorageService.listRepertoireFiles() → List<RepertoireMetadata>
  → user picks RepertoireMetadata → onSelected callback → setRepertoire / loadRepertoire
  → RepertoireController (MoveTree + TreePath, OpeningTree, RepertoireLine list; loadError on failure)
  → InteractivePgnEditor (pure view: tree + path props, action callbacks; memoized move widgets; context-menu path highlighting)
  → EditMainZone (onAutoSave, onDirty, onCopyToClipboard, onViewInLines adapters)
  → OpeningTreeWidget (unchanged — read-only statistics tree)
  → disk writes via RepertoireService / RepertoireWriter (browse adds; line edits use _findGameIndexByLineId + _reassembleDocument)
```

### Native engines (Stockfish + Maia)

```
Stockfish:
  tools/fetch_assets.py | CMake/Xcode (if .gz missing) | in-app download
  → assets/executables/*.gz  (gitignored; pubspec bundles the directory)
  → StockfishBundle.ensureExecutable
      → gunzip (or unpack upstream tar/zip) into AppPaths.supportDirectory()

Maia:
  assets/maia3_simplified.onnx + vocab JSON  (tracked in git)
  onnxruntime plugin  (.so / .dll / universal .dylib, auto-copied into the bundle)
  → MaiaService.initialize → OrtSession
```

macOS GitHub Releases are two zips (`macos-arm64` / `macos-x86_64`). Each has the
matching Stockfish; `ditto --arch` also thins the universal ONNX Runtime dylib.
Release packaging uses `zip -ry` so framework `Versions/Current` symlinks are
stored as links (plain `zip -r` packed Stockfish/Maia/Flutter three times).

### Tree generation (expectimax pipeline)

```
GenerationSessionController (owns TreeBuildService + CoherenceService)
  ← RepertoireGenerationTab reports lifecycle (markGenerating, onTreeBuilt, onTreeReset)
  ← Screen/JobsPanel call pauseBuild/resumeBuild/cancelBuild/finishNow directly
  ← Config shown inline in Jobs tab (no dialog to pop); controller tracks progress stats

RepertoireGenerationTab (config UI + build orchestration)
  → cancelGeneration() → _savePartialTree() before cleanup (partial trees survive cancel)
  → EngineLifecycle.enterGeneration(threads)
  → controller.buildService.build(TreeBuildConfig)    [Phase 1 BFS — Stockfish/Maia modes]
    OR
  → controller.buildService.buildFromPgnFreqMap(…)    [Phase 1 DB Explorer mode]
      → parsePgnFiles (isolate) → PgnFreqMap
      → BFS expand from freq map
      → _enrichEvals (cache → external chain → Stockfish batch)
  → calculateTreeEase + EcaCalculator                 [Phase 2]
  → calculateMyEase                                     [myEase on our moves]
  → RepertoireSelector + LineExtractor
  → TrapExtractor → *_traps.json
  → tree.json persisted beside repertoire PGN
  → EngineLifecycle.exitGeneration()
```

**Build modes** (enum `BuildMode` in `generation_config.dart`, UI labels in parentheses):
- `stockfishExpectimax` ("Stockfish Expectimax (recommended)") — default; Stockfish MultiPV + Maia opponent, traps auto-detected
- `maiaDbExplore` ("DB Win Rate Only (no Stockfish)") — Maia moves, DB evals only, no engine at build time
- `dbExplorer` ("From Added PGN Files") — requires PGN files added via `PgnSourcesPanel` (file picker or paste); does **not** use lines already in the repertoire PGN; parsing → frequency map → BFS tree → eval enrichment
- `chessDbBook` ("ChessDB mainline book") — one move per position, whichever ChessDB ranks best (exact ties to the more-played master move); opponent replies from master practice only, unsmoothed; off practice (or past `maxPly`) the line continues as a single ChessDB mainline to `bookTailMaxPly`; a line ends where ChessDB's knowledge ends unless `bookEngineFallback` puts the engine underneath as a floor (off by default — it is what makes the mode need Stockfish at all, and it is slow); Phase 2.5 never runs. Needs the local TerarkDB dump or the ChessDB API. See the mode's section in `lib/services/generation/README.md`

**Generation config, two layers.** The always-visible form is three titled blocks — Opponent (rating), What to build (build source, novelties, traps-only, PGN sources), Search (Fast/Pure plus engine depth, max line length, candidate moves, time budget) — then the collapsed skeleton-plan and eval-database expanders, a saved-preset menu, and a live one-line summary of the whole config.

Everything else is in the **Advanced** dialog (`AdvancedSettingsDialog`), ten focused sections in build order: Opponent model · Move choice · Search tuning · Master games · ChessDB book · Verification · Coverage & line order · Chapters · Explanatory variations · PGN source filters. Both layers edit the same controllers, so they cannot disagree.

A section whose knobs cannot apply to the current build source renders one sentence saying why instead of a card of greyed-out controls (`AdvancedSection.unavailable`); it keeps its table-of-contents entry so it stays findable. ChessDB book, Verification and PGN source filters use this. The main form's `PgnSourcesPanel` is simply absent unless the source is My PGN files — the attached files live in `PgnSourcesController`, so they survive a round trip through another build source.

**Where the form's sub-editor state lives.** The three sub-editors are views over controllers `GenerationConfigFormState` owns — `EvalSourcesController`, `SkeletonPlanController`, `PgnSourcesController` — not `GlobalKey`-addressed widget state. Each of their widgets sits behind an expander or a build-source switch, so none is guaranteed to be mounted when the form seeds it (`_applyInitialConfig`) or reads it back (`toConfig`); owning the state lets the widgets be built conditionally and removes the post-frame seeding hop. `EvalSourcesController` pairs `applyConfig` with `applyTo`, the two halves of the config round trip, in one file.

"Finish Now" stops Phase 1 BFS and proceeds to Phase 2 on the partial tree; discarding an unfinished build asks for confirmation first.

See `docs/ALGORITHM.md` for algorithm detail.

### Browse → one-click add

```
BrowsePanel
  → CandidateService.getCandidates(fen, tree + BuildTree)  // Lichess Explorer mothballed
       → inRepertoire via OpeningTree.hasMoveOnPath(pathFromRoot, san)
  → tap in repertoire → RepertoireController.playMove(san) (jump to existing child)
  → tap unexplored → RepertoireWriter.addMoveAtPosition()
       → RepertoireService.appendMoveAtPath (atomic PGN)
       → RepertoireController.appendMoveToExistingLine
       → playMove(san)
  → Ctrl+Z → RepertoireWriter.undo()
```

### Coverage & suggestions

```
CoverageCalculatorWidget / CoverageService
  → CoverageService.getPositionData() mothballed (returns null; no Lichess API)
  → CoverageResult (gaps, unaccounted moves, covered %) from in-tree data where available
  → CoverageSuggestionService.generateSuggestions()
  → SuggestionPanel → RepertoireWriter.acceptSuggestion()
```

### Audit

Config in dialog, results in bottom pane:

```
AuditSessionController (owns RepertoireAuditService + all audit state)
  ← Screen delegates pause/resume/cancel via controller methods
  ← tryRestore() on repertoire load; launchResume() for interrupted audits
  ← Persistence: saveProgress/saveComplete/onResultChanged via AuditPersistence

AuditConfigDialog (toolbar button)
  → Wraps AuditConfigPanel in a modal dialog
  → Config: source toggles (Stockfish/Maia; Lichess DB mothballed, `useLichessDb` defaults false), thresholds, scope
  → Start button closes dialog, task runs in background
  → Bottom pane auto-opens to Findings tab
  → RepertoireAuditService.audit(openingTree, config)
       BFS: our moves → StockfishPool.discoverMoves (eval loss check)
       BFS: opponent turns → MaiaFactory (gap check); ProbabilityService mothballed (no Lichess API); clash tree from book PGNs (source: clash)
       BFS: leaves → dead-end detection (stores uncovered move SANs)
       Cumulative probability: product of opponent move frequencies from root
  → Callbacks: controller.onAuditingChanged, .onResultReady, .onLiveFinding

AuditFindingsPanel (bottom pane Findings tab)
  → Receives AuditResult from controller; `interruptedSnapshot` + resume banner when incomplete audit detected
  → onResumeAudit / onStartFreshAudit → controller.launchResume / startFresh
  → FindingsDisplayFilter: auto-scales when >100 findings (drops info → raises reach floor)
  → Summary card: soundness %, coverage %, clickable type badges
  → Filter bar: severity chips (Critical/Warning/Info), "X of N" counter
  → Findings list: sort (severity/reach/ply), filter by type
  → Bulk dismiss: right-click → dismiss similar / at depth / all of type
  → Keyboard: ↓/↑ cycle findings, D dismisses, when panel focused (board navigates)
  → Selected finding highlighted, board arrows shown
  → Dismissed section: count + "Restore all" at bottom
  → Finding tap → RepertoireController.loadMoveSequence()

Controller state:
  → AuditResult + liveFindings + interruptedSnapshot + progress + _activeRepertoireId
  → Repertoire scoping: onRepertoireSwitching(oldPath) cancels in-flight audit, saves progress to old path, clears all state; tryRestore(newPath) has stale-async guard (discards late loads if user switched again)
  → Board annotations: screen reads controller.result for arrows (mistakes=red, inaccuracies=yellow, missing=blue)
  → JSON persistence: *_audit.json beside repertoire PGN; partial progress saved on cancel/dispose via controller.saveProgress()
  → Interrupted audits: controller.tryRestore() sets interruptedSnapshot; controller.launchResume() passes skipFens + priorFindings
  → Shared eval via EvalCache (SQLite-backed, FEN → white-normalized CP + depth)
  → Coverage %: only missingResponse FENs in denominator (dead-ends excluded)
```

### Traps

```
TrapExtractor (during generation)
  → TrapLineInfo list → JSON
  → TrapIndexService (FEN index, line prefix index, metrics)
  → TrapsBrowser, TrapDetailCard, TrapNavigationButtons, PGN trap dots
```

### Coherence

```
CoherenceService.compute(lines)
  → extractItemset per line → Isolate.run(runFpGrowthMining)  // FP-Growth off UI thread
  → clusters + lineCoherence scores on main isolate
  → CoherencePanel, browse coherence hints, suggestion scoring
```

### Engine analysis

```
Settings → Enable engine analysis → EngineLifecycle.toggleOn/Off
UnifiedEnginePane (when lifecycle ≠ off)
  → post-frame _runAnalysis on FEN / lifecycle changes (not during parent build)
  → AnalysisService.ensureWorkers() (lazy spawn on first use) → StockfishPool / EvalWorker
  → Eval chain: session cache → CdbDirect → Stockfish (Lichess Explorer mothballed; DB column hidden, _fetchDbData never called)
  → Best-line eval persisted to EvalCache via _persistBestEvalToCache()
  → Hover on MOVE or PV line → BoardPreviewController (floating) → FloatingBoardPreview overlay
InlineEngineBar — Stockfish discovery writes best eval to EvalCache on completion
ExpectimaxLinesPane — same floating preview on line hover
```

### Training

```
RepertoireTrainingScreen
  → RepertoireService.parse trainable lines from PGN
  → TrainingSessionController (phases, streaks, FSRS-like review)
  → TrainingSettings (persisted)
```

### PGN viewer (Open PGN)

```
PgnViewerScreen._pickFile → `FilePicker.pickFile` (Linux: **XDG Desktop Portal only** in `file_picker` ≥10.3 — D-Bus `org.freedesktop.portal.FileChooser`; no zenity/kdialog fallback) → PgnViewerController.loadFile(path)
  → StorageService.fileExists / readFile (absolute paths as-is; relative → app documents)
  → compute(parseMultiGamePgn) → allGames / filteredGames
  → on failure: controller.errorMessage + debugPrint; screen shows SnackBar + inline error in empty state
  → on success: recent-files prefs, optional saved slice restore, loadCurrentGame
  → game change (↓/↑, dropdown, slice, sort): `loadCurrentGame` resets `currentPosition` to start; `PgnViewerWidget._loadGame` defers `onPositionChanged` to a post-frame callback (avoids setState-during-build when called from `didUpdateWidget`)
Game nav bar (when games loaded): Copy PGN → `filteredGames[currentGameIndex].pgnText` → `Clipboard.setData` + `AppMessages.pgnCopied` snackbar
Analysis tab / inline engine: tap best line or Maia move → `PgnViewerWidgetController.goToMainLineIndex(branchPly)` + `addEphemeralMove` (new RAV per distinct line; prior RAVs kept)
Clear annotations → nav bar `onClearAnnotations` or PGN variation context menu / Escape / Home → `clearEphemeralMoves` (removes ephemeral nodes only)
Keyboard: `N`/`P` prev/next game, `F` flip (`Ctrl+F`/F11 fullscreen), `E` engine (`Ctrl+E` export), `W` auto-next, `A` edit mode, `T` opening tree, `S` solitaire mode; plus `←`/`→` navigate, Home/End jump, Space auto-play, Tab cycle tabs, Escape exit edit/fullscreen/clear annotations. Letter keys suppressed while a text field has focus. Digit star-rating shortcuts removed.
Side tabs: **Game | Analysis** by default. **Line** (book line vs the game on screen, plus the deviation banner) is added only for a Games/tactics handoff (`gameId` / single-game focus). Course files use the opening tree (`T`) to browse matching lines instead.
Opening tree (`T`): `PgnOpeningTreePanel` splits the move tree and a resizable **games at this position** list (`PgnTreeGamesList`). Viewer and repertoire both build through `OpeningTreeBuilder` → `walkMainlineIntoTree` (`pgn_tree_core.dart`); player analysis uses the same walk from `UnifiedAnalysisBuilder` (mainline only). Course / repertoire games (`Result *`) fold RAVs into the tree so every book continuation is a sibling, not just each chapter's mainline; scored player games stay mainline-only (their variations are analysis notes). `*` results count toward frequency without a fake 50% draw bar — the UI says **lines** instead of **games** and hides the W/D/L bar. Chessable intro dummies (`1. Z0 (1. d4 …)`) are promoted onto the mainline before the walk. The list keeps the nav-bar `GameNumberField` + `GameSearchButton` (`/` searches this list, `G` focuses the number). Rows start expanded with the comment-free continuation from this FEN (including a hit that only exists in a sideline), truncated to one line. **Expand all** (next to Search) is on by default — the blue triangle is a bullet and tapping a row opens the game. Unchecked, the triangle previews one line and the title still opens the game. Drag the split handle to grow the list.

**Cursor ownership (same rule as Game vs Line tabs, Analysis `_navigateTo`, Repertoire `jump`):** each exploration surface keeps its own place. The merged opening tree is not the current game's move list, and showing it unmounts `PgnViewerWidget` (which would otherwise reload at move 1). Re-entering the tree — `T`, or the app-bar back after a games-at-position click — restores the tree cursor onto the board; it does not resync from that remounted game. Clicking a game in the list parks that game at the tree FEN (`pgnInitialFen` → `PgnViewerWidget.initialFen`). Leaving the tree with `T` restores the game cursor snapshotted when the tree was opened. First open (no saved tree cursor) still syncs the tree to the current game FEN. Next/prev/sort/slice clear the landing FEN so those games start at move 1. Repertoire's Tree tab and Analysis's opening-tree tab already share one board cursor and stay mounted, so they do not need this snapshot.
```

#### Edit Mode (Annotation)

Toggled via pencil icon in `GameNavBar` or keyboard shortcut `A`. When active:

- **NAG display**: Move-quality NAGs ($1–$6) render inline after the SAN with Lichess-style colors (brilliant=green, good=green, interesting=pink, dubious=blue, mistake=orange, blunder=red). Hidden when edit mode is off.
- **Annotation toolbar**: Tapping a move in edit mode shows an `_AnnotationToolbar` below it with 6 NAG toggle buttons + comment button. Toggling a NAG replaces any existing move-quality NAG.
- **Context menu**: Right-click in edit mode shows Comment, Annotate, Promote (variation), Delete — with promote/delete gated by `protectOriginal`.
- **Protect original PGN**: Checkbox in the edit mode bar (always resets to checked on activation). When checked, destructive operations on the original game moves are disabled.
- **Keyboard**: `Escape` exits edit mode.
- **Persistence**: NAGs saved via `buildMovetext()` → `persistMoveComments()` → file write. NAGs serialize as `$N` tokens after the SAN in standard PGN format.

Key files: `pgn_comment_utils.dart` (NAG constants, `kMoveNags`, `nagColor`, `buildMovetext` with NAG serialization), `pgn_viewer_widget.dart` (`editMode`/`protectOriginal` props, `_AnnotationToolbar`, `_NagButton`), `pgn_viewer_screen.dart` (`_editMode`, `_protectOriginal`, `_buildEditModeBar`), `game_nav_bar.dart` (`onToggleEditMode`, `isEditMode`).

#### Solitaire Mode (Guess-the-Move)

Guess one side's moves of the loaded game; the game unfolds as you get them right. Lives entirely in the PGN viewer (brain icon in the app bar, `Ctrl+S` / `Shift+S`), because any PGN you are viewing is material for it — there is deliberately no separate mode or entry point.

- **Setup strip** (`SolitaireSetupStrip`): the toolbar button opens a one-line strip above the movetext instead of starting at once. Choices: **Guess for** White/Black (defaults to the side at the bottom of the board), **Start** from the game start or **from here** (only offered when the cursor is on the mainline mid-game; the moves before it stay visible), **Include variations** (only when the game has saved sidelines), and **Hint and reveal after** 0–120 s (persisted as `solitaire_reveal_delay_sec`). Enter starts, Esc cancels. The side is fixed for the session: flipping the board or changing perspective no longer restarts it. A new game under a running session restarts with the side read from the board again and the same sidelines choice (`solitaire_include_variations`).
- **Script** (`lib/core/pgn/solitaire_script.dart`): `buildSolitaireScript` lays the session out up front as a list of `SolitaireStep`s — mainline moves from the start ply, and with variations every saved sideline in movetext order: a move, then the alternatives to it, then the line resumes. A sideline's first move is a **premise** (`isPremise`): shown after a 700 ms pause, never asked. Null-move plies are walked through but never asked; ephemeral scratch lines are never drilled.
- **Reveal state** (`lib/core/pgn/solitaire_reveal.dart`): `SolitaireReveal` = mainline frontier ply + revealed sideline node ids + whether unreached sidelines are hidden. Pushed into the PGN widget through `PgnViewerHandle.setSolitaireReveal` synchronously on every controller change, *before* the controller's navigation callbacks fire, so a jump to the new frontier is never clamped against the old one (the old prop-based `revealedPly` lagged a frame). `ViewerGameModel.reveal` clamps mainline navigation, refuses hidden sideline nodes, and `PgnMovetextView.reveal` prunes them from rendering; the fork bar and ←/→ inside a sideline respect it too.
- **Guessing**: a board move counts as a guess only when the board sits on the position the current step is asked from (`mainLineIndex == step.mainlinePly`, or inside a sideline `currentVariationNodeId == step.parentNodeId`); anywhere else it is exploratory analysis. Wrong tries appear live as ephemeral alternatives (sideline roots on the mainline, children of the current node inside a sideline). The opponent's reply auto-plays after 400 ms.
- **Hint** (`H`, lightbulb chip): after the delay, highlights the square of the piece that moves (`ChessBoardWidget.highlightedSquares`). One per move; a hinted move is logged `wasHinted` — not first-try, not revealed. **Reveal** (`R`) gives the move up. Both chips stay visible and grey until available; the countdown sits in its own fixed-width slot so nothing jitters.
- **Status bar** (`SolitaireStatusBar`): "Solitaire · White", a turn cue ("Your move · 2 wrong", "Black replies…", "Sideline: 1… c5", "Sideline 1… c5 · White replies…"), progress over script steps, first-try tally.
- **Leaving**: Esc, the toolbar icon, the Exit chip, and Prev/Next game all ask first (`confirmAction`, non-destructive styling) when guesses have been made and the game is not complete. Closing the file, opening the opening tree, or loading another file stops silently.
- **Guess log & PGN injection**: every asked move is a `SolitaireGuess` (its `SolitaireStep`, wrong attempts, `wasRevealed`, `wasHinted`). On completion the notes (`1st try`, `Hinted`, `Tried: e5, d5 (3 tries)`, `Revealed`) are appended to the move's comment and wrong tries become saved alternatives — for mainline moves by ply (`addGuessAnnotations` / `addGuessVariations`) and for sideline moves by node id (`addGuessNodeAnnotations` / `addGuessNodeVariations`). `persistMoveCommentsFor` updates the in-memory game even without a file, so a pasted PGN's Copy PGN carries the notes; only the disk write needs a path.
- **Completion banner** (`SolitaireCompleteBanner`): score line (first-try, hinted, revealed), Copy PGN, Add to study…, **Analyse for trophies** (leaves solitaire, runs or reuses full-game analysis, then `detectSolitaireTrophies`) and Next game. The trophy sentence and button appear only when there were wrong tries to check.
- **Trophies**: `detectSolitaireTrophies` evaluates each wrong attempt at a mainline position and compares it with the game move's eval (sideline guesses have no eval and are skipped). Trophies persist to `solitaire_trophies.json`, show as markers in the analysis tab, and the cabinet dialog is always listed in the viewer's overflow menu ("Solitaire trophies", with a hint while empty) so the loop is discoverable before the first one is earned.
- **Toolbar adaptation**: in solitaire the `GameNavBar` shows game counter, Hint, Reveal, Fullscreen, Exit and Prev/Next; the app bar hides slice chips, opening tree, amend and perspective; the side-panel tabs, engine bar and Analysis tab are hidden. The engine bar is also hidden while the setup strip is open.

Key files: `lib/core/pgn/solitaire_script.dart` (`SolitaireStep`, `SolitaireScript`, `buildSolitaireScript`), `lib/core/pgn/solitaire_reveal.dart`, `lib/core/pgn/solitaire_controller.dart` (cursor over the script, hints, countdown, score, `SolitaireGuess`), `lib/core/pgn/viewer_solitaire_session.dart` (`SolitaireSetup`, board glue, guess routing, note injection), `lib/core/pgn/pgn_viewer_handle.dart` (the widget surface core may touch), `lib/core/pgn_viewer_controller.dart` (delegating API, `onViewerGameLoaded`), `lib/widgets/pgn/solitaire_status_widgets.dart` (setup strip, status bar, completion banner), `lib/widgets/game_nav_bar.dart` (Hint/Reveal chips), `lib/screens/pgn_viewer_screen.dart` (confirm-on-leave, `H`/`R`/Enter/Esc bindings, analyse action), `lib/widgets/pgn/pgn_movetext_view.dart` + `pgn_movetext_variations.dart` (reveal-aware rendering), `lib/models/solitaire_trophy.dart`, `lib/services/solitaire_trophy_service.dart`, `lib/services/solitaire_trophy_detector.dart`, `lib/widgets/solitaire_trophy_cabinet.dart`.

### Generate repertoire from PGN viewer games

Toolbar ⋮ menu → "Generate repertoire from games":

```
PgnViewerScreen._generateRepertoireFromGames
  → dialog: user enters repertoire name + color (loop on rename)
  → name sanitised (filesystem-unsafe chars stripped; apostrophes preserved)
  → if name already exists → _showDuplicateNameDialog:
      • "Use Existing & Re-seed" → overwrites {name}_raw_games.pgn,
        opens existing repertoire in builder (no new .pgn created)
      • "Pick Different Name" → loops back to name dialog
      • "Cancel" → aborts
  → (new name) saves filteredGames PGN to {name}_raw_games.pgn in repertoires/
  → creates empty {name}.pgn repertoire (header only)
  → AppState.switchToBuilderWithGeneration(repertoirePath, pgnPaths)
  → RepertoireScreen._onAppStateChanged consumes pendingGenerationPgnPaths
    (initState skips selection-screen push when pending data exists)
  → opens generate mode + waits for repertoire loading to finish via
    controller listener before seeding RepertoireGenerationTabState.seedDbExplorer
    (pgnPaths, minGames: 1, autoStart: true)
  → build starts automatically in DB Explorer mode
```

### PGN import UX (multi-source panel)

The `PgnSourcesPanel` extends beyond the single-import `pgn_import_dialog.dart`
for contexts that manage multiple PGN sources (generation, batch import). Architecture:

```
PgnSourcesPanel (lib/widgets/pgn_sources_panel.dart)
  ├─ PgnSourcesController (lib/widgets/pgn_sources_controller.dart)
  │    └─ List<PgnSource> — each with name, filePath/paste, color, sliceConfig;
  │       owned by the host so the list outlives the panel's mount
  ├─ "+ Add PGN" popover → file picker (multi) or compact paste dialog
  └─ Per-source row:
       ├─ Color badge, name, filename, game count
       ├─ Slice chip → expands InlineSliceEditor
       │    ├─ Radio: "All Lines" / "Slice"
       │    ├─ PositionFilter (lib/widgets/slice/position_filter.dart)
       │    ├─ SequenceFilter (lib/widgets/slice/sequence_filter.dart)
       │    ├─ HeaderFilters (lib/widgets/slice/header_filters.dart)
       │    ├─ Isolate-based slice compute → matchedIndices
       │    └─ "Preview lines" → LinesPreviewPanel
       │         ├─ Fuzzy search bar
       │         ├─ Virtualized game line list
       │         └─ HoverableMoveChips per row → BoardPreviewController → FloatingBoardPreview
       └─ Remove button
```

Used by:
- `RepertoireGenerationTab` (DB Explorer mode) — replaces `_buildPgnFilePickerSection()`
- `PgnSliceDialog._buildResultsPreview()` — now embeds `LinesPreviewPanel` with hover board
- `LineItemRow._MovesPreview` — upgraded to `HoverableMoveChips` for hover board on lines browser

---

## Directory reference

### `lib/constants/`

| File | Purpose | Dependencies |
|------|---------|--------------|
| `chess_constants.dart` | Shared chess literals (starting FEN helpers, ply limits) | — |
| `engine_defaults.dart` | Defaults: interactive analysis depth (`kDefaultDepth` 15), **tree generation eval depth** (`kDefaultGenerationEvalDepth` 14), MultiPV | — |
| `ui_breakpoints.dart` | Responsive layout width constants | — |

### `lib/core/`

| File | Purpose | Public API / state |
|------|---------|-------------------|
| `app_state.dart` | Global app mode, usernames, board position, builder↔trainer↔study pending handoffs (`pendingTrainStudyPath` = "Train" in Study mode, `pendingStudyPath` = "Edit study" in the Trainer); **tactics auto-fetch preferences** (`tacticsAutoFetch`, `lichessLastFetch`, `chesscomLastFetch`) persisted via SharedPreferences; `AppMode.usesInteractiveEngine` names which IndexedStack children keep an engine pane | `setMode`, `switchToBuilder`/`switchToTrainer`/`switchToStudyTraining`/`switchToStudyEdit`/`switchToBuilderWithGeneration`, `setRepertoireGenerating`, `setTacticsAutoFetch`, `setLichessLastFetch`/`setChesscomLastFetch`, `notifyListeners` |
| `generation_session_controller.dart` | **Generation session** — owns `TreeBuildService` + `CoherenceService` + the generated-tree bundle; pause/resume/cancel/finishNow; pipeline phases stay here, progress and snapshot export are collaborators | `startBuild`, `pauseBuild`, `resumeBuild`, `cancelBuild`, `discardBuild`, `finishNow`, `onTreeBuilt`, `savePartialTree`, `progress`, `snapshots` |
| `generation_progress.dart` | Throttled BFS / phase stats for the Jobs panel; owned by the session controller | `update`, `setStatus`, `handleBuildProgress`, `flushNotify` |
| `snapshot_exporter.dart` | Mid-run export of lines found so far to a new repertoire file | `export`, `nameSuggestion` |
| `generation_session_types.dart` | `GenerationRequest`, `GeneratedLineExport`, `TreeAnalysis`, `ExtractedLines` | — |
| `audit_session_controller.dart` | **Audit session state** — owns `RepertoireAuditService` + result, live findings, progress, config, interrupted snapshot; handles persistence via `AuditPersistence`; `onLiveFinding` creates a new list on each addition (avoids stale-reference bugs in widget comparisons) | `pause`, `resume`, `cancel`, `saveProgress`, `tryRestore`, `launchResume`, `startFresh`, `onAuditingChanged`, `onResultReady`, `onLiveFinding`, `onProgress` |
| `coverage_controller.dart` | **Coverage session state** — result, progress, running flag | `calculate`, `clear` |
| `board_preview_controller.dart` | Debounced hover FEN overlay for board | `setPreview`, `clearPreview`, `previewFen`, `isPreview` |
| `navigation_stack.dart` | Breadcrumb stack for repertoire navigation | push/pop/jump |
| `pgn_viewer_controller.dart` | PGN viewer file load, game index & navigation | `loadFile`, `errorMessage`, slice/export/tree APIs; `detectProtagonist`, `detectBothPlayers` (two-player matchup detection); `loadCurrentGame` parks at `pgnInitialFen` when set (tree landing / restored game cursor), else game start; `applySlice` no-ops when indices + `SliceConfig` unchanged (skips opening-tree rebuild); loads persisted `.fenidx` companion file on open (validated against PGN file size + mtime + game count; FENIDX2, RAVs included), or builds `fenIndex` in background, for instant position-filter and tree-position lookups; re-persists `.fenidx` after PGN metadata writes to keep stat values fresh; solitaire mode (`toggleSolitaire`, `SolitaireController`); used by `PgnViewerScreen` |
| `pgn/viewer_opening_tree.dart` | PGN-viewer opening-tree mode: build progress, cursor, games-at-position lookup | `toggle`/`enter` restore the saved tree cursor instead of syncing from the remounted game; `snapshotCursor(leavingForGame:)` for games-at-position return; `hasSavedPosition` gates the app-bar back button |
| `pgn/viewer_game_model.dart` | Parsed game + mainline spine + sidelines for the viewer widget | `load` promotes Chessable dummy-null mainlines (`pgn_dummy_mainline.dart`) before extracting variations |
| `pgn/pgn_dummy_mainline.dart` | `promoteNullMoveDummyMainline` — splice a childless `Z0`/`--` dummy whose only sibling is the real lesson onto the mainline | used by the viewer, FEN index, and opening-tree walk |
| `repertoire_controller.dart` | **Central repertoire session state**: owns `MoveTree` + `TreePath` cursor, `RepertoireMetadata? currentRepertoire`, lines, opening tree. Single navigation entry point `jump(path)`. Surfaces load failures via `loadError`. Move entry via `playMove` (replaces removed `userPlayedMove` / `_isInternalUpdate`). Opening-tree clicks call `playMove` so a transposing SAN keeps the board's move order. `deleteAtPath` pushes undo snapshot before deleting. | `jump`, `playMove`, `playMoveAtTreePath`, `userSelectedTreeMove` (opening-tree clicks), `goBack`/`goForward`/`goToStart`/`goToEnd`, `loadMoveSequence`, `navigateToLineMove`, `deleteAtPath`, `promoteVariation`, `makeMainLine`, `setCommentAtPath`, `deleteLine`, `setRepertoire`/`loadRepertoire` |
| `repertoire_writer.dart` | Serialised PGN mutations + undo stack | `addMoveAtPosition`, `acceptSuggestion`, `pushUndo`, `undo`, `canUndo` |

### `lib/models/`

| File | Purpose |
|------|---------|
| `analysis/discovery_result.dart` | Engine discovery lines (MultiPV) |
| `analysis/move_analysis_result.dart` | Per-move analysis in game review |
| `analysis_node.dart` | Game tree node for analysis |
| `analysis_player_info.dart` | Player metadata for analysis; `accounts` (the chess.com/lichess handles an opponent's merged game-set came from — what makes it re-downloadable) and `group` (event name); `displayName` is the first `;`-segment of the username |
| `build_tree_node.dart` | **Generated tree node**: eval, ease, myEase, expectimax, traps, `pvContinuationMove`, `engineInjected`, children, serialization |
| `chess_game.dart` | Loaded game model for tactics/analysis |
| `engine_evaluation.dart` | Single eval result |
| `engine_settings.dart` | **Singleton** engine/generation/explorer settings + SharedPreferences persistence; setters share `_assignIfChanged` / `_assignInRange`; persist is fire-and-forget via `_persist()` |
| `engine_weakness_result.dart` | Weak square / position analysis output |
| `eval_database_settings.dart` | CdbDirect path, enable flags (persisted) |
| `explorer_response.dart` | Lichess opening explorer API shape |
| `move_tree.dart` | Editable PGN move tree (`MoveNode`, `TreePath`, `MoveTree`). FEN cached per node. PGN round-trip via `fromPgn`/`toPgn`. `collectFenPrefixes()` for transposition detection. Used by `RepertoireController` as the single source of truth for the move cursor. |
| `opening_tree.dart` | In-memory statistics tree indexed by FEN. Cursor walks by FEN (so 1.d4 Nf6 2.e3 c5 and 1.d4 c5 2.e3 Nf6 land on the same node). Off-book positions still list **one-ply transpositions** (`continuations` / `viaTransposition`). `hasMove`, `appendLine` / `appendLineFromFen` (null-move passes skip a node). `updateStats(null)` counts frequency without a fake draw; `hasWdl` hides the W/D/L bar on course trees |
| `pgn_filter_models.dart` | PGN import filter types |
| `pgn_source.dart` | **PGN source model** — represents one attached PGN file or paste blob with optional slice config; used by `PgnSourcesPanel` for multi-source import |
| `pgn_game_entry.dart` | One game in a loaded PGN file. `label` is `"White vs Black"` for player games; course exports (`Result *`, no ratings, no `"Last, First"` comma) use `"Chapter — Line"` (or just the title when White==Black) |
| `position_analysis.dart` | Position analysis aggregate |
| `repertoire_line.dart` | Trainable line extracted from PGN (moves, title, probability) |
| `repertoire_metadata.dart` | **Typed repertoire file descriptor** (`filePath`, `name`, `gameCount`, `lastModified`) — replaces untyped `Map<String, dynamic>` across selection screen, controller, storage, generation tab, and training; `fromMap`/`toMap` for legacy JSON only |
| `repertoire_move_progress.dart` | Training progress per move |
| `repertoire_review_entry.dart` | FSRS-style review scheduling |
| `repertoire_review_history_entry.dart` | Review history log |
| `settings_enums.dart` | `CandidateSource`, `SelectionMode` (`expectimax`, `engineOnly`, `dbWinRateOnly`), `OpponentProbabilityMode`, etc. |
| `tactics_position.dart` | Tactics puzzle position; includes `int rating` (0=unrated, 1–5 stars; 1-star excluded from training by default) |
| `tactics_session_settings.dart` | `TacticsSessionSettings` — order (`newestFirst`/`leastReviewed`/`worstSuccessRate`/`random`), `mistakeTypes` filter, `includeOneStar` toggle; `accepts(pos)` for session filtering |
| `training_settings.dart` | Trainer behavior (persisted); `ReviewOrder` enum includes `hardestFirst` (sorts by ascending playability from tree) |

### `lib/features/browse/`

| File | Purpose |
|------|---------|
| **services/candidate_service.dart** | Merges `BuildTree` + coverage delta into `CandidateMove` list (Lichess Explorer mothballed) |
| **widgets/browse_panel.dart** | Candidate list, rare-move collapse, back/root/undo nav |
| **widgets/candidate_row.dart** | Per-move row: eval, ease, traps, DB stats, coherence hint |
| **widgets/expanded_trap_list.dart** | Trap sub-list when expanding trappy candidate |

### `lib/features/coverage/`

| File | Purpose |
|------|---------|
| **services/coverage_service.dart** | Gap detection, `CoverageResult` (`findNextGap`, `findBiggestGap`); `getPositionData()` mothballed (returns null, no Lichess API) |
| **services/coverage_suggestion_service.dart** | Gap → line resolution, scoring, greedy set cover → `SuggestedLine` |
| **widgets/suggestion_panel.dart** | Target coverage UI, accept/skip suggestions with hover preview |

### `lib/features/traps/`

| File | Purpose |
|------|---------|
| **models/trap_line_info.dart** | Trap metadata + optional `allReplies`, `fen`, `refutationMove`, `refutationEvalCp` |
| **models/trap_reply.dart** | Opponent reply classification at trap position |
| **services/trap_index_service.dart** | FEN/prefix indexes, repertoire & line metrics, ETV |
| **widgets/trap_detail_card.dart** | Narrative trap UI, reply table, hoverable move path |
| **widgets/trap_move_indicator.dart** | Orange dot for pre-trap PGN moves, enriched multi-line tooltip (mistake desc, popularity, reach, score) |
| **widgets/trap_navigation_buttons.dart** | Prev/next trap in line (board toolbar) |
| **widgets/trap_summary_header.dart** | Aggregate trap stats + ETV |
| **widgets/trap_walkthrough.dart** | Sequential trap tour with list hover preview |
| **widgets/traps_browser.dart** | Rich trap list with mini board, per-reply stats, classification badges, sort by Eval Drop/Most Common/Trap%/Surplus; filter toggle: All Explored vs In Repertoire (wired into repertoire screen Lines tab) |

### `lib/features/eval_tree/`

| File | Purpose |
|------|---------|
| **adapters/eval_tree_snapshot_adapter.dart** | `BuildTree` → lightweight snapshot for UI |
| **controllers/eval_tree_controller.dart** | Graph selection, pan, focused window |
| **models/eval_tree_snapshot.dart** | Serializable snapshot node |
| **services/eval_tree_file_loader.dart** | Load tree JSON from disk (IO/stub) |
| **services/eval_tree_layout_engine.dart** | Graph layout for focused window (~400 nodes) |
| **services/eval_tree_line_metrics.dart** | Per-node / per-line metrics including `linePlayability` |
| **tree_colors.dart** | Node coloring by eval/ease |
| **widgets/eval_tree_tab.dart** | Tab hosting graph + explorer |
| **widgets/eval_tree_details_pane.dart** | Selected node detail |
| **widgets/eval_tree_node_chip.dart** | Graph node widget |
| **widgets/eval_tree_toolbar.dart** | Graph controls |
| **widgets/eval_tree_viewport.dart** | `graphview` wrapper |
| **widgets/repertoire_tree_explorer.dart** | Table explorer at current FEN (candidates, metrics) |
| **widgets/compact_tree_outline.dart** | Scrollable indented [BuildTree] outline with eval, expectimax V%, and move probability per row; expand/collapse + tap-to-navigate |

### `lib/features/audit/`

Repertoire quality audit — BFS over the existing `OpeningTree` to detect mistakes, inaccuracies, missing opponent responses, weak positions, and dead ends.

**Shares the same caching infrastructure as generation:** Stockfish evals are read from and written to `EvalCache` (SQLite), so running an audit populates the cache for future generation runs and vice-versa. Maia policy/win-prob cached in `EvalCache.maia_cache`. Lichess Explorer mothballed (`ProbabilityService._fetchInternal()` returns null; `useLichessDb` defaults false). The audit is effectively "generation-shaped" — same engines, same persistent cache.

| File | Purpose |
|------|---------|
| **models/audit_finding.dart** | `AuditFinding` — JSON-serializable, with cumulative probability, dismissal state, `transposesIntoRepertoire` flag for missing moves |
| **models/audit_result.dart** | `AuditResult` — JSON-serializable aggregate: findings, stats, soundness/coverage %, cache hit rate |
| **services/audit_config.dart** | `AuditConfig` thresholds (mistake/inaccuracy cp, min games, Maia prob, depth); `useLichessDb` defaults `false`; `clashPgnPaths` for repertoire-clash checking against book/course PGNs; `toMap()`/`fromMap()` serialization; `summaryLabel` compact display |
| **services/repertoire_audit_service.dart** | BFS walker: Stockfish MultiPV for our moves, Maia for opponent gaps (Lichess mothballed), repertoire-clash check against book/course PGN tree (`MissingResponseSource.clash`); reads/writes `EvalCache`; computes cumulative reach probability per finding; transposition detection for missing moves (checks if resulting FEN exists in tree's `fenToNodes`); `pause()`/`resume()`/`cancel()`; exposes `checkedFens` for resume support; accepts `skipFens`/`priorFindings` to resume interrupted audits |
| **services/audit_persistence.dart** | `AuditPersistence` singleton: centralized save/load for audit snapshots (`AuditSnapshot` = result + config + checked FENs + completion state). Auto-loads on repertoire open, auto-saves on dismiss changes. Handles v1 (legacy) and v2 (envelope) JSON formats |
| **widgets/audit_config_panel.dart** | Compact audit configuration: always uses Stockfish + Maia (no source toggles), scope toggle (subtree-only chip), key thresholds (Eval Depth/Max Ply/Maia Elo) shown by default, detailed thresholds under "More thresholds" expander (Mistake cp, Inaccuracy cp, Min Maia Prob — minGames hidden since Lichess mothballed), **Repertoire Clashes** section with PGN file picker for checking against book/course lines, compact start/cancel with inline progress; `useLichessDb` hardcoded false; accepts external `RepertoireAuditService` for pause/resume from Jobs tab |
| **widgets/audit_config_dialog.dart** | Modal dialog wrapping AuditConfigPanel; forwards `auditService` and `onConfigChanged` |
| **widgets/audit_findings_panel.dart** | Results display: category filter chips (Blunders/Inaccuracies/Missing/Weak/Dead Ends) + Clashes source filter (purple, shown when clash findings exist), sorted by reach probability with per-tile probability label, user-configurable visible cap (default 20, inline text field), reach range shown in status row, bulk dismiss context menu, keyboard navigation (↓/↑ and D when panel focused; suppressed in text fields), selected state, timestamp display, "Re-run audit" button; resume banner when `interruptedSnapshot` set (`onResumeAudit`, `onStartFreshAudit`) |

**Entry points:** Toolbar "Audit" button is context-aware: opens bottom pane Findings tab if audit running or results exist; opens config dialog otherwise. Force-open config via "Re-run audit" button in findings panel. Results appear in bottom pane Findings tab.

**Persistence:** Audit results are saved to `<repertoire>_audit.json` via `AuditPersistence`. Results auto-load when a repertoire is opened (`AuditSessionController.tryRestore()` in `_onRepertoireChanged`), so findings survive app restarts. Dismissal changes auto-save via `controller.onResultChanged`. Cancel/dispose call `controller.saveProgress()` → `AuditPersistence.saveProgress()`. `tryRestore()` checks `isComplete` and sets `interruptedSnapshot` for incomplete audits; `controller.launchResume()` resumes with `skipFens`/`priorFindings`. The snapshot envelope (v2) stores the `AuditConfig`, checked FEN set, and completion state.

**Data flow:**
```
AuditSessionController._launchAuditConfig() (via screen)
  ├─ AuditConfigDialog → AuditConfigPanel._startAudit()
  │    ├─ onConfigChanged → controller.lastConfig (stored on controller + job.configSnapshot)
  │    ├─ EngineLifecycle.enterGeneration(1)
  │    ├─ EvalCache.init()  ← shared SQLite eval store
  │    ├─ controller.service.audit(openingTree, config, ...)
  │    │    ├─ BFS over OpeningTree nodes (tracks cumulative reach probability)
  │    │    ├─ Our turn: StockfishPool.discoverMoves → cache best-line eval
  │    │    │    └─ Per-move: EvalCache hit? → skip Stockfish : evaluateFen → cache
  │    │    ├─ Opponent turn: MaiaFactory → check coverage (ProbabilityService mothballed)
  │    │    └─ Leaves: check for uncovered opponent continuations
  │    ├─ onProgress → controller.nodesChecked/totalNodes + currentJob.updateProgress()
  │    ├─ onLiveFinding → controller.liveFindings
  │    └─ onResultReady → controller.result + persisted to <repertoire>_audit.json
  ├─ RepertoireAuditService owned by controller → pause/resume/cancel from Jobs tab
  └─ EngineLifecycle.exitGeneration() on cancel
```

**Finding UX:**
- Clicking a finding navigates within the existing repertoire tree (via `navigateToLineMove`) — the full tree with all variations is preserved.
- **Missing-move ephemeral preview:** Clicking a missing-move finding navigates to the parent position AND shows the missing move played ephemerally on the board (position after the missing move). A blue "Go to position" bar appears below the board with the missing move name; clicking it navigates to that position in the tree. Close button dismisses the ephemeral preview. Ephemeral state auto-clears when the user navigates normally.
- **Transposition detection:** Missing-move findings check if the resulting FEN (after playing the missing move) already exists in the repertoire tree. If so, the finding is tagged "transposes" in the summary — indicating the gap is less critical because the position is already covered elsewhere.
- Category filter chips: Blunders, Inaccuracies, Missing, Weak, Dead Ends — click to toggle (multi-select). Counts shown per chip.
- **Auto-scaling:** At most ~20 findings shown at a time (sorted by reach probability, highest first). As findings are dismissed, lower-probability ones surface. Status bar shows "20 of 150 findings" when capped.
- **Probability display:** Missing moves show Maia probability (e.g. "p=0.003 Maia" for small values). Uses adaptive formatting: ≥10% → integer, ≥1% → 1 decimal, ≥0.001 → 3 decimals, smaller → scientific notation.
- Move numbers in summaries: "Missing: 3...Nd2" instead of "Missing: Nd2". Also for mistakes/inaccuracies.
- Dismiss button: 16px icon with 32px hit target and hover feedback.
- Bulk dismiss via right-click context menu: dismiss similar (same type + FEN), dismiss at depth (all of same type at ply N or earlier), dismiss all of type.
- Keyboard navigation: ↓/↑ cycle through findings (board auto-navigates), D dismisses and advances; suppressed while a text field has focus.
- Selected finding gets a highlighted background in the list, with "X of N" counter in status bar.
- Timestamp display: "2h ago", "3d ago", etc. when viewing saved results.
- Dismissed findings shown in a collapsed section at the bottom with "Restore all".

Implements principles from `docs/tree-display-architecture.md` (focused window, flat index, pre-sorted children).

### `lib/features/engine_tournament/`

Engine-vs-engine play. **The only place the app runs a binary that is not the
bundled Stockfish** — a user-supplied UCI engine has to pass
`verifyUciEngine` (start → `uciok` → `readyok` → a *legal* move from the
standard position) before it can be added, so a wrong pick is reported as a
sentence rather than as a match of silent forfeits.

The whole core is Flutter-free `dart:io`, which is what lets
`tools/run_engine_tournament.dart` drive the identical code path headlessly
into the same `Documents/engine_tournaments/` tree the app reads. That tool is
also how the MCP server runs matches, verifies binaries (`--verify`) and reads
standings (`--show`) — there is exactly one implementation of the arbiter and
of the Elo/SB/LOS maths, and everything else reaches it through that script.

The screen keeps a directory watch, so a match an agent starts fills in live
rather than waiting for someone to press Refresh.

Output is deliberately plain: one directory per tournament holding
`tournament.json` (config + per-game results) and `games.pgn` (the games, in
schedule order). Clicking a row in the games table hands that PGN to the PGN
Viewer with a game index, so the viewer's own Prev/Next then walks the match.

| File | Purpose |
|------|---------|
| **models/time_control.dart** | `TimeControl` — per-move, clock (base+inc, optional moves/session), fixed depth, fixed nodes; labels, PGN `TimeControl` tag, hang-guard ceilings, and the preset list |
| **models/engine_spec.dart** | `EngineSpec` — one competitor: binary path (null = bundled), name, Hash/Threads/Ponder, extra `setoption` pairs |
| **models/adjudication_rules.dart** | cutechess-shaped `-draw` / `-resign` knobs plus the move ceiling and the fifty-move/threefold toggles |
| **models/tournament_config.dart** | Snapshot of a tournament's setup; owns pairing generation (round robin / gauntlet) and `totalGames` |
| **models/tournament_game.dart** | `GameResult`, `TerminationReason` (with PGN `Termination` vocabulary), and the per-game record |
| **models/crosstable.dart** | Standings row + head-to-head grid data |
| **models/stored_tournament.dart** | What lives on disk: config, status, games, paths |
| **services/uci_engine.dart** | UCI process driver for *play* — handshake, options, clock-aware `go`, `bestmove` with score/depth/time, hang guard. Exposes the narrow `PlayingEngine` interface the arbiter uses |
| **services/engine_verification.dart** | The gate on user-supplied binaries; never throws, always reports |
| **services/engine_registry.dart** | `engines.json`; the bundled engine's *settings* persist but its path never does (it is resolved at launch) |
| **services/engine_game_runner.dart** | The arbiter: clocks, repetition/fifty-move, draw & resign adjudication, illegal-move and crash handling, and the PGN writer. Per-move cutechess-style `{+0.31/24 2.0s}` comments are opt-in (`TournamentConfig.annotateMoves`) — on by default they put every move on its own row in the viewer |
| **services/engine_tournament_runner.dart** | Schedule building, concurrent lanes with per-lane engine processes, persist-after-every-game |
| **services/tournament_store.dart** | `Documents/engine_tournaments/<slug>/` — atomic writes, listing, deletion |
| **services/tournament_open_request.dart** | The cross-process "open the app on this tournament" file (`open_request.json`), written by the MCP tools and consumed — read-and-cleared in one step — by the app. Requests older than a day are dropped so a forgotten one cannot hijack a launch |
| **services/tournament_open_watcher.dart** | Checks for a waiting request on start (which is what makes a request written while the app was closed work), then watches the directory. Timer-free on purpose: a poll in the always-mounted host screen would leak into every widget test that pumps it |
| **services/crosstable_builder.dart** | Points, W/D/L, Sonneborn-Berger, Elo ± 95% interval, likelihood of superiority |
| **services/tournament_summary.dart** | One-line readings for the history rail: match score (`Alpha 5½–4½ Beta`), leader of a field, duplicate-name disambiguation, day grouping and run duration. Pure — the arithmetic is `buildCrosstable`'s |
| **controllers/engine_tournament_controller.dart** | Screen state: list, selection, engine registry, live run (board + last move + progress) |
| **widgets/engine_tournament_screen.dart** | The mode screen; hands games to the PGN Viewer, and honours an `OpenEngineTournament` handoff (breadcrumb, or an agent's open request) |
| **widgets/new_tournament_dialog.dart** | Engines, position (FEN / current board / paste), time control, schedule, adjudication |
| **widgets/engine_manager_dialog.dart** | Add / verify / configure / remove engines |
| **widgets/tournament_list_pane.dart** | The history rail: every saved run, newest first, grouped by day, each row carrying its score; filter box appears past six runs |
| **widgets/crosstable_view.dart**, **tournament_games_table.dart**, **tournament_detail_pane.dart** | The results UI |

### `lib/features/master_games/`

The window onto the local TWIC corpus, which until now only the generator could
read. Two views of the same two million games: a filtered database search, and
**In my repertoire** — the games that walked into one of your designated books,
ranked by how deep they got. Playing through them is not reimplemented: any
selection is written out as an ordinary PGN collection and handed to the Games
viewer, which leaves the user with a file they can open anywhere else too.

| File | Purpose |
|------|---------|
| **services/twic_repertoire_scan.dart** | Walks master games against the designated White and Black books with the same `GameDeviationService` the Games page uses on your own games. A master game has no "me", so both books are tried and the deeper agreement wins; separates *tested your choice* (left at a move you cover) from *ran past your prep* (the book simply ends) |
| **controllers/master_games_browser_controller.dart** | Query, paging, mode, selection, the scan, and writing the visible games out as a PGN collection. Changing the filters drops a stale scan rather than showing it against a different set of games |
| **widgets/master_games_browser.dart** | The browser dialog: filter bar (player, pairing, ECO, event, Elo floor, classical-OTB-only), results list, detail pane, and the hand-off to the Games viewer. Opened from the master-games settings panel and from the Openings block on the home column |

### `lib/features/holes/`

Adversarial "Find Holes" hunt — hosted in Player Analysis (`analysis_screen.dart`), which keys results per player + colour. **Different from Analyze with Engine** (raw Stockfish eval coloring of most-played positions): this walks the loaded tree from the ATTACKER's side (opposite the tree's colour) and emits exploitable findings — `uncoveredStrongMove` (engine-strong attacker moves with no reply on file), `refutation` (owner moves that concretely lose, with verified Stockfish PV), `practicalTrap` (**only** the second pass: top leaves get a short Maia expectimax build where practical eval beats raw engine eval for the attacker). Ranked by `exploitScore` (reach × gain) into a short killer list, not a breadth checklist. Reuses the audit's `AuditFinding` model and shared `EvalCache`/`StockfishPool`.

| File | Purpose |
|------|---------|
| **services/hole_hunt_config.dart** | `HoleHuntConfig` — hunt thresholds/knobs for a hunt over an opening tree |
| **services/hole_hunt_service.dart** | Adversarial walker: attacker-side BFS, Stockfish refutation verification, end-of-line expectimax trap pass |
| **services/hole_scoring.dart** | Pure scoring/ranking helpers (exploit score, `LeafEntry` for the trap pass); engine/widget-free for unit tests |
| **services/hole_hunt_persistence.dart** | `HoleHuntSnapshot` JSON save/load at a caller-supplied path; no resume state — cancels save partial reports |
| **widgets/hole_hunt_config_dialog.dart** | Config dialog; pops with a `HoleHuntConfig`, the host screen owns the hunt lifecycle |
| **widgets/holes_report_panel.dart** | Lean ranked report for the Findings tab: flat list sorted by exploit score, per-type filter chips, simple dismissal |

### `lib/screens/`

| File | Purpose |
|------|---------|
| `main_screen.dart` | Mode `IndexedStack`; engine suspend/resume on leaving/entering interactive-engine modes and on `paused`/`hidden`/`detached` (not `inactive`) |
| `repertoire_screen.dart` | **Composition root** — wires `GenerationSessionController`, `AuditSessionController`, `CoverageController` to widgets; owns board, PGN, ephemeral finding preview, layout; when no repertoire is selected shows `RepertoireListBody` inline instead of a placeholder button; keyboard shortcuts via `RepertoireShortcuts`; status bar shows "Audit paused" when audit is paused; Jobs panel listens to both `_jobManager` and `_generationController` via `Listenable.merge` |
| `repertoire_selection_screen.dart` | Full-screen push wrapper around `RepertoireListBody`; pops with selected `RepertoireMetadata` |
| `repertoire_training_screen.dart` | Training mode shell for **repertoires and studies-as-tactics**; Train tab has two `SegmentedButton` selectors — Mode (Repertoire/Tactics) and Repetition (Spaced repetition/Linear); when no source is loaded the body shows `RepertoireListBody` inline with a "Studies — custom tactics" section; consumes `pendingRepertoirePath`/`pendingTrainStudyPath` via an AppState listener (screen is cached in the IndexedStack); app-bar and PGN-tab edit buttons switch Builder↔Study by source; Lines tab uses `TrainingLinesPanel` (categorized Learn/Review view with SRS metadata, per-line playability chips, bottleneck warnings, "needs scoring" banner linking to Builder — suppressed for studies); keyboard: J toggles manual advance, Space acknowledges learn steps or opponent-comment Next, `/` focuses move input (letter keys suppressed in text fields) |
| `analysis_screen.dart` | Game weakness / position analysis |
| `study_screen.dart` | **Composition root** for Study mode — wires `StudyController` to `StudyBoardPane`, `StudySidePane`, `StudyPickerBar`, `StudyChapterSidebar`; keyboard, import/export, train/browse handoffs stay on the screen |
| `pgn_viewer_screen.dart` | Standalone PGN + `InlineEngineBar`; surfaces `loadFile` errors via SnackBar and empty-state text; ⋮ menu with "Generate repertoire from games"; solitaire mode toggle + feedback overlay + progress bar; keyboard: N/P/F/E/W/A/T/S letters plus arrows, Home/End, Space, Tab, Escape, Ctrl+E export, Ctrl+F/F11 fullscreen; caches `AppState` so dispose does not `context.read` |
| `player_selection_screen.dart` | Player pick for analysis: cached game-sets from chess.com / lichess downloads, PGN-file imports, and **opponent lists** (`OpponentListImportDialog` → one merged player per opponent, sourced from every account listed, tagged with the event as `group`; batch download with per-person progress, skip-existing, failures reported not swallowed); search matches name, platform and group |
| `settings_screen.dart` | Machine-level settings (accounts, my repertoires, engine cores, ChessDB); body is a bounded `ListView` so every section is reachable; analysis *behavior* lives on per-panel gears |

### `lib/services/` (grouped)

#### Engine & analysis

| File | Purpose |
|------|---------|
| `engine/engine_lifecycle.dart` | OFF/IDLE/ANALYZING/GENERATING state machine; `toggleOn`/`toggleOff`/`enterGeneration`/`exitGeneration` serialized via `_serialExec`; `suspend`/`resume` preserve `_userWantsEngine`; `onPositionChanged` skips notify when already ANALYZING; `@visibleForTesting resetForTest()` resets singleton; `testMode` skips pool I/O in unit tests |
| `engine/engine_connection.dart` | Abstract engine connection |
| `engine/eval_worker.dart` | UCI worker loop |
| `engine/stockfish_pool.dart` | Worker pool acquire/release, `prepareForTreeBuild` |
| `engine/stockfish_*_connection.dart` | Platform Stockfish backends |
| `engine/process_connection*.dart` | Process spawn (native/stub). Delegates path setup to `stockfish_bundle.dart`. |
| `engine/stockfish_bundle.dart` | Installs desktop Stockfish: support-dir cache, then bundled `.gz`, then download of the lockfile URL (checksummed). macOS lock key is arch-specific; the extracted file is always `stockfish-macos`. |
| `analysis_service.dart` | Multi-position analysis orchestration |
| `analysis_games_service.dart` | Fetch/store analysis game-sets; `downloadGamesFor(player)` is the single (re-)download entry point — one live account, or every `account` of an opponent concatenated into one PGN |
| `game_analysis_controller.dart` | Game review session; cached and live replay pass ChessBase `--`/`Z0` without dropping later plies (1-based PGN ply still includes the pass) |
| `engine_weakness_service.dart` | Weakness detection |
| `unified_analysis_builder.dart` | Builds unified analysis structures |

#### Eval providers & chain

| File | Purpose |
|------|---------|
| `eval/eval_chain.dart` | Ordered provider chain |
| `eval/cdbdirect_eval_provider.dart` | Local TerarkDB/CdbDirect |
| `eval/chessdb_api_provider.dart` | ChessDB.cn API |
| `eval/sqlite_eval_provider.dart` | Local SQLite cache |
| `eval/in_memory_eval_provider.dart` | Session hash |
| `eval/external_eval_provider.dart` | Remote eval abstraction |
| `eval/db_move_list.dart` | `ExternalMoveProvider` — a database's whole ranked move list (`DbMove`/`DbMoveList`), not just a score; what `BuildMode.chessDbBook` builds from |
| `eval/chessdb_score.dart` | ChessDB's raw score encoding (plain cp, mate as ±(30000−ply)), decoded once for both ChessDB faces |
| `eval/cdb_snapshot_catalog.dart` | Which full dumps exist and what they cost — reads the published `chess-YYYYMMDD` snapshots off the Hugging Face mirror of chessdb.cn (per-file sizes and SHA-256, so the download knows the exact total before it starts). Parsers are pure and tested; the network half is one injectable `http.Client` |
| `eval/cdb_snapshot_download.dart` | The ~1.2 TB transfer itself: four parallel HTTP range requests, per-file resume (a partial file continues from its own length, a finished one is never re-fetched), pause/resume across app restarts, a free-space guard that parks the job rather than filling the disk, and `check()` to compare local lengths against the manifest. Registers a resumable `JobType.evalDatabase` job and points `EvalDatabaseSettings` at the `data/` folder when it finishes |
| `eval/storage_volumes.dart` | `df -PB1 -T` → mounted volumes with free space, deduped per device, each tagged SSD / hard disk / network from `/sys/block/*/queue/rotational` (LUKS and LVM resolved through `slaves`). Also `formatBytes` / `formatDuration`, used wherever the download reports size or ETA |
| `eval/lichess_eval_source.dart` | What `database.lichess.org` is publishing today: a `HEAD` for the size and `Last-Modified` (which is the file's only version identity — Lichess refreshes it in place) plus the page scrape for the position count and publication date. Falls back to the September 2026 figures, flagged, when the site is unreachable |
| `eval/lichess_eval_line.dart` | One JSONL line → one row. Scans the text directly instead of `jsonDecode` because the import reads 394M lines averaging 716 bytes; keeps the deepest eval's first PV. Documents the sign convention (`cp` and `mate` are **White-relative**, established from the data, not from the download page) and packs the best move into 15 bits |
| `eval/zstd_stream.dart` | Streaming zstd, so the 21.7 GB download is never expanded to disk: libzstd through FFI where the library exists (Linux, macOS), the `zstd` command as the fallback. Detects a frame that ends early, so a truncated download fails instead of quietly building a partial database |
| `eval/lichess_eval_store.dart` | The sorted flat store the evals live in — 15-byte records keyed by the same FNV position key the master-games book uses, with a sparse index every 1024 keys. ~5.9 GB and one disk read per lookup, where the equivalent SQLite table would be ~10 GB of random-insert B-tree |
| `eval/lichess_eval_import.dart` | Scan then merge: decompress, parse, append each record to one of 256 bucket files chosen by the key's top byte; then sort each bucket in memory and concatenate. Checkpoints line count and bucket lengths so an interrupted scan resumes without re-parsing or double-counting, and discards the buckets when a newer file is published |
| `eval/lichess_eval_provider.dart` | `ExternalEvalProvider` over the store, converting the published White-relative scores into the white-normalized cp / side-to-move mate the rest of the app uses |
| `eval/lichess_eval_controller.dart` | Owns the two stages behind one progress bar — resumable range download, then the import isolate — with a free-space guard, Jobs-pane integration, and delete-the-archive / delete-everything. Points `EvalDatabaseSettings` at the store and switches it on when the build finishes |
| `eval_cache.dart` | Eval cache facade (SQLite v2): Stockfish evals + `maia_cache` table keyed by `(fen, elo)` (policy JSON, win prob); `MaiaCache` get/put with L1 in-memory mirror; get/put await idempotent `init()` so background warm-up in `main` cannot leave early writes memory-only; fire-and-forget writes use `putEvalCpWhiteSoon`; shared by generation, audit, and interactive engine panes |
| `eval/eval_canonicalize.dart` | FEN normalization for lookup |

#### Generation pipeline

| File | Purpose |
|------|---------|
| `tree_build_service.dart` | BFS tree build; canonical-FEN transposition table with `propagate_higher_cumP` on higher-probability transposition hits; root MultiPV floor `max(ourMultipv, 10)` at ply 0; MultiPV line-0 PV reply stash + opponent-node injection when Maia omits it; `buildFromPgnFreqMap()` for DB Explorer mode |
| `generation/pgn_freq_map.dart` | PGN frequency map (Dart port of C `pgn_freq.c`): isolate-based PGN parsing via `file_text_reader` (UTF-8 with Latin-1 fallback), FEN-based prefix matching (games reaching target via transposed move orders), per-position move frequencies keyed by 4-field canonical FEN, min-elo filtering, move probability filtering; detailed parse warnings (first 10 failures); tracks `fileReadErrors` in stats. `pgn_freq_parser.dart` treats `--`/`Z0` as a turn pass (no `recordMove`) so later same-side SAN stays legal |
| `generation/pgn_freq_cache.dart` | Disk cache for parsed frequency maps (`<pgn>.freq.cache`); manifest keyed on file path/size/mtime + `startFen`/`startMoves`/`maxPly`/`minElo`; binary format compatible with C `PFREQ` layout |
| `generation/line_extractor.dart` | Extract lines from tree; PGN `{engine-injected}` on injected opponent moves |
| `generation/pgn_export.dart` | Export generated lines to PGN (includes `{engine-injected}` annotation) |
| `generation/generation_config.dart` | `TreeBuildConfig` (default `evalDepth` 14, `relativeEval` true), build modes; `summaryLabel` / `buildModeLabel` / `engineResourceLabel` for Jobs panel; DB Explorer fields: `pgnFilePaths`, `dbMinGames`, `dbMinProb`, `minElo` |
| `generation/tree_eval_resolver.dart` | Eval resolution during build |
| `generation/tree_ease.dart` | Opponent ease calculation |
| `generation/tree_my_ease.dart` | Our-move naturalness + line playability |
| `generation/eca_calculator.dart` | Expectimax + trap scores + per-node opponent CPL (diagnostic) |
| `generation/repertoire_selector.dart` | Mark repertoire moves on tree (3 objectives; novelty weight and tie-breaks on top) |
| `generation/trap_extractor.dart` | Trap candidate collection |
| `generation/fen_map.dart` | Transposition map keyed by 4-field canonical FEN (`canonicalizeFen`); `freeze()` after `GeneratedRepertoire.fromTree`; shared cycle helpers `isTranspositionCycle` / `enterFenPath` / `enterPositionOnce`; `resolveTransposition(node, fenMap)` follows canonical FEN when a leaf has children elsewhere |
| `generation/tree_serialization.dart` | tree.json read/write (`pv_continuation_move`, `engine_injected`) |
| `generation/tree_build_progress.dart` | Progress callbacks |

#### Repertoire & PGN

| File | Purpose |
|------|---------|
| `repertoire_service.dart` | Load/save repertoire, parse lines, append moves; in-place line edits and deletion locate games via `_findGameIndexByLineId` and rewrite via `_reassembleDocument` (atomic `_writeAtomically`); `deleteLine(filePath, lineId)` removes a game from disk |
| `repertoire_review_service.dart` | Review scheduling |
| `pgn_service.dart` | General PGN load/save |
| `pgn_parsing_service.dart` | Multi-game split/count (`splitPgnIntoGames`, `countPgnGames`); `[Event]`-delimited chunks, including back-to-back games without blank lines (tree_builder exports); `buildFenIndex` builds an inverted FEN→game-indices map in an isolate for O(1) position lookups (mainline **and RAVs**); `computeSliceMatches` is the shared entry point for position+header+sequence filtering (fast path with FEN index, slow path without); `serializeFenIndex`/`deserializeFenIndex` persist the index as a FENIDX2-format companion `.fenidx` file (header stores game count, PGN file size, and mtime for staleness detection; FENIDX1 blobs rebuild); `parseTargetFen` / `gamePassesThroughFen` / `buildFenIndex` / `mainlineSansAfterFen` replay ChessBase/Chessable **null moves** (`--` / `Z0`) as a turn pass so later same-side SAN stays on the index; `promoteNullMoveDummyMainline` runs before replay so Chessable intro chapters index the lesson moves; `gameMatchesSequence` ignores those tokens; `mainlineSansAfterFen` returns remaining SAN after a FEN along the line that found it (used by the opening-tree games list PV) |
| `opening_tree_builder.dart` | Build opening tree from PGN via `walkMainlineIntoTree`; `*` / empty Result → `userResult: null` and `includeVariations: true` (course sidelines become tree siblings); scored games stay mainline-only; `--`/`Z0` pass without a tree node |
| `pgn_tree_core.dart` | Shared PGN attribution + walk used by `OpeningTreeBuilder` and `UnifiedAnalysisBuilder`; `includeVariations` counts each RAV as a line so sibling frequencies still sum to 100% |
| `default_pgn_service.dart` | Bundled default PGN extraction (`rootBundle.load` + `decodeTextBytes` for Latin-1/Windows-1252 names in legacy PGNs) |

#### Expectimax & lines

| File | Purpose |
|------|---------|
| `expectimax_line_service.dart` | `followExpectimaxLine`, `generateExpectimaxLines` (capped, used by hole/trick probes), `expectimaxLinesForAllMoves` (the pane's position table), `findNodeByFen`, `ExpectimaxLine` model. Pure reads of the cooked tree |
| `line_metrics_helpers.dart` | Line-level quality/trap/coherence metrics for UI |
| `coherence_service.dart` | FP-Growth coherence + browse hints; `compute()` runs mining in `Isolate.run` |
| `fp_growth.dart` | FP-Growth algorithm |
| `probability_service.dart` | Move probability helpers; `_fetchInternal()` mothballed (returns null immediately, no Lichess Explorer API) |

#### Maia & Lichess

| File | Purpose |
|------|---------|
| `maia_service.dart`, `maia_native.dart`, `maia_stub.dart`, `maia_factory.dart`, `maia_tensor.dart` | Human move prediction; ONNX model + vocab JSON are git-tracked Flutter assets; native ORT comes from the `onnxruntime` plugin (Linux/Windows/macOS). `evaluate()` checks `MaiaCache` before inference. |
| `lichess_api_client.dart` | Authenticated API |
| `lichess_auth_service.dart` | OAuth/PAT token storage |
#### Tactics & training

| File | Purpose |
|------|---------|
| `tactics_engine.dart` | Puzzle validation; `buildTrainableLine` extends lines using **Maia opponent-probability** (≥ 85% threshold) when available — agreement with PV continues from PV, disagreement triggers a fresh Stockfish depth-14 eval for the user's best reply then stops, low confidence stops at single move; falls back to captures/checks/mates heuristic when Maia is unavailable; max 6 ply (3 user moves); `solutionPv` + `solutionLineToSan` for Show Solution |
| `tactics_database.dart` | Local puzzle store; `startSession(settings)` builds filtered/ordered queue; `setRating(fen, rating)` persists star rating + removes 1-star from live queue |
| `tactics_import_service.dart` | Import from Lichess/Chess.com; supports `since` parameter for date-based fetch (Lichess `since` query param, Chess.com archive month filtering + PGN date header filtering); 200-game safety cap on date-based imports; initializes Maia at import start; extracts user Elo from first game PGN headers (`WhiteElo`/`BlackElo`) — Lichess uses PGN Elo as-is; Chess.com maps blitz Elo via `chesscom_lichess_elo.dart` then clamps 600–2400 (default 2200); passes `MaiaEvaluator` + `EvalWorker` to `buildTrainableLine` for line extension; **atomic per-game completion**: positions are awaited/persisted before `markGameAnalyzed`, so an app close mid-batch never permanently skips a game's blunders; `countPendingGames()` reports stored-but-unanalyzed count; `resumeStoredPgns()` re-analyzes from storage (splits by source prefix, uses appropriate username per platform); all public import/resume methods return `ImportResult` (`positions`, `gamesAnalyzed`, `gamesSkipped`) so callers can distinguish "all skipped" from "analyzed with no blunders" |
| `tactics_export_import.dart` | Export/import facade |
| `tactics_export_import_io.dart` / `tactics_export_import_stub.dart` | Platform export/import |
| `tactics_parallel_analyzer.dart` / `tactics_parallel_analyzer_stub.dart` | Parallel puzzle analysis |
| `tactics/tactics_session_controller.dart` | Puzzle session; `startSession(settings)` delegates to DB queue; `setRating(star)` on current position |
| `tactics/tactics_import_coordinator.dart` | Import UI coordination; `TacticsImportMode.recent` / `TacticsImportMode.sinceDate` for count-based vs date-based fetch; passes `since` param through to service; **resume analysis**: `refreshPendingCount()` diffs stored PGN game IDs against `analyzedGameIds` to detect interrupted imports; `resumeAnalysis()` re-processes only un-analyzed games from storage (no re-download); `pendingGameCount`/`totalStoredGames` drive the resume button; `_statusMessage(ImportResult)` picks "Games were already analyzed" / "No new blunders found" / "Added N …" based on `gamesAnalyzed` count |
| `training/training_session_controller.dart` | Repertoire training flow; `TrainingMode` × `RepetitionMode`; owns queue, drill, and session stats. Learn walkthrough and missed-move replay are collaborators (`LearnPhase`, `ReplayPhase`); chapter grouping is `ChapterScope`; disk review state is `ReviewProgressStore` |
| `training/learn_phase.dart` | New-line acknowledge / quiz walkthrough |
| `training/replay_phase.dart` | Missed-move replay after a drill with mistakes |
| `training/chapter_scope.dart` | Chapter grouping and training scope |
| `training/review_progress_store.dart` | Persisted SRS entries, per-move streaks, history writes |
| `training/training_phase.dart` | Phase enum/state |
| `opponent_list.dart` | Parse opponent-list JSON (`chess-auto-prep/opponents@1`) into `AnalysisPlayerInfo` entries for Player Analysis |

#### Storage & platform

| File | Purpose |
|------|---------|
| `storage/storage_service.dart` | Abstract file I/O; `listRepertoireFiles()` → `List<RepertoireMetadata>` |
| `storage/io_storage_service.dart` | Desktop/mobile IO; `_resolveFile` maps relative paths to app documents; `readFile` / PGN reads use UTF-8 with Latin-1 fallback via `utils/file_text_reader.dart`; `listRepertoireFiles` filters out `*_raw_games.pgn` companion files; `fileStat` returns file size + modification time for index staleness checks |
| `storage/storage_factory.dart` | Platform factory |
| `storage/app_paths.dart` | App data directories |

### `lib/widgets/` (grouped)

#### Shared UI patterns

| File | Purpose |
|------|---------|
| `shortcut_tooltip.dart` | **Shortcut hover tooltips** — `actionTooltip()`, `ShortcutIconButton`, `ShortcutTooltip`, `shortcutTooltip()` (500ms hover delay); debug asserts if shortcut is empty. Cursor rule: `.cursor/rules/shortcut-tooltips.mdc`. Tests: `test/widgets/shortcut_tooltip_test.dart`. |
| `common/list_search_field.dart` | Compact one-line filter box (`fontSize` 13, 6px radius outline) used by list toolbars and `GameSearchDialog`; `matchesSearch` is the shared contains-filter |

#### Layout (repertoire builder zones)

| File | Purpose |
|------|---------|
| `layout/repertoire_layout.dart` | 3-zone orchestrator (board / main / context) |
| `layout/board_zone.dart` | Board wrapper; app-bar trap navigation via `BoardZoneControls` |
| `layout/edit_main_zone.dart` | PGN editor column shell (clipboard + view-in-lines adapters) |
| `layout/edit_context_zone.dart` | Edit context column: FilterChip visibility toggles; user-arrangeable **columns** (horizontal, draggable dividers) each with a **vertical stack** of panels (draggable dividers). Default layout: col1 = Browse+Engine+Expectimax+Tree stacked, col2 = Lines. **Arrange panes** sheet + long-press chip → assign column. Layout persisted via [EditContextLayoutPrefs] (`edit_context.layout_v1`). Panel shells use [AutomaticKeepAliveClientMixin] but **rebuild slot content** each parent update (tree/generation props must not freeze). Expectimax uses [ExpectimaxPanelHost] (built-tree values only, same as dock). `selectedViewsNotifier` mirrors visible set. |
| `layout/edit_context_tabs.dart` | `EditContextTabSpec`, `kEditContextTabs` chip descriptors |
| `layout/edit_context_split_handle.dart` | Draggable horizontal/vertical pane dividers |
| `layout/edit_context_layout_sheet.dart` | Bottom sheet: reorder stacks, move views between columns |
| `models/edit_context_layout.dart` | `EditContextLayout` / `EditContextColumnLayout` column+stack model |
| `services/edit_context_layout_prefs.dart` | SharedPreferences persistence for edit context layout |
| `layout/analyze_main_zone.dart` | Analyze mode main column shell |
| `layout/analyze_context_zone.dart` | Detail pane (eval graph, trap card) |
| `layout/repertoire_mode.dart` | `RepertoireMode`, `EditContextView` enums |
| `layout/repertoire_mode_switcher.dart` | Edit/Analyze toggle (legacy — not wired from screen) |
| `layout/bottom_pane.dart` | VS Code-style resizable, collapsible bottom pane with tabs (Findings/Jobs); collapsed by default, opens at max height (60%) to minimise board area, auto-opens on audit/generation start, drag-resizable, badge counts |
| `layout/repertoire_status_bar.dart` | Bottom metrics bar (badges open bottom pane tabs) |
| `layout/empty_state_placeholder.dart` | Shared empty states |
| `repertoire_list_body.dart` | Embeddable repertoire list with create/rename/delete; used inline by Builder and Trainer screens when no repertoire is selected, and by `RepertoireSelectionScreen` as a full-screen push; optional `onStudySelected` adds a "Studies — custom tactics" section (trainer only; study management stays in Study mode) |
| `layout/responsive_split_layout.dart` | Generic split helper |

#### Repertoire-specific

| File | Purpose |
|------|---------|
| `repertoire/repertoire_board_pane.dart` | Board + preview overlay + generation dim |
| `repertoire/repertoire_shortcuts.dart` | `RepertoireShortcuts` — `CallbackShortcuts` (Ctrl/Cmd+Z undo, Ctrl/Cmd+Shift+V paste FEN) + `Focus.onKeyEvent` for letter/arrow bindings; suppresses shortcuts while a text field is focused (`isTextInputFocused()` in `lib/utils/keyboard_shortcut_utils.dart`) |
| `repertoire/repertoire_toolbar.dart` | App bar: `AppModeSwitcher` + repertoire switcher as the title; actions: contextual buttons → select repertoire → overflow ⋮. |
| `repertoire/repertoire_tab_bar.dart` | Compact layout tab bar (PGN | Context) + navigation trail |
| `repertoire/repertoire_analyze_pane.dart` | Wires analyze zones (lines, coverage, traps) |
| `repertoire/repertoire_analyze_props.dart` | Prop bag for analyze pane |
| `repertoire/repertoire_lines_with_traps.dart` | Lines tab with trap + coherence panels |
| `generation/generation_config_form.dart` | `GenerationConfigForm` — settings form (controllers, build mode, advanced thresholds, eval sources); prominent **Engine resources** section (threads, hash MB, logical core count) when Stockfish is used; `toConfig({startFen, playAsWhite})`, `validateBeforeStart()`, `seedDbExplorer()`, optional `initialConfig`; DB Explorer mode shows `PgnSourcesPanel` + tuning fields; owns `EvalSourcesController` / `SkeletonPlanController` / `PgnSourcesController`, which hold the three sub-editors' state |
| `generation/eval_sources_controller.dart` | `EvalSourcesController` — the eval lookup chain's settings (local ChessDB file, ChessDB API quota/concurrency, subtree skip, depth floor) plus today's API spend; `applyConfig` ↔ `applyTo` are the two halves of the config round trip |
| `generation/skeleton_plan_controller.dart` | `SkeletonPlanController` + `kStructureVetoes` — the typed lines and active vetoes behind `SkeletonPlanCard`; `loadPlan` / `currentPlan(playAsWhite:)` |
| `repertoire_generation_tab.dart` | Build orchestration + progress UI; embeds `GenerationConfigForm` via `GlobalKey`; receives `GenerationSessionController`; sets `controller.setPartialSaveContext()` at build start so pause/cancel from any source saves partial tree |
| `repertoire_analysis_dock.dart` | Resizable Engine/Expectimax dock above PGN |
| `repertoire_lines_browser.dart` | Filter/sort/group lines; 300 ms search debounce; typed `LineSortBy`/`LineMetricsFilter`; filter reset uses single `setState` |
| `interactive_pgn_editor.dart` | Tree-structured PGN editor with Overlay-based context menu (promote, make main line, duplicate line, copy PGN, view in lines, delete), trap dots, hover preview hooks; memoizes `_buildMoveWidgets` when tree+path unchanged and context menu closed; highlights root-to-target path when context menu is open; I/O via `onAutoSave`/`onDirty`/`onCopyToClipboard`/`onViewInLines` callbacks (wired in `EditMainZone`); Save button removed |
| `opening_tree_widget.dart` | Compact tree navigator. Continuations come from `OpeningTree.continuations` (played moves plus one-ply transpositions, marked `≈` / "transp.") |
| `opening_tree/opening_tree_move_row.dart` | Tree row |
| `opening_tree/coverage_annotation.dart` | Coverage badges on tree |
| `coverage_calculator_widget.dart` | Run coverage analysis UI |
| `coherence_panel.dart` | Cluster list + global coherence score |

#### Engine widgets

| File | Purpose |
|------|---------|
| `engine/unified_engine_pane.dart` | MultiPV table, hoverable PV via `ClickableMoveLineWidget`; FEN changes schedule analysis post-frame (avoids setState-during-build); DB column hidden; best eval persisted to `EvalCache` via `_persistBestEvalToCache()` |
| `engine/expectimax_lines_pane.dart` | Position table from the built tree: every move with practical (expectimax) value beside engine eval, ★ on the chosen move, continuation; honest empty states (no tree / not in tree / leaf). Never runs the engine |
| `engine/expectimax_panel_host.dart` | Thin wrapper binding [ExpectimaxLinesPane] to a [RepertoireController] cursor (or `fenOverride`); used by [EditContextZone], [InlineExpectimaxBar] and [RepertoireAnalysisDock] |
| `engine/inline_engine_bar.dart` | Compact engine for PGN viewer and tactics; settings button opens `AnalysisSettingsContext.tacticsEngine` (depth + multiPv only); writes Stockfish eval to `EvalCache` after discovery completes |
| `engine/inline_expectimax_bar.dart` | Compact toggleable expectimax bar for right pane; wraps `ExpectimaxPanelHost(compact: true)` with toggle switch and settings gear |
| `engine/engine_toggle_button.dart` | Legacy bolt toggle widget (unused; engine on/off is in Settings) |
| `engine/engine_pane_footer.dart` | Engine pane footer controls |
| `engine/floating_board_preview.dart` | Cursor-following mini board overlay on engine/expectimax line hover |

#### Lines sub-widgets

| File | Purpose |
|------|---------|
| `lines/line_filter_controls.dart` | Compact search + sort/coverage filter chips (same 6px-radius outline as `ListSearchField`) |
| `lines/line_item_row.dart` | Single line row + trap/coherence badges; unaccounted-move preview sorts a copied list (does not mutate source); trash icon with confirm dialog (`onLineDeleted` callback) |
| `lines/line_metrics_panel.dart` | Metrics + Next/Biggest gap buttons |
| `lines/lines_list_panel.dart` | Grouped list view; lazy `ListView.builder` over flattened group headers + line rows |

#### Shared / other modes

| File | Purpose |
|------|---------|
| `app_mode_switcher.dart` | Top-level mode switcher: the app-bar title with the grouped mode menu behind it |
| `chess_board_widget.dart` | Board rendering, move input; `_BoardPainter.shouldRepaint` compares highlight/square/color state (not always `true`). Pieces are `Positioned` on their squares with no implicit animation, so a layout resize (expanding a chapter list, dragging a panel) cannot slide them. Annotation types live in `lib/models/board_annotation.dart`. |
| `clickable_move_line.dart` | SAN line with tap + hover callbacks |
| `navigation_trail.dart` | Breadcrumb trail widget (used by repertoire tab bar) |
| `analysis_tab.dart` | Legacy browse/analysis tab wrapper (not used in current repertoire screen) |
| `generation_config_dialog.dart` | Modal dialog wrapping RepertoireGenerationTab; pops on generation start via controller listener; opened by sparkles button |
| `layout/jobs_panel.dart` | Jobs tab: single rich card per active generation or audit job (name, build mode config summary, phase icon/label, C-style live stats, thread/hash chips, linear progress, elapsed, pause/resume/cancel/finish-now); completed jobs as compact list tiles |
| `services/jobs/generation_job_display.dart` | Phase labels, stats-line formatting, and progress fraction helpers for generation job cards |
| `analysis/analysis_settings_sheet.dart` | Context-aware analysis/engine settings dialog. Accepts `AnalysisSettingsContext` (`full` or `tacticsEngine`) to gate which sections are shown: engine depth + multiPv always; panel visibility in `full` mode ("Show DB % column" toggle and Lichess DB filter section hidden — Explorer mothballed). |
| `analysis_download_dialog.dart` | Download games for analysis |
| `game_analysis_tab.dart` | PGN viewer Analysis tab: chart, classified move list, best-line / Maia taps; each tap adds an **ephemeral RAV** at that ply (accumulates; does not clear prior lines); move list scrolls only when the nearest classified row changes (instant `ensureVisible`, no per-ply jump+animate) |
| `game_analysis_chart.dart` | Eval chart for game review |
| `game_nav_item.dart` | `GameNavItem` — label, study rating/summary, PGN `headers` for nav bar and search dialog; `fromEntry(PgnGameEntry)` |
| `game_number_field.dart` | **Game N of Total** jump box: the counter *is* the input (digits only, Enter jumps, Escape restores, `G` focuses). Search-by-name stays on the Search button so the current position stays visible while you type |
| `game_nav_bar.dart` | Game navigation controls; **Game N of Total** is `GameNumberField` (`G`); compact labeled **Search** button (same outline/height as the number box, `/`) opens `GameSearchDialog`; **Copy PGN** (`onCopyPgn`) and **Clear analysis annotations** (`onClearAnnotations`, `Icons.layers_clear_outlined`, enabled when `hasEphemeralAnnotations`) in auto-play row; **Edit mode toggle** (`onToggleEditMode`, `isEditMode`) pencil icon with amber highlight when active; **Solitaire mode** (`isSolitaireMode`) switches layout to Reveal/Exit chips + Prev/Next only (keeps the number box + Search) |
| `game_search_dialog.dart` | Compact jump-to-game search (`GameNavItem.headers` + study fields) using the shared `ListSearchField`; empty query lists every game; pure-integer query → “Go to game N” plus text matches; Enter selects first, Escape dismisses; `showGameSearchDialog` / `GameSearchButton` shared by the nav bar and the opening-tree games list |
| `games_list_widget.dart` | Selectable games list |
| `fullscreen_game_view.dart` | Fullscreen game + board view |
| `fen_list_widget.dart` | FEN list display helper |
| `pgn_with_analysis_pane.dart` | PGN + analysis dock split |
| `pgn_with_engine.dart` | PGN pane with inline engine bar |
| `pgn_viewer_widget.dart` | Game list + board for viewer; `_variationsByPly` holds mainline + **multiple ephemeral RAVs** per branch point (`addEphemeralMove` / `clearEphemeralMoves`); movetext via `PgnMovetextView` (near-white `PgnTextStyles`, comments/variations on own rows); larger branch chips + Return-to-mainline + nav icons; **Edit mode** (`editMode` prop): NAG inline display, annotation panel, right-click context menu with promote/delete gated by `protectOriginal`; `_toggleNag` modifies `PgnNodeData.nags` and persists via `buildMovetext` |
| `pgn/pgn_movetext_view.dart` | Mainline + sideline + comment rendering; uses `PgnTextStyles` (comments upright, not italic). ChessBase/Chessable **null moves** (`--` / `Z0`) are hidden in the SAN but still pass the turn. Chessable intro dummies are promoted to the mainline before render, so `1. Z0 (1. d4 Z0 2. Nf3 …)` shows the lesson text on the spine |
| `pgn/pgn_opening_tree_panel.dart` | Opening-tree side panel (replaces Game/Analysis + nav bar). Resizable split between `OpeningTreeWidget` and `PgnTreeGamesList`. While the tree is open, `/` searches the games-at-position list (not the full file) and picking a row/`G` number calls `loadGameFromTree` |
| `pgn/pgn_tree_games_list.dart` | Games at the tree cursor: `GameNumberField` + `GameSearchButton` + **Expand all** checkbox. Default expanded rows show title + truncated comment-free mainline PV from this FEN (`mainlineSansAfterFen`). With expand-all off, the blue play arrow previews one line and the title opens the game |
| `pgn_import_dialog.dart` | Compact PGN import `AlertDialog` — file picker pill + paste textarea with live line count via `countPgnGames`; used for repertoire append and create-with-PGN flows. Multi-source contexts use `PgnSourcesPanel` instead |
| `pgn_sources_panel.dart` | **Compact multi-source PGN attachment panel** — replaces the oversized import dialog; supports multiple PGN files/pastes, per-source slicing via `InlineSliceEditor`, embedded `LinesPreviewPanel` |
| `pgn_inline_slice_editor.dart` | **Inline slice editor** — "All Lines" / "Slice" radio + position/header/sequence filters + match count via `computeSliceMatches` + preview panel; accepts optional `fenIndex` for instant position lookups; used inside `PgnSourcesPanel` per source |
| `lines_preview_panel.dart` | **Browseable line list** — fuzzy search, virtualized scrolling, `HoverableMoveChips` per row with `FloatingBoardPreview` on hover; shows full-panel loading spinner while `computing` (replaces stale count + list); used in slice dialog and inline slice editor |
| `hoverable_move_chips.dart` | **Inline move chips with hover board preview** — renders SAN moves as compact chips, computes FEN on hover, triggers `BoardPreviewController.setPreview`; shared by `LinesPreviewPanel`, `LineItemRow`, PGN Viewer |
| `slice/position_filter.dart` | Shared position filter widget (FEN/SAN input + Apply/Clear + "Board position" chip); uses `PositionPreviewIcon` for hover board preview |
| `slice/header_filters.dart` | Shared header filters widget (dynamic field/mode/value rows) |
| `slice/sequence_filter.dart` | Shared move sequence filter widget ([gap]-separated groups) |
| `pgn_slice_dialog.dart` | Slice dataset dialog (position, sequence, header filters) | Default header row starts as Date ≥ (changeable field/mode like other rows); live preview via `LinesPreviewPanel` with hover board; skips recompute when effective filters unchanged, on empty filter rows, or 300ms-debounced header typing; accepts optional `fenIndex` for O(1) position filtering |
| `position_preview_icon.dart` | **Shared hover-preview widget** — eye icon that shows a floating 200×200 board overlay on hover via `bestEffortPositionFromInput`; supports FEN, SAN, and `[gap]`-separated sequences; used by `PositionFilter` and `PgnSliceDialog` |
| `position_analysis_widget.dart` | Weakness UI |
| `engine_weakness_dialog.dart` | Weakness detail dialog |
| `lichess_db_info_icon.dart` | Lichess DB info + OAuth entry point |
| `tactics_control_panel.dart` | Tactics mode shell; warms Maia on page load but leaves Stockfish lazy so an idle home screen holds no engine processes; PGN tab builds a synthetic PGN from the tactic FEN + **trainable line** (`correctLine`) as the **mainline** (`_buildSolutionPgn`) — correct user moves and opponent replies advance through the mainline via `goForward()`; FEN comparison in `onPositionChanged` prevents double-updates; Show Solution midway through a multi-move tactic navigates to current position via `_navigateToSolutionIndex` instead of jumping to end; keyboard: **E** (inline engine), **J** (auto-advance), **A** (analyze/reset), **P**/**N** (prev/skip), Space, arrows, Escape (letter keys suppressed in text fields; digit star-rating shortcuts removed) |
| `tactics/tactics_training_panel.dart` | Puzzle UI; **played-moves trail** shows numbered SAN for moves completed so far in multi-move tactics; **Show Solution** = numbered SAN line + highlight; midway Show Solution navigates to current position (not end); star rating after solve/reveal |
| `tactics/tactics_browse_panel.dart` | Puzzle browser with full filter/sort toolbar: **Mistake-type chips** (toggle `??` blunders, `?` mistakes, `?!` inaccuracies independently), **Status filter** (All / New / Struggling < 50% success), **Min-rating popup** (Any / 2★+ / 3★+ …), **Sort chips** (Newest / Oldest / Worst success / Least reviewed); **Multi-select mode** (checklist icon → checkboxes on rows, Select All, batch Delete with confirmation); per-row: tappable 5-star rating, 1-star rows dimmed; count shows "visible / total tactics" |
| `tactics/tactics_import_panel.dart` | Import tactics from Lichess/Chess.com; **fetch mode toggle** (Recent N games / Since date) with segmented button; date picker for since-date mode; **auto-fetch on startup** checkbox with last-synced label; **Session Settings** dialog (order, mistake-type filter, 1-star toggle) opened from toolbar button beside Browse Tactics; live matching count on Start Session |
| `tactics/puzzle_stats_display.dart` | Puzzle statistics display |
| `tactics/tactics_delayed_tooltip.dart` | Delayed tooltip for puzzle hints |
| `training/training_*.dart` | Training panels (progress, results, settings, board controls, repertoire selector); **Chessable-style move display** shows opponent/user moves with full notation ("White's move 1. e4", "Your move 2. Nf3"), comments inline, and **Next button** (Space shortcut) when opponent moves have comments; **J** toggles learn auto-advance (`learnRequiresClick`) on training screen + settings tooltip; `MoveInputWidget` below board accepts SAN/UCI text input, auto-submits on unique legal-move match (Escape clears & blurs) |
| `study/study_board_pane.dart` | Study board + SAN input; board-shape helpers (`applyStudyBoardShape`) |
| `study/study_side_pane.dart` | Engine bar + compact chapter bar + PGN editor |
| `study/study_picker_bar.dart` | App-bar study switcher with inline rename |
| `study/study_name_dialog.dart` | Shared name prompt for studies and chapters |
| `opponent_list_import_dialog.dart` | Import an opponent-list JSON into Player Analysis |
| `training/training_lines_panel.dart` | **Training Lines browser** — replaces raw `RepertoireLinesBrowser` in the trainer Lines tab; top action bar with **Learn** (new lines) / **Review** (due lines) buttons with count badges; lines grouped into three sections: **Due for Review** (sorted weakest-first), **New** (unseen), **Learned** (collapsed by default, sorted by next due date); each row shows color chip, line name, status label ("Due 2h ago" / "New" / "Next: 3d"), pass/fail ratio, and move mastery bar; tapping a row starts that line |
| `settings/settings_widgets.dart` | Reusable settings tiles |
| `eval_database_settings_panel.dart` | CdbDirect configuration and the download card: start / pause / resume / check / delete, live progress with rate and ETA, the data-directory picker with a **Show in file manager** button, and a collapsed "Download it yourself instead" section carrying the rsync command for the current snapshot. On non-Linux, shows that the dump reader is unavailable instead of hiding the section. |
| `lichess_eval_settings_panel.dart` | The Lichess evaluations card: download, progress through both stages, pause/resume, open folder, free the archive once the store is built, rebuild from a newer file. Separate from the ChessDB panel because that one is gated on the Linux-only native reader while this store is plain Dart |
| `lichess_eval_download_dialog.dart` | States the three numbers the download page does not: 21.7 GB to fetch, ~28 GB needed while building, ~5.9 GB kept. Measures drives against the peak rather than the download size |
| `storage_destination_picker.dart` | The shared "where should this go?" drive list: free space per volume, SSD / hard disk / network label, per-drive "X to spare" or "short by X", and the advisories. Used by both database downloads |
| `eval_database_download_dialog.dart` | Where the dump should go: the exact snapshot size and file count, every drive with free space and an SSD / hard disk / network label, "fits with X to spare" or "short by X" per drive, and blocking / advisory banners (no room, tight fit, spinning disk, network share). Defaults to the fastest drive that actually fits, and never pre-selects one that does not |
| `lichess_db_selector.dart` | Explorer DB/speed/rating filters (widget retained; hidden from settings while Explorer mothballed) |
| `generation/build_progress_display.dart` | Generation progress UI |
| `generation/eval_sources_section.dart` | Eval source picker in generation |

### `lib/utils/`

| File | Purpose |
|------|---------|
| `chess_utils.dart` | UCI/SAN helpers; `isNullMoveSan` / `playSanOrNullMove` treat ChessBase `--`, SCID `Z0`, UCI `0000`, and `@@@@` as a turn pass so same-side continuations stay legal |
| `movetext_builder.dart` | Numbered PGN movetext; omits `--`/`Z0` from the text but still flips the turn so `1. d4 Z0 2. Nf3` serializes as `1. d4 2. Nf3` |
| `fen_utils.dart` | FEN manipulation; `isWhiteToMove(fen)` shared across eval providers, generation, and Maia |
| `best_effort_position.dart` | Best-effort board builder from FEN, SAN, or `[gap]`-separated move sequences; handles castling (O-O/O-O-O) by manually repositioning king+rook; produces a renderable `Position` even for illegal placements (used by `PositionPreviewIcon`) |
| `pgn_utils.dart` | PGN formatting, event title extraction |
| `pgn_comment_utils.dart` | Comment filtering, NAG constants, movetext serialization, and Chessable rich-comment parser (`parseRichComment`, `hasChessableFormatting`). Handles `@@HeaderStart@@`, `@@StartBlockQuote@@`, `@@StartBracket@@`, `@@StartSquare@@`, `@@StartFEN@@`, `@@LinkStart@@` markers and double-space paragraph breaks. |
| `coverage_helpers.dart` | Coverage UI helpers |
| `lines_filter_helpers.dart` | Line filter/sort/group (`filterSortAndGroupLines`, `getLineGroupName`); typed `LineSortBy` and `LineMetricsFilter` enums (replaces string sort/filter params) |
| `ease_utils.dart` | Ease display formatting |
| `eval_constants.dart` | Eval display thresholds |
| `chesscom_lichess_elo.dart` | Chess.com blitz → Lichess blitz Elo table + `chessComBlitzToLichessBlitz()` for Maia (tactics Chess.com import) |
| `app_messages.dart` | Snackbar helpers |
| `keyboard_shortcut_utils.dart` | Shared `isTextInputFocused()`, `hasNoLetterModifiers`, `isPrimaryModifierPressed` for keyboard shortcut guards |
| `file_text_reader.dart` | UTF-8 file read with Latin-1 fallback (`decodeTextBytes`, `decodeTextBytesDetailed`, sync/async helpers) for PGN / text imports |
| `system_info.dart` | CPU core count (native/stub) |

### `lib/theme/`

| File | Purpose |
|------|---------|
| `app_colors.dart` | Dark theme palette, semantic colors; canonical `success`/`danger`/`warning` with eval/analysis aliases (`evalPositive`, `evalNegative`, `difficulty`). PGN movetext tokens (`pgnMove`, `pgnMoveNumber`, `pgnComment`, `pgnVariation`) are a near-white hierarchy — sidelines are distinguished by structure, not mint/teal hue. |
| `app_text_styles.dart` | Shared text roles (`body`, `muted`, `caption`, `mono`, `title`, …) built from `AppColors` / near-white ink. Wired into `ThemeData.textTheme` in `main.dart`. Prefer these over ad-hoc `Colors.grey` / hard-coded sizes. |
| `pgn_text_styles.dart` | Movetext domain styles (`move`, `moveNumber`, `comment` upright, `variation`, `branchChip`, …) on top of `AppColors` + `AppTextStyles`. Single knobs file for PGN viewer/editor look. Ephemeral (scratch/solitaire) moves stay italic. |

**Style convention:** new and touched UI should use `AppColors` / `AppTextStyles` / `theme.textTheme` (and domain packs like `PgnTextStyles`) instead of inline `Colors.grey[n]` or one-off `TextStyle(fontSize: …)`. Gradual migration of legacy call sites is tracked in FUTURE_FEATURES.

---

## Test coverage map

| Test file | Verifies |
|-----------|----------|
| `test/core/board_preview_controller_test.dart` | Preview debounce, clear |
| `test/core/generation_session_controller_test.dart` | Engine-free surface of `GenerationSessionController`: initial state, `onTreeBuilt`/`clearTree` bundle lifecycle, resume-mismatch refusal, `GenerationProgress` throttling, idle guards, dispose safety |
| `test/core/repertoire_controller_test.dart` | Controller navigation (tree-path model), line sync, invariants |
| `test/core/viewer_opening_tree_test.dart` | PGN-viewer opening tree: re-enter restores the tree line after a game remount; first open syncs to current FEN; app-bar back only after a games-at-position click |
| `test/core/viewer_game_model_test.dart` | Viewer load/nav; Chessable dummy intro promoted onto the mainline |
| `test/core/pgn/pgn_dummy_mainline_test.dart` | `promoteNullMoveDummyMainline` splice + idempotence |
| `test/core/pgn/pgn_variation_extractor_test.dart` | Sideline extraction including Z0 passes (without dummy promotion) |
| `test/core/pgn_viewer_controller_test.dart` | Game index nav, close-file reset, tree-landing FEN cleared on nextGame |
| `test/models/move_tree_test.dart` | MoveTree: parse PGN, round-trip, addMove, navigation, variations, TreePath equality |
| `test/core/repertoire_writer_test.dart` | Add move, PGN append |
| `test/core/repertoire_writer_undo_test.dart` | Undo stack |
| `test/features/browse/candidate_service_test.dart` | Candidate merge/sort |
| `test/features/coverage/coverage_suggestion_service_test.dart` | Suggestions, coherence bonus |
| `test/features/coverage/coverage_result_test.dart` | `CoverageResult.findNextGap` / `findBiggestGap` gap ordering |
| `test/features/traps/trap_index_service_test.dart` | FEN index, line traps |
| `test/features/traps/trap_navigation_buttons_test.dart` | Trap jump UI |
| `test/features/traps/trap_walkthrough_test.dart` | Walkthrough navigation |
| `test/features/master_games/twic_repertoire_scan_test.dart` | TWIC games vs the designated books: tested-vs-past-prep, both colours, ranking, cancellation |
| `test/features/master_games/master_games_browser_controller_test.dart` | Search, filtering, the repertoire view, stale-scan invalidation, PGN export |
| `test/features/master_games/master_games_browser_test.dart` | The browser UI against a real database: rows, filtering, selection, the repertoire verdicts, narrow-window layout |
| `test/services/master_games/master_games_query_test.dart` | Browse filters, as clauses and against a real database |
| `test/services/eval/lichess_eval_line_test.dart` | Lichess JSONL parsing: deepest eval, White-relative signs, move packing |
| `test/services/eval/lichess_eval_store_test.dart` | Import, sort, dedupe, resume, and lookup of the Lichess store |
| `test/services/eval/lichess_eval_controller_test.dart` | Download → import → enable, resume from a partial file, delete paths |
| `test/services/eval/lichess_eval_source_test.dart` | Size/date probe and its offline fallback |
| `test/services/eval/zstd_stream_test.dart` | Both zstd backends, and truncation detection |
| `test/features/holes/hole_hunt_config_test.dart` | `HoleHuntConfig` defaults/serialization |
| `test/features/holes/hole_finding_json_test.dart` | Hole finding JSON round-trip |
| `test/features/holes/exploit_ranking_test.dart` | Exploit-score ranking/capping |
| `test/features/holes/hole_walk_probability_test.dart` | Reach-probability propagation in the attacker walk |
| `test/features/engine_tournament/engine_game_runner_test.dart` | The arbiter, against scripted engines: mate, threefold, fifty-move, draw/resign adjudication, move ceiling, illegal move, engine death, per-move and clock forfeits, PGN numbering from a FEN start |
| `test/features/engine_tournament/crosstable_builder_test.dart` | Points from both sides, head-to-head order, SB tiebreak, Elo/LOS edge cases |
| `test/features/engine_tournament/tournament_summary_test.dart` | History-rail wording: match score and leader, level match, field leader while running, self-match name numbering, day grouping and run duration |
| `test/features/engine_tournament/tournament_schedule_test.dart` | Colour alternation, round-major order, round robin vs gauntlet |
| `test/features/engine_tournament/tournament_store_test.dart` | Slug allocation, JSON round trip, corrupt-file tolerance, and that `games.pgn` reparses as the viewer's collection |
| `test/features/engine_tournament/engine_verification_test.dart` | Real-process gate: missing/dir/non-executable, silent binary, UCI-but-illegal-move, and a passing toy engine |
| `test/features/engine_tournament/time_control_test.dart` | Labels, PGN `TimeControl` tags, hang-guard ceilings, JSON round trip |
| `test/features/engine_tournament/uci_score_test.dart` | Mate-to-centipawn collapsing (including `mate 0`), no-move answers, `go` command spelling |
| `test/features/engine_tournament/crosstable_view_test.dart` | Crosstable and games-table rendering, empty states, row click carries the game index |
| `test/features/engine_tournament/engine_tournament_screen_test.dart` | Screen boots empty and populated, a games-row click hands the viewer the match PGN parked on that game, and an `OpenEngineTournament` handoff selects the named tournament (or leaves the screen intact and says so when it is gone); the history rail's score line and its filter |
| `test/features/engine_tournament/tournament_open_request_test.dart` | The request file the MCP side writes and the app consumes: round trip, read-and-clear, malformed and stale requests, and the watcher's already-waiting / written-live / stopped paths |
| `test/features/engine_tournament/engine_registry_test.dart` | Bundled-first ordering, bundled settings persisted without its path, update/remove, corrupt-file tolerance |
| `test/features/eval_tree/eval_tree_controller_test.dart` | Graph controller |
| `test/features/eval_tree/eval_tree_tab_test.dart` | Tab widget |
| `test/features/eval_tree/eval_tree_line_metrics_test.dart` | Line metrics |
| `test/features/eval_tree/eval_tree_layout_engine_test.dart` | Layout performance |
| `test/features/eval_tree/eval_tree_snapshot_adapter_test.dart` | Snapshot adapter |
| `test/features/eval_tree/tree_serialization_eval_tree_test.dart` | Tree JSON round-trip |
| `test/models/opening_tree_test.dart` | Opening tree mutations; `updateStats(null)` frequency without WDL; one-ply transposition (1.d4 c5 2.e3 shows Nf6 when the book is 1.d4 Nf6 2.e3 c5) |
| `test/models/pgn_game_entry_test.dart` | Course `"Chapter — Line"` labels vs player `"White vs Black"` |
| `test/models/repertoire_metadata_test.dart` | `RepertoireMetadata` parsing, equality, `fromMap`/`toMap` |
| `test/models/engine_settings_test.dart` | Settings persistence |
| `test/services/coherence_service_test.dart` | Coherence compute |
| `test/services/engine_lifecycle_test.dart` | State transitions, notify-count guards, full lifecycle cycle |
| `test/services/engine/stockfish_bundle_test.dart` | Host lock key + largest-member extract from zip/tar |
| `test/widgets/unified_engine_pane_lifecycle_test.dart` | Engine pane ↔ lifecycle feedback-loop regression via pane-coupling harness |
| `test/services/expectimax_line_service_test.dart` | Line following / MultiPV |
| `test/services/fp_growth_test.dart` | FP-Growth mining |
| `test/services/generation/tree_my_ease_test.dart` | myEase computation |
| `test/services/generation/repertoire_selector_test.dart` | Expectimax/engine selection, idempotent marking |
| `test/services/pgn_parsing_service_test.dart` | PGN parsing; `mainlineSansAfterFen` remaining SAN |
| `test/services/repertoire_service_test.dart` | Repertoire I/O |
| `test/services/trap_extractor_test.dart` | Trap extraction |
| `test/services/tactics/tactics_session_controller_test.dart` | Tactics session |
| `test/services/training/training_session_controller_test.dart` | Repertoire trainer: `loadRepertoire` happy/error paths, due-queue ordering, `setIdle`, `isCorrectUserMove` SAN/UCI edge cases, drill/learn/replay phase transitions, session statistics, move-progress streaks, dispose safety (in-memory service fakes) |
| `test/services/games_repertoire/games_draft_controller_test.dart` | `GamesDraftController`: build happy path + classification, building flag/notify lifecycle, no-games and fetch-failure errors, start-position restriction, re-entrancy no-op, `close`, dispose safety |
| `test/services/tactics_engine_test.dart` | `checkMoveAtIndex`, SAN normalization, mate-in-1 from mid-game FEN; `buildTrainableLine` fallback + Maia agree/disagree/low-confidence paths with mock evaluator |
| `test/services/eval/test_*.dart` | Eval provider chain (helpers) |
| `test/widgets/layout/edit_context_zone_test.dart` | Context zone multi-panel chips |
| `test/widgets/position_analysis_widget_test.dart` | Analysis widget |
| `test/widgets/pgn_tree_games_list_test.dart` | Opening-tree games list: expanded PV, expand-all off preview vs open |
| `test/screens/main_screen_test.dart` | Main screen smoke |
| `test/widget_test.dart` | App smoke |
| `test/utils/lines_filter_helpers_test.dart` | `filterSortAndGroupLines`, `LineSortBy`/`LineMetricsFilter`, grouping, sort invariants |
| `test/utils/chesscom_lichess_elo_test.dart` | Chess.com→Lichess blitz anchor, interpolation, clamp |

**Gaps:** Few widget/integration tests for full `RepertoireScreen` layout, generate mode, or settings screen.

---

## External & non-Flutter components

| Path | Role |
|------|------|
| `tree_builder/` | C expectimax tree builder (`--eval-depth` default 14), CdbDirect reader; MultiPV line-0 PV reply stash + opponent injection (`engine_injected`, PGN `{engine-injected}`). **Build modes** (`--build-mode` in `tree.h`): `stockfish-expectimax` (default interleaved BFS), `maia-db-explore`, `db-explorer`, `trap-finder` (unimplemented). **SQLite cache** (`database.c`): explorer/eval/Maia/repertoire tables plus `build_metadata`. **`cli_args` persistence:** each run calls `save_config_to_db()` → `rdb_save_cli_config()` with the effective CLI as JSON (color, depth, build mode, PGN paths, eval sources, presets, etc.). **`--resume`:** `load_config_from_db()` in `main.c` restores from `cli_args`; `CliExplicit` records flags passed on the command line — saved values apply only for options *not* explicitly set (e.g. `--resume --threads 8` overrides stored thread count). Restores `-c` when omitted; DBs without `cli_args` fail with a clear error. **`build_now` is sticky:** `save_config_to_db()` persists it and `load_config_from_db()` re-applies it whenever the CLI passes neither `--build-now` nor `--skip-build` (`main.c` ~L564), so once a DB has seen one `--build-now`, every later `--resume` silently skips building. Pass the original flags explicitly instead of `--resume` if you need to alternate between scoring and building. **`--resume` skips** the legacy `check_build_metadata` color/ratings/speeds gate; without `--resume`, reopening an existing `.db` still **refuses** on mismatch (prints stored vs current settings and example `--resume` / fresh / `--input-db` commands). Legacy DBs with data but no metadata get a one-time note and recorded settings. **`--input-db` / `-I`:** copy eval/explorer cache tables (`evaluations`, `explorer_positions`/`explorer_moves`, `multipv_cache`, `maia_cache`) from another DB into a new/empty target via `rdb_import_cache_from` (ATTACH + INSERT OR IGNORE); not `repertoire_moves`. **Threads:** `-t` / `--threads` default is `default_thread_count()` — half of `_SC_NPROCESSORS_ONLN`, minimum 1 (not a fixed 4). **Build progress (TTY):** live line via `progress_line.c` — `[Depth N] X new + Y transpositions | total | rate/min | ~ETA`; depth-complete line uses unique node count at that ply (`g_nodes_created_at_depth`). **Tree resume** (stockfish-expectimax / maia-db-explore): if `<name>.tree.json` exists and `build_complete` is false, stage 1 continues BFS from unexplored frontier leaves (`resume_prepare_frontier` in `tree.c`); only `build_complete: true` skips building. SIGINT saves partial trees; nodes interrupted mid-expansion stay `explored: false` and are retried. **Engine pool:** Stockfish children call `setsid()` (Ctrl+C does not kill engines); `engine_pool_request_stop` from the signal handler sets `shutting_down` and wakes waiters so batch/single eval exits without spamming "all Stockfish engines are dead". `--build-now` / `--skip-build` still export without expanding. **DB explorer:** `--build-mode db-explorer --pgn <file>` (repeatable) → `pgn_freq.c` replays each game from the standard start position; when `--fen` or `--moves` defines a target, counting starts only after the canonical 4-field FEN matches (not SAN-prefix string matching). `--min-elo` (default 2100) skips games where both `[WhiteElo]` and `[BlackElo]` are present and below threshold; missing or partial Elo tags are kept. Games that never reach the target are skipped (aggregate log). Parallel per-file parse when multiple PGNs; binary cache `<name>.freq.bin` with manifest incl. `min_elo`, `--no-freq-cache` to force reparse; OOM aborts parse → `tree_build_from_freqmap` → deferred Stockfish pool start → `tree_enrich_evals` (project DB → external chain → Stockfish; abort if >50% nodes still unevaluated, else warn) → expectimax + PGN export. `fen_map_put` / PGN hash tables propagate resize OOM. Opponent `move_probability` = count/reach; our-move children = 1.0; `tree_recalculate_probabilities` chains cumulative probability. See `tree_builder/ALGORITHM.md`. |
| `python/twic-position-finder/` | TWIC Position Finder — the live site/API at `api.chessautoprep.com` (FastAPI + Astro frontend, weekly ingest cron, lesson booking). Dashboard lists matched games per TWIC issue with a Lichess link on each game. Independent of the Flutter app. |
| `tools/fetch_assets.py` | Stdlib fetch of pinned Stockfish (`sf_18`) into `assets/executables/*.gz` (gitignored). Default is **host OS/arch only**. Linux/Windows CMake and macOS Assemble invoke it when the `.gz` is missing; Release CI always `--only`s the job’s target. In-app fallback is `StockfishBundle`. Checksums in `tools/assets.lock.json`. |
| `tools/mcp/chess_prep/` | Local MCP server (`python3 tools/mcp/chess_prep/__main__.py`). **Opponent prep** (zero extra deps): directory, USCF, roster, Swiss sim, `opponents_export`. **PGN opening tree** (`pgn_open` / `pgn_position` / `pgn_walk` / `pgn_eval` / `pgn_audit`): FEN-keyed graph so transpositions merge; needs `python-chess` (`pip install -r tools/mcp/requirements.txt`) and Stockfish for eval. **ChessDB** (`chessdb.py`: `chessdb_query`, and the reply-gap half of `pgn_audit`): chessdb.cn `queryall` over `urllib`, cached per position, fetch injectable; the one source that rates a move nobody plays. **Engine tournaments** (`tournament_run` / `_status` / `_list` / `_crosstable` / `_games` / `_game_pgn` / `_stop` / `_open` / `_engines` / `_add_engine`): starts a match from any FEN and opens the app on it. Needs the Flutter SDK's `dart` (`CHESS_PREP_DART` overrides) because it shells out to `tools/run_engine_tournament.dart` rather than re-implementing the chess or the standings maths. `tournament_run` returns as soon as the runner prints its `TOURNAMENT {…}` handshake line and leaves the games playing detached, recording the pid in `run.json` so `tournament_stop` can SIGINT it. **Expectimax runs** (`expectimax_run` / `_result` / `_status` / `_list` / `_stop` / `_resume`): builds a Maia+Stockfish expectimax tree via `tree_builder/` and returns the root ranking — every candidate with its practical win probability, its eval, and how much of the tree it got. Takes a move list or FEN; refuses a `color` that is not the side to move (a line ending on Black's move is White to move) rather than scoring the wrong side. `prepare_toolchain()` compiles `tree_builder` on first use, unpacks `assets/executables/stockfish-*.gz`, and symlinks `libonnxruntime`/`libcurl` out of the pub cache and `/usr/lib64` into `CHESS_PREP_EXPECTIMAX_TOOLCHAIN` — Fedora ships neither `-devel` symlink. Runs are directories under `CHESS_PREP_EXPECTIMAX_DIR` (default `Documents/expectimax_runs`). Never passes `--resume` (see the `tree_builder/` row); it re-runs the `build_argv` stored in `run.json` instead, adding `--build-now` to score a partial tree. `_pid_alive` treats zombies as dead — the server is the builder's parent, so an unreaped child otherwise reads as running for ever. The server is registered for Claude Code in `.mcp.json` at the repo root. See [`OPPONENT_PREP.md`](OPPONENT_PREP.md). Tests: `python3 tools/mcp/test_chess_prep.py`, `python3 tools/mcp/test_opening_tree.py`, `python3 tools/mcp/test_chessdb.py`, `python3 tools/mcp/test_engine_tournament.py`, `python3 tools/mcp/test_expectimax.py`. |
| `packages/cdbdirect_flutter_libs/` | Native ChessDB bindings |
| `scripts/` | One-off data/analysis scripts (chess.com titled-player stats, USCF mapping, epub/pdf game extraction) |

---

## Audit gaps

Areas where behavior could not be fully determined without runtime testing:

1. **Maia native availability** — platform matrix for real vs stub inference.
2. **Cross-platform Stockfish** — first-launch extract from the bundled `.gz` is implemented (`process_connection.dart`); Release CI fetches the platform engine before `flutter build`. End-to-end extract on a clean Windows/macOS install is still a runtime check.
3. **Lichess OAuth** — full flow on all desktop platforms (callback server binding).
4. **Compact vs wide layout** — all breakpoint transitions and state preservation paths in `RepertoireScreen` (complex conditional tree).
5. **Training FSRS parameters** — exact scheduling algorithm vs documented FSRS.

**Recently closed:** generation cancel now UCI-stops in-flight evals (`StockfishPool.stopAll` + `forEachParallel` abort); dead workers are dropped and respawned up to the last `ensureWorkers` target. `loadRepertoire` is epoch-guarded like `StudyController.openStudy`. Board annotation types live in `lib/models/board_annotation.dart` so utils/services no longer import widgets. `FenMap` is frozen when published on `GeneratedRepertoire`. Transposition cycle checks share `isTranspositionCycle` / `enterFenPath` in `fen_map.dart`. Settings persist is fire-and-forget via `EngineSettings._persist` / `TrainingSettings.saveSoon`; eval cache writes from search pipelines use `EvalCache.putEvalCpWhiteSoon`. Training review headers are awaited after FSRS updates. `copyToClipboard` in `app_messages.dart` is the shared clipboard helper. `MainScreen` suspends the engine on `paused`/`hidden`/`detached` and on leaving interactive-engine modes (`AppMode.usesInteractiveEngine`); `resume` restores it on `resumed` and when re-entering those modes. Findings/report dismiss menus share `showAnchorMenu`. Single-file picks use `FilePicker.pickFile`; multi-file picks use `pickFiles` without deprecated `withData`/`withReadStream`/`allowMultiple`.

For planned work not yet in code, see **[`docs/FUTURE_FEATURES.md`](FUTURE_FEATURES.md)** (backlog only — do not treat as current behavior).
