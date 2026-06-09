# Component Map

**Source of truth for what is currently implemented** in the Chess Auto Prep Flutter/Dart app. Use this document to audit behavior, trace data flows, and plan fixes.

| Document | Purpose |
|----------|---------|
| **This file** | Current implementation — screens, services, widgets, tests |
| [`FUTURE_FEATURES.md`](FUTURE_FEATURES.md) | Backlog only — not yet built or incomplete |
| [`ALGORITHM.md`](ALGORITHM.md) | Flutter expectimax / tree-generation pipeline |
| [`../tree_builder/ALGORITHM.md`](../tree_builder/ALGORITHM.md) | C `tree_builder` CLI pipeline (incl. db-explorer) |
| [`tree-display-architecture.md`](tree-display-architecture.md) | Eval-tree graph performance principles |

Last reviewed against `lib/` and `tree_builder/` (June 2026). When you change code, update the matching section here.

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

**Repertoire navigation model:** `RepertoireController` owns a `MoveTree` (editable PGN tree) and a `TreePath` cursor. All navigation goes through `controller.jump(path)`. The PGN editor (`InteractivePgnEditor`) is a pure view that receives `tree` + `currentPath` as props and fires `onJump` / `onCommentChanged` / `onDelete` / `onPromote` / `onMakeMainLine` callbacks. No secondary state, no `addPostFrameCallback` sync.

**PGN context menu (right-click):** Uses Flutter's built-in `showMenu` API (Overlay-based, avoids Stack/Positioned layout issues). Menu items: Add Comment (focuses comment TextField), Promote Variation (non-mainline only), Make Main Line (recursive promote to root, non-mainline only), Duplicate Line (copies full line to clipboard), Copy PGN from Here, Delete from Here.

**Chess logic:** `dartchess` for rules/FEN; `flutter_chess_board` for display.

---

## Entry points & navigation

### Application bootstrap

```
main.dart
  ├─ EngineSettings.loadFromPrefs()
  ├─ EvalDatabaseSettings.instance.load()
  ├─ EvalCache.instance.init()  // SQLite eval + Maia cache ready for interactive writes
  ├─ EngineLifecycle.loadPersistedState()  // marks engine idle (no process spawn); workers created lazily on first eval
  ├─ BrowserExtensionServerFactory.start()  (desktop IO only)
  ├─ DefaultPgnService.ensureExtracted()
  └─ ChessAutoPrepApp → MainScreen
```

| File | Purpose |
|------|---------|
| `lib/main.dart` | `WidgetsFlutterBinding`, window manager, settings init, `EvalCache.instance.init()`, `MaterialApp` dark theme, `AppState` provider |
| `lib/core/app_state.dart` | Global mode enum, usernames, loaded games, builder↔trainer pending path handoff |
| `lib/screens/main_screen.dart` | `IndexedStack` of mode views; disposes engine when leaving repertoire |

### App modes (`AppMode`)

| Mode | Screen | Primary use |
|------|--------|-------------|
| `tactics` | Embedded `_TacticsModeView` | Tactics from user's own games (Stockfish analysis + Maia line extension) |
| `positionAnalysis` | `AnalysisScreen` | Weak positions from user games |
| `repertoire` | `RepertoireScreen` | Opening repertoire builder |
| `repertoireTrainer` | `RepertoireTrainingScreen` | Spaced repetition training |
| `pgnViewer` | `PgnViewerScreen` | Standalone game PGN + inline engine |

Mode switcher: `widgets/app_mode_menu_button.dart`.

### Repertoire screen layout (right pane + bottom pane, redesigned June 2026)

Design principles: **Right pane** = current-position analysis (engine, expectimax, PGN). **Bottom pane** = output workspace (findings, jobs, lines) — collapsed by default, VS Code-style resizable/collapsible with tabs. **Dialogs** = configuration only (generation, audit). Board and right pane stay spatially stable when the bottom pane opens.

```
RepertoireScreen (composition root — wires controllers to widgets)
  ├─ RepertoireController (MoveTree + TreePath cursor, opening tree, lines)
  ├─ GenerationSessionController (TreeBuildService, CoherenceService, tree/config/fenMap, job)
  ├─ AuditSessionController (RepertoireAuditService, result/liveFindings/progress, persistence, job)
  ├─ CoverageController (CoverageResult, progress)
  ├─ BoardPreviewController (hover preview FEN)
  ├─ JobManager (background generation/audit tracking)
  ├─ TrapIndexService
  │
  ├─ Wide (≥ kCompactBreakpoint):
  │     Column:
  │       Expanded Row: Board (square, annotated) | ToolsColumn (right pane)
  │         ToolsColumn (unified, no tabs):
  │           InlineEngineBar (toggleable, shortcut E)
  │           InlineExpectimaxBar (toggleable, shortcut X)
  │           PgnWithAnalysisPane (expanded, always visible)
  │           NavControls (|< < > >| + "+" gen-from-here + Flip)
  │       BottomPane (collapsed by default, full width):
  │         Tabs: Findings (auto-scaled, dismissable) | Jobs | Lines
  │         Drag-resizable top edge, min 120px, max 60% screen
  │
  ├─ Compact (<960px):
  │     Column: Board (flex 4) | ToolsColumn (flex 5) | BottomPane
  │
  ├─ Dialogs (opened from toolbar/shortcuts):
  │     GenerationConfigDialog (sparkles / G) — full generation config
  │     AuditConfigDialog (policy / A) — audit config + start
  │
  ├─ RepertoireStatusBar (clickable badges → toggle bottom pane tabs)
  └─ optional TrapWalkthrough overlay
```

**Key files:**
- `lib/core/generation_session_controller.dart` — owns `TreeBuildService` + `CoherenceService` + tree output; pause/resume/cancel survive dialog disposal
- `lib/core/audit_session_controller.dart` — owns `RepertoireAuditService` + audit state + persistence; pause/resume/cancel from any widget
- `lib/core/coverage_controller.dart` — owns coverage result + progress state
- `lib/widgets/layout/bottom_pane.dart` — resizable, collapsible, tabbed bottom pane (Findings/Jobs/Lines)
- `lib/widgets/engine/inline_expectimax_bar.dart` — compact toggleable expectimax PV display
- `lib/widgets/generation_config_dialog.dart` — modal dialog wrapping RepertoireGenerationTab; pops on generation start via controller listener
- `lib/features/audit/widgets/audit_config_dialog.dart` — modal dialog wrapping AuditConfigPanel
- `lib/features/audit/widgets/audit_findings_panel.dart` — findings list with category filter chips, auto-scaled to ~20 findings, bulk dismiss, keyboard navigation, and interrupted-audit resume banner
- `lib/features/audit/services/audit_persistence.dart` — centralized save/load for audit snapshots (result + config + resume state)
- `lib/widgets/layout/jobs_panel.dart` — jobs content for the Jobs tab
- `lib/widgets/repertoire_lines_browser.dart` — line search/filter/group browser for the Lines tab
- `lib/widgets/layout/board_zone.dart` — board wrapper, passes annotations
- `lib/widgets/chess_board_widget.dart` — board + annotation overlay (arrows, circles, labels)
- `lib/services/jobs/repertoire_job.dart` — background job manager; `RepertoireJob` includes `configSnapshot` (serialized `AuditConfig.toMap()`) for audit jobs

**Bottom pane (VS Code-style):** Collapsed by default (zero height). Auto-opens to Findings tab when audit starts, Jobs tab when generation starts. Tabs show badge counts. Resizable by dragging the top edge (min 120px, max 60% of screen height). Collapse via close button, `Escape` key, or double-click the drag handle.

**Findings tab UX:** Category filter chips (Blunders/Inaccuracies/Missing/Weak/Dead Ends) with counts — multi-select toggles. Auto-scales to show ~20 highest-probability findings at a time; as findings are dismissed, lower-probability ones surface. Bulk dismiss via right-click context menu: dismiss similar, dismiss at depth, dismiss all of type. Keyboard: N/P or arrows to cycle findings (board navigates within full repertoire tree), D to dismiss current. Selected finding is highlighted. "X of N" counter in the status bar. Status bar shows "20 of 150 findings" when auto-scaled. Timestamp shows when saved results were generated.

**Lines tab:** Reconnects the existing `RepertoireLinesBrowser` with full search, filter, sort, group, rename, and coverage metrics.

**"Generate from here" button:** In the nav controls bar, a `+` icon button opens the generation dialog pre-seeded with the current position FEN.

**Board annotations:** `BoardAnnotation` model with `AnnotationBrush` (green/red/blue/yellow/purple). `_AnnotationPainter` renders arrows (shaft + arrowhead) and circles on a `CustomPaint` overlay above pieces.

**Keyboard shortcuts:**
- `E` — toggle engine bar
- `X` — toggle expectimax bar
- `G` — open generation config dialog
- `A` — smart audit: opens findings (if running/results exist) or config dialog (if fresh)
- `1` — toggle bottom pane → Jobs tab
- `2` — toggle bottom pane → Findings tab
- `3` — toggle bottom pane → Lines tab
- `Escape` — collapse bottom pane
- `N`/`P` — next/prev finding (when findings tab focused)
- `D` — dismiss current finding (when findings tab focused)
- `F` — flip board, arrows — navigate moves

Breakpoints: `constants/ui_breakpoints.dart` (`kCompactBreakpoint=960`, `kWideBreakpoint=1100`).

Settings: gear → `screens/settings_screen.dart` (from repertoire toolbar).

---

## Major data flows

### Repertoire load & edit

```
RepertoireSelectionScreen
  → RepertoireService.loadRepertoire(path)
  → RepertoireController (MoveTree + TreePath, OpeningTree, RepertoireLine list)
  → InteractivePgnEditor (pure view: tree + path props, onJump callback)
  → OpeningTreeWidget (unchanged — read-only statistics tree)
  → disk writes via RepertoireService / RepertoireWriter (browse adds)
```

### Tree generation (expectimax pipeline)

```
GenerationSessionController (owns TreeBuildService + CoherenceService)
  ← RepertoireGenerationTab reports lifecycle (markGenerating, onTreeBuilt, onTreeReset)
  ← Screen/JobsPanel/BoardZone call pauseBuild/resumeBuild/cancelBuild directly
  ← Dialog pops via controller listener (controller survives dialog disposal)

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

**Build modes** (enum `BuildMode` in `generation_config.dart`):
- `stockfishExpectimax` — default; Stockfish MultiPV + Maia opponent (Lichess Explorer mothballed)
- `maiaDbExplore` — Maia moves, DB evals only, no engine at build time
- `dbExplorer` — PGN file parsing → frequency map → BFS tree → eval enrichment
- `trapFinder` — not yet implemented

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

AuditConfigDialog (toolbar button or shortcut A)
  → Wraps AuditConfigPanel in a modal dialog
  → Config: source toggles (Stockfish/Maia; Lichess DB mothballed, `useLichessDb` defaults false), thresholds, scope
  → Start button closes dialog, task runs in background
  → Bottom pane auto-opens to Findings tab
  → RepertoireAuditService.audit(openingTree, config)
       BFS: our moves → StockfishPool.discoverMoves (eval loss check)
       BFS: opponent turns → MaiaFactory (gap check); ProbabilityService mothballed (no Lichess API)
       BFS: leaves → dead-end detection
       Cumulative probability: product of opponent move frequencies from root
  → Callbacks: controller.onAuditingChanged, .onResultReady, .onLiveFinding

AuditFindingsPanel (bottom pane Findings tab, shortcut 2)
  → Receives AuditResult from controller; `interruptedSnapshot` + resume banner when incomplete audit detected
  → onResumeAudit / onStartFreshAudit → controller.launchResume / startFresh
  → FindingsDisplayFilter: auto-scales when >100 findings (drops info → raises reach floor)
  → Summary card: soundness %, coverage %, clickable type badges
  → Filter bar: severity chips (Critical/Warning/Info), "X of N" counter
  → Findings list: sort (severity/reach/ply), filter by type
  → Bulk dismiss: right-click → dismiss similar / at depth / all of type
  → Keyboard: N/P cycle findings (board navigates), D dismiss + advance
  → Selected finding highlighted, board arrows shown
  → Dismissed section: count + "Restore all" at bottom
  → Finding tap → RepertoireController.loadMoveSequence()

Controller state:
  → AuditResult + liveFindings + interruptedSnapshot + progress
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
  → FPGrowthMiner → clusters + lineCoherence scores
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
OnTheFlyExpectimaxService (expectimax dock)
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
PgnViewerScreen._pickFile → `FilePicker.pickFiles` (Linux: **XDG Desktop Portal only** in `file_picker` ≥10.3 — D-Bus `org.freedesktop.portal.FileChooser`; no zenity/kdialog fallback) → PgnViewerController.loadFile(path)
  → StorageService.fileExists / readFile (absolute paths as-is; relative → app documents)
  → compute(parseMultiGamePgn) → allGames / filteredGames
  → on failure: controller.errorMessage + debugPrint; screen shows SnackBar + inline error in empty state
  → on success: recent-files prefs, optional saved slice restore, loadCurrentGame
  → game change (N/P, dropdown, slice, sort): `loadCurrentGame` resets `currentPosition` to start; `PgnViewerWidget._loadGame` defers `onPositionChanged` to a post-frame callback (avoids setState-during-build when called from `didUpdateWidget`)
Game nav bar (when games loaded): Copy PGN → `filteredGames[currentGameIndex].pgnText` → `Clipboard.setData` + `AppMessages.pgnCopied` snackbar
Analysis tab / inline engine: tap best line or Maia move → `PgnViewerWidgetController.goToMainLineIndex(branchPly)` + `addEphemeralMove` (new RAV per distinct line; prior RAVs kept)
Clear annotations → nav bar `onClearAnnotations` or PGN variation context menu / Escape / Home → `clearEphemeralMoves` (removes ephemeral nodes only)
```

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

The `PgnSourcesPanel` replaces the monolithic `pgn_import_dialog.dart` bottom sheet
for contexts that manage multiple PGN sources (generation, batch import). Architecture:

```
PgnSourcesPanel (lib/widgets/pgn_sources_panel.dart)
  ├─ List<PgnSource> — each with name, filePath/paste, color, sliceConfig
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
| `engine_defaults.dart` | Defaults: interactive analysis depth (`kDefaultDepth` 15), **tree generation eval depth** (`kDefaultGenerationEvalDepth` 14), on-the-fly expectimax eval depth (`kDefaultExpEvalDepth` 12), MultiPV, browser extension port | — |
| `ui_breakpoints.dart` | Responsive layout width constants | — |

### `lib/core/`

| File | Purpose | Public API / state |
|------|---------|-------------------|
| `app_state.dart` | Global app mode, usernames, games list | `setMode`, `switchToBuilder/Trainer`, `notifyListeners` |
| `generation_session_controller.dart` | **Generation session state** — owns `TreeBuildService` + `CoherenceService`; pause/resume/cancel survive dialog disposal; holds generated tree, config, fenMap, job reference | `pauseBuild`, `resumeBuild`, `cancelBuild`, `markGenerating`, `onTreeBuilt`, `onTreeReset`, `clearTree` |
| `audit_session_controller.dart` | **Audit session state** — owns `RepertoireAuditService` + result, live findings, progress, config, interrupted snapshot; handles persistence via `AuditPersistence` | `pause`, `resume`, `cancel`, `saveProgress`, `tryRestore`, `launchResume`, `startFresh`, `onAuditingChanged`, `onResultReady`, `onLiveFinding`, `onProgress` |
| `coverage_controller.dart` | **Coverage session state** — result, progress, running flag | `calculate`, `clear` |
| `board_preview_controller.dart` | Debounced hover FEN overlay for board | `setPreview`, `clearPreview`, `previewFen`, `isPreview` |
| `navigation_stack.dart` | Breadcrumb stack for repertoire navigation | push/pop/jump |
| `pgn_viewer_controller.dart` | PGN viewer file load, game index & navigation | `loadFile`, `errorMessage`, slice/export/tree APIs; `detectProtagonist`, `detectBothPlayers` (two-player matchup detection); `loadCurrentGame` resets board to game start (`currentPosition`, engine-line highlight); `applySlice` no-ops when indices + `SliceConfig` unchanged (skips opening-tree rebuild); used by `PgnViewerScreen` |
| `repertoire_controller.dart` | **Central repertoire session state**: owns `MoveTree` + `TreePath` cursor, lines, opening tree. Single navigation entry point `jump(path)`. | `jump`, `playMove`, `playMoveAtTreePath`, `goBack`/`goForward`/`goToStart`/`goToEnd`, `loadMoveSequence`, `navigateToLineMove`, `deleteAtPath`, `promoteVariation`, `makeMainLine`, `setCommentAtPath`, backward-compat wrappers `userPlayedMove`/`userSelectedTreeMove` |
| `repertoire_writer.dart` | Serialised PGN mutations + undo stack | `addMoveAtPosition`, `acceptSuggestion`, `undo`, `canUndo` |

### `lib/models/`

| File | Purpose |
|------|---------|
| `analysis/discovery_result.dart` | Engine discovery lines (MultiPV) |
| `analysis/move_analysis_result.dart` | Per-move analysis in game review |
| `analysis_node.dart` | Game tree node for analysis |
| `analysis_player_info.dart` | Player metadata for analysis |
| `build_tree_node.dart` | **Generated tree node**: eval, ease, myEase, expectimax, traps, `pvContinuationMove`, `engineInjected`, children, serialization |
| `chess_game.dart` | Loaded game model for tactics/analysis |
| `engine_evaluation.dart` | Single eval result |
| `engine_settings.dart` | **Singleton** engine/generation/explorer settings + SharedPreferences persistence |
| `engine_weakness_result.dart` | Weak square / position analysis output |
| `eval_database_settings.dart` | CdbDirect path, enable flags (persisted) |
| `explorer_response.dart` | Lichess opening explorer API shape |
| `move_tree.dart` | Editable PGN move tree (`MoveNode`, `TreePath`, `MoveTree`). FEN cached per node. PGN round-trip via `fromPgn`/`toPgn`. `collectFenPrefixes()` for transposition detection. Used by `RepertoireController` as the single source of truth for the move cursor. |
| `opening_tree.dart` | In-memory repertoire statistics tree indexed by FEN; `hasMove`, `appendLine` (read-only reference, separate from `MoveTree`) |
| `pgn_filter_models.dart` | PGN import filter types |
| `pgn_source.dart` | **PGN source model** — represents one attached PGN file or paste blob with optional slice config; used by `PgnSourcesPanel` for multi-source import |
| `position_analysis.dart` | Position analysis aggregate |
| `repertoire_line.dart` | Trainable line extracted from PGN (moves, title, probability) |
| `repertoire_metadata.dart` | Side, starting FEN, headers |
| `repertoire_move_progress.dart` | Training progress per move |
| `repertoire_review_entry.dart` | FSRS-style review scheduling |
| `repertoire_review_history_entry.dart` | Review history log |
| `settings_enums.dart` | `CandidateSource`, `SelectionMode`, `OpponentProbabilityMode`, etc. |
| `tactics_position.dart` | Tactics puzzle position; includes `int rating` (0=unrated, 1–5 stars; 1-star excluded from training by default) |
| `tactics_session_settings.dart` | `TacticsSessionSettings` — order (`newestFirst`/`leastReviewed`/`worstSuccessRate`/`random`), `mistakeTypes` filter, `includeOneStar` toggle; `accepts(pos)` for session filtering |
| `training_settings.dart` | Trainer behavior (persisted) |

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
| **models/trap_line_info.dart** | Trap metadata + optional `allReplies`, `fen` |
| **models/trap_reply.dart** | Opponent reply classification at trap position |
| **services/trap_index_service.dart** | FEN/prefix indexes, repertoire & line metrics, ETV |
| **widgets/trap_detail_card.dart** | Narrative trap UI, reply table, hoverable move path |
| **widgets/trap_move_indicator.dart** | Orange dot for pre-trap PGN moves |
| **widgets/trap_navigation_buttons.dart** | Prev/next trap in line (board toolbar) |
| **widgets/trap_summary_header.dart** | Aggregate trap stats + ETV |
| **widgets/trap_walkthrough.dart** | Sequential trap tour with list hover preview |
| **widgets/traps_browser.dart** | Sortable trap list |

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
| **services/audit_config.dart** | `AuditConfig` thresholds (mistake/inaccuracy cp, min games, Maia prob, depth); `useLichessDb` defaults `false`; `toMap()`/`fromMap()` serialization; `summaryLabel` compact display |
| **services/repertoire_audit_service.dart** | BFS walker: Stockfish MultiPV for our moves, Maia for opponent gaps (Lichess mothballed); reads/writes `EvalCache`; computes cumulative reach probability per finding; transposition detection for missing moves (checks if resulting FEN exists in tree's `fenToNodes`); `pause()`/`resume()`/`cancel()`; exposes `checkedFens` for resume support; accepts `skipFens`/`priorFindings` to resume interrupted audits |
| **services/audit_persistence.dart** | `AuditPersistence` singleton: centralized save/load for audit snapshots (`AuditSnapshot` = result + config + checked FENs + completion state). Auto-loads on repertoire open, auto-saves on dismiss changes. Handles v1 (legacy) and v2 (envelope) JSON formats |
| **widgets/audit_config_panel.dart** | Audit configuration: sources (Lichess DB chip hidden), thresholds, scope, start/cancel; `useLichessDb` defaults false; accepts external `RepertoireAuditService` for pause/resume from Jobs tab |
| **widgets/audit_config_dialog.dart** | Modal dialog wrapping AuditConfigPanel; forwards `auditService` and `onConfigChanged` |
| **widgets/audit_findings_panel.dart** | Results display: category filter chips (Blunders/Inaccuracies/Missing/Weak/Dead Ends), auto-scaled to ~20 highest-probability findings (more surface as dismissed), sorted by reach probability, bulk dismiss context menu, keyboard navigation (N/P/D), selected state, timestamp display, "Re-run audit" button; resume banner when `interruptedSnapshot` set (`onResumeAudit`, `onStartFreshAudit`) |

**Entry points:** Toolbar "Audit" button (shortcut **A**) is context-aware: opens bottom pane Findings tab if audit running or results exist; opens config dialog otherwise. Force-open config via "Re-run audit" button in findings panel. Results appear in bottom pane Findings tab.

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
- **Missing-move ephemeral preview:** Clicking a missing-move finding navigates to the parent position AND shows the missing move played ephemerally on the board (position after the missing move). A blue "New line from here" bar appears below the board with the missing move name; clicking it creates a new line in the tree with those moves. Close button dismisses the ephemeral preview. Ephemeral state auto-clears when the user navigates normally.
- **Transposition detection:** Missing-move findings check if the resulting FEN (after playing the missing move) already exists in the repertoire tree. If so, the finding is tagged "transposes" in the summary — indicating the gap is less critical because the position is already covered elsewhere.
- Category filter chips: Blunders, Inaccuracies, Missing, Weak, Dead Ends — click to toggle (multi-select). Counts shown per chip.
- **Auto-scaling:** At most ~20 findings shown at a time (sorted by reach probability, highest first). As findings are dismissed, lower-probability ones surface. Status bar shows "20 of 150 findings" when capped.
- **Probability display:** Missing moves show Maia probability (e.g. "p=0.003 Maia" for small values). Uses adaptive formatting: ≥10% → integer, ≥1% → 1 decimal, ≥0.001 → 3 decimals, smaller → scientific notation.
- Move numbers in summaries: "Missing: 3...Nd2" instead of "Missing: Nd2". Also for mistakes/inaccuracies.
- Dismiss button: 16px icon with 32px hit target and hover feedback.
- Bulk dismiss via right-click context menu: dismiss similar (same type + FEN), dismiss at depth (all of same type at ply N or earlier), dismiss all of type.
- Keyboard navigation: N/P or arrows cycle through findings (board auto-navigates), D dismisses and advances.
- Selected finding gets a highlighted background in the list, with "X of N" counter in status bar.
- Timestamp display: "2h ago", "3d ago", etc. when viewing saved results.
- Dismissed findings shown in a collapsed section at the bottom with "Restore all".

Implements principles from `docs/tree-display-architecture.md` (focused window, flat index, pre-sorted children).

### `lib/screens/`

| File | Purpose |
|------|---------|
| `main_screen.dart` | Mode `IndexedStack`, engine lifecycle on mode exit |
| `repertoire_screen.dart` | **Composition root** — wires `GenerationSessionController`, `AuditSessionController`, `CoverageController` to widgets; owns board, PGN, ephemeral finding preview, layout; ~15 fields (down from 40) |
| `repertoire_selection_screen.dart` | Pick/create repertoire |
| `repertoire_training_screen.dart` | Training mode shell |
| `analysis_screen.dart` | Game weakness / position analysis |
| `pgn_viewer_screen.dart` | Standalone PGN + `InlineEngineBar`; surfaces `loadFile` errors via SnackBar and empty-state text; ⋮ menu with "Generate repertoire from games" |
| `player_selection_screen.dart` | Lichess player pick for analysis |
| `settings_screen.dart` | Global engine, opponent model (Maia only; Lichess DB selector hidden), **on-the-fly expectimax** (live dock; separate from Generation tab Engine Depth), CdbDirect settings |

### `lib/services/` (grouped)

#### Engine & analysis

| File | Purpose |
|------|---------|
| `engine/engine_lifecycle.dart` | OFF/IDLE/ANALYZING/GENERATING state machine; `onPositionChanged` skips notify when already ANALYZING; `@visibleForTesting resetForTest()` resets singleton; `testMode` skips pool I/O in unit tests |
| `engine/engine_connection.dart` | Abstract engine connection |
| `engine/eval_worker.dart` | UCI worker loop |
| `engine/stockfish_pool.dart` | Worker pool acquire/release, `prepareForTreeBuild` |
| `engine/stockfish_*_connection.dart` | Platform Stockfish backends |
| `engine/process_connection*.dart` | Process spawn (native/stub) |
| `analysis_service.dart` | Multi-position analysis orchestration |
| `analysis_games_service.dart` | Fetch/analyze user games |
| `game_analysis_controller.dart` | Game review session |
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
| `eval_cache.dart` | Eval cache facade (SQLite v2): Stockfish evals + `maia_cache` table keyed by `(fen, elo)` (policy JSON, win prob); `MaiaCache` get/put with L1 in-memory mirror; shared by generation, audit, and interactive engine panes |
| `eval/eval_canonicalize.dart` | FEN normalization for lookup |

#### Generation pipeline

| File | Purpose |
|------|---------|
| `tree_build_service.dart` | BFS tree build; MultiPV line-0 PV reply stash + opponent-node injection when Maia omits it; `buildFromPgnFreqMap()` for DB Explorer mode |
| `generation/pgn_freq_map.dart` | PGN frequency map (Dart port of C `pgn_freq.c`): isolate-based PGN parsing, per-position move frequencies, min-elo filtering, move probability filtering |
| `generation/line_extractor.dart` | Extract lines from tree; PGN `{engine-injected}` on injected opponent moves |
| `generation/pgn_export.dart` | Export generated lines to PGN (includes `{engine-injected}` annotation) |
| `generation/generation_config.dart` | `TreeBuildConfig` (default `evalDepth` 14, `relativeEval` true), build modes; DB Explorer fields: `pgnFilePaths`, `dbMinGames`, `dbMinProb`, `minElo` |
| `generation/tree_eval_resolver.dart` | Eval resolution during build |
| `generation/tree_ease.dart` | Opponent ease calculation |
| `generation/tree_my_ease.dart` | Our-move naturalness + line playability |
| `generation/eca_calculator.dart` | Expectimax + trap scores |
| `generation/repertoire_selector.dart` | Mark repertoire moves on tree |
| `generation/trap_extractor.dart` | Trap candidate collection |
| `generation/fen_map.dart` | Transposition map |
| `generation/tree_serialization.dart` | tree.json read/write (`pv_continuation_move`, `engine_injected`) |
| `generation/tree_build_progress.dart` | Progress callbacks |

#### Repertoire & PGN

| File | Purpose |
|------|---------|
| `repertoire_service.dart` | Load/save repertoire, parse lines, append moves |
| `repertoire_review_service.dart` | Review scheduling |
| `pgn_service.dart` | General PGN load/save |
| `pgn_parsing_service.dart` | Multi-game split/count (`splitPgnIntoGames`, `countPgnGames`); `[Event]`-delimited chunks, including back-to-back games without blank lines (tree_builder exports) |
| `opening_tree_builder.dart` | Build opening tree from PGN |
| `default_pgn_service.dart` | Bundled default PGN extraction (`rootBundle.load` + `decodeTextBytes` for Latin-1/Windows-1252 names in legacy PGNs) |

#### Expectimax & lines

| File | Purpose |
|------|---------|
| `expectimax_line_service.dart` | `followExpectimaxLine`, `generateExpectimaxLines`, `hasPrecomputedExpectimaxAtPly` (`maxSubtreePly` ≥ on-the-fly depth), `isBranchCompleteToPly`, `ExpectimaxLine` model |
| `on_the_fly_expectimax_service.dart` | Progressive BFS from current FEN, session cache |
| `line_metrics_helpers.dart` | Line-level quality/trap/coherence metrics for UI |
| `coherence_service.dart` | FP-Growth coherence + browse hints |
| `fp_growth.dart` | FP-Growth algorithm |
| `probability_service.dart` | Move probability helpers; `_fetchInternal()` mothballed (returns null immediately, no Lichess Explorer API) |

#### Maia & Lichess

| File | Purpose |
|------|---------|
| `maia_service.dart`, `maia_native.dart`, `maia_stub.dart`, `maia_factory.dart`, `maia_tensor.dart` | Human move prediction; `evaluate()` checks `MaiaCache` before ONNX inference, writes results back after |
| `lichess_api_client.dart` | Authenticated API |
| `lichess_auth_service.dart` | OAuth/PAT token storage |
| `ease_calculator.dart` | Standalone ease helpers |

#### Tactics & training

| File | Purpose |
|------|---------|
| `tactics_engine.dart` | Puzzle validation; `buildTrainableLine` extends lines using **Maia opponent-probability** (≥ 85% threshold) when available — agreement with PV continues from PV, disagreement triggers a fresh Stockfish depth-14 eval for the user's best reply then stops, low confidence stops at single move; falls back to captures/checks/mates heuristic when Maia is unavailable; max 6 ply (3 user moves); `solutionPv` + `solutionLineToSan` for Show Solution |
| `tactics_database.dart` | Local puzzle store; `startSession(settings)` builds filtered/ordered queue; `setRating(fen, rating)` persists star rating + removes 1-star from live queue |
| `tactics_import_service.dart` | Import from Lichess/Chess.com; initializes Maia at import start; extracts user Elo from first game PGN headers (`WhiteElo`/`BlackElo`) — Lichess uses PGN Elo as-is; Chess.com maps blitz Elo via `chesscom_lichess_elo.dart` then clamps 600–2400 (default 2200); passes `MaiaEvaluator` + `EvalWorker` to `buildTrainableLine` for line extension |
| `tactics_export_import.dart` | Export/import facade |
| `tactics_export_import_io.dart` / `tactics_export_import_stub.dart` | Platform export/import |
| `tactics_parallel_analyzer.dart` / `tactics_parallel_analyzer_stub.dart` | Parallel puzzle analysis |
| `tactics/tactics_session_controller.dart` | Puzzle session; `startSession(settings)` delegates to DB queue; `setRating(star)` on current position |
| `tactics/tactics_import_coordinator.dart` | Import UI coordination |
| `training/training_session_controller.dart` | Repertoire training flow |
| `training/training_phase.dart` | Phase enum/state |

#### Storage & platform

| File | Purpose |
|------|---------|
| `storage/storage_service.dart` | Abstract file I/O |
| `storage/io_storage_service.dart` | Desktop/mobile IO; `_resolveFile` maps relative paths to app documents; `readFile` / PGN reads use UTF-8 with Latin-1 fallback via `utils/file_text_reader.dart`; `listRepertoireFiles` filters out `*_raw_games.pgn` companion files |
| `storage/storage_factory.dart` | Platform factory |
| `storage/app_paths.dart` | App data directories |
| `browser_extension_server/*` | Local HTTP server for browser extension (IO/stub) |

### `lib/widgets/` (grouped)

#### Shared UI patterns

| File | Purpose |
|------|---------|
| `shortcut_tooltip.dart` | **Shortcut hover tooltips** — `AppShortcuts` shared keys (e.g. **J** auto-advance); `actionTooltip()`, `ShortcutIconButton`, `ShortcutTooltip`, `shortcutTooltip()` (500ms hover delay); debug asserts if shortcut is empty. Cursor rule: `.cursor/rules/shortcut-tooltips.mdc`. Tests: `test/widgets/shortcut_tooltip_test.dart`. |

#### Layout (repertoire builder zones)

| File | Purpose |
|------|---------|
| `layout/repertoire_layout.dart` | 3-zone orchestrator (board / main / context) |
| `layout/board_zone.dart` | Board wrapper; app-bar trap navigation via `BoardZoneControls` |
| `layout/edit_main_zone.dart` | PGN editor column shell |
| `layout/edit_context_zone.dart` | Edit context column: FilterChip visibility toggles; user-arrangeable **columns** (horizontal, draggable dividers) each with a **vertical stack** of panels (draggable dividers). Default layout: col1 = Browse+Engine+Expectimax+Tree stacked, col2 = Lines. **Arrange panes** sheet + long-press chip → assign column. Layout persisted via [EditContextLayoutPrefs] (`edit_context.layout_v1`). Panel shells use [AutomaticKeepAliveClientMixin] but **rebuild slot content** each parent update (tree/generation props must not freeze). Expectimax uses [ExpectimaxPanelHost] (on-the-fly when FEN lacks depth-complete precomputed expectimax, same as dock). `selectedViewsNotifier` mirrors visible set. |
| `layout/edit_context_tabs.dart` | `EditContextTabSpec`, `kEditContextTabs` chip descriptors |
| `layout/edit_context_split_handle.dart` | Draggable horizontal/vertical pane dividers |
| `layout/edit_context_layout_sheet.dart` | Bottom sheet: reorder stacks, move views between columns |
| `models/edit_context_layout.dart` | `EditContextLayout` / `EditContextColumnLayout` column+stack model |
| `services/edit_context_layout_prefs.dart` | SharedPreferences persistence for edit context layout |
| `layout/analyze_main_zone.dart` | Analyze mode main column shell |
| `layout/analyze_context_zone.dart` | Detail pane (eval graph, trap card) |
| `layout/repertoire_mode.dart` | `RepertoireMode`, `EditContextView` enums |
| `layout/repertoire_mode_switcher.dart` | Edit/Analyze toggle |
| `layout/bottom_pane.dart` | VS Code-style resizable, collapsible bottom pane with tabs (Findings/Jobs/Lines); collapsed by default, auto-opens on audit/generation start, drag-resizable, badge counts |
| `layout/repertoire_status_bar.dart` | Bottom metrics bar (badges open bottom pane tabs) |
| `layout/empty_state_placeholder.dart` | Shared empty states |
| `layout/responsive_split_layout.dart` | Generic split helper |

#### Repertoire-specific

| File | Purpose |
|------|---------|
| `repertoire/repertoire_board_pane.dart` | Board + preview overlay + generation dim |
| `repertoire/repertoire_toolbar.dart` | App bar actions (generate, settings, mode) |
| `repertoire/repertoire_tab_bar.dart` | Compact layout tab bar (PGN | Context) + navigation trail |
| `repertoire/repertoire_analyze_pane.dart` | Wires analyze zones (lines, coverage, traps) |
| `repertoire/repertoire_analyze_props.dart` | Prop bag for analyze pane |
| `repertoire/repertoire_lines_with_traps.dart` | Lines tab with trap + coherence panels |
| `repertoire_generation_tab.dart` | Generation config UI; receives `GenerationSessionController` (build service + observable state); **Engine Depth (tree build)** default 14; `cancelGeneration()` calls `_savePartialTree()` before cleanup |
| `repertoire_analysis_dock.dart` | Resizable Engine/Expectimax dock above PGN |
| `repertoire_lines_browser.dart` | Filter/sort/group lines |
| `interactive_pgn_editor.dart` | Tree-structured PGN editor with Overlay-based context menu (promote, make main line, duplicate line, copy PGN, delete), trap dots, hover preview hooks |
| `opening_tree_widget.dart` | Compact tree navigator |
| `opening_tree/opening_tree_move_row.dart` | Tree row |
| `opening_tree/coverage_annotation.dart` | Coverage badges on tree |
| `coverage_calculator_widget.dart` | Run coverage analysis UI |
| `coherence_panel.dart` | Cluster list + global coherence score |

#### Engine widgets

| File | Purpose |
|------|---------|
| `engine/unified_engine_pane.dart` | MultiPV table, hoverable PV via `ClickableMoveLineWidget`; FEN changes schedule analysis post-frame (avoids setState-during-build); DB column hidden; best eval persisted to `EvalCache` via `_persistBestEvalToCache()` |
| `engine/expectimax_lines_pane.dart` | Precomputed + on-the-fly expectimax lines; floating hover preview |
| `engine/expectimax_panel_host.dart` | Owns [OnTheFlyExpectimaxService] (or accepts external); auto-computes when [hasPrecomputedExpectimaxAtPly] is false at FEN (`onTheFlyMaxDepth`); used by [EditContextZone] and [RepertoireAnalysisDock] |
| `engine/inline_engine_bar.dart` | Compact engine for PGN viewer and tactics; settings button opens `AnalysisSettingsContext.tacticsEngine` (depth + multiPv only); writes Stockfish eval to `EvalCache` after discovery completes |
| `engine/inline_expectimax_bar.dart` | Compact toggleable expectimax bar for right pane; wraps `ExpectimaxPanelHost(compact: true)` with toggle switch (shortcut X) and settings gear |
| `engine/engine_toggle_button.dart` | Legacy bolt toggle widget (unused; engine on/off is in Settings) |
| `engine/engine_pane_footer.dart` | Engine pane footer controls |
| `engine/floating_board_preview.dart` | Cursor-following mini board overlay on engine/expectimax line hover |

#### Lines sub-widgets

| File | Purpose |
|------|---------|
| `lines/line_filter_controls.dart` | Search, sort, coverage filter |
| `lines/line_item_row.dart` | Single line row + trap/coherence badges |
| `lines/line_metrics_panel.dart` | Metrics + Next/Biggest gap buttons |
| `lines/lines_list_panel.dart` | Grouped list view |

#### Shared / other modes

| File | Purpose |
|------|---------|
| `app_mode_menu_button.dart` | Top-level mode switcher menu |
| `chess_board_widget.dart` | Board rendering, move input |
| `clickable_move_line.dart` | SAN line with tap + hover callbacks |
| `navigation_trail.dart` | Breadcrumb trail widget (used by repertoire tab bar) |
| `analysis_tab.dart` | Legacy browse/analysis tab wrapper (not used in current repertoire screen) |
| `generation_config_dialog.dart` | Modal dialog wrapping RepertoireGenerationTab; pops on generation start via controller listener; opened by sparkles button / G shortcut |
| `layout/jobs_panel.dart` | Jobs tab content for bottom pane: active/completed generation and audit jobs with progress, config summary, pause/resume/cancel controls |
| `analysis/analysis_settings_sheet.dart` | Context-aware analysis/engine settings dialog. Accepts `AnalysisSettingsContext` (`full` or `tacticsEngine`) to gate which sections are shown: engine depth + multiPv always; panel visibility in `full` mode ("Show DB % column" toggle and Lichess DB filter section hidden — Explorer mothballed). |
| `analysis_download_dialog.dart` | Download games for analysis |
| `game_analysis_tab.dart` | PGN viewer Analysis tab: chart, classified move list, best-line / Maia taps; each tap adds an **ephemeral RAV** at that ply (accumulates; does not clear prior lines); move list scrolls only when the nearest classified row changes (instant `ensureVisible`, no per-ply jump+animate) |
| `game_analysis_chart.dart` | Eval chart for game review |
| `game_nav_item.dart` | `GameNavItem` — label, study rating/summary, PGN `headers` for nav bar and search dialog |
| `game_nav_bar.dart` | Game navigation controls; **Game N / Total** opens `GameSearchDialog` (replaces ±25-game popup); **Copy PGN** (`onCopyPgn`) and **Clear analysis annotations** (`onClearAnnotations`, `Icons.layers_clear_outlined`, enabled when `hasEphemeralAnnotations`) in auto-play row |
| `game_search_dialog.dart` | Compact jump-to-game search (`GameNavItem.headers` + study fields); up to 5 matches, pure-integer query → “Go to game N”, Enter selects first, Escape dismisses |
| `games_list_widget.dart` | Selectable games list |
| `fullscreen_game_view.dart` | Fullscreen game + board view |
| `fen_list_widget.dart` | FEN list display helper |
| `pgn_with_analysis_pane.dart` | PGN + analysis dock split |
| `pgn_with_engine.dart` | PGN pane with inline engine bar |
| `pgn_viewer_widget.dart` | Game list + board for viewer; `_variationsByPly` holds mainline + **multiple ephemeral RAVs** per branch point (`addEphemeralMove` / `clearEphemeralMoves`); PGN tab renders each root as `( … )` |
| `pgn_import_dialog.dart` | PGN file import dialog; live preview counts **lines** via `countPgnGames` (matches Lines list). **Deprecated** — replaced by `PgnSourcesPanel` for multi-source contexts |
| `pgn_sources_panel.dart` | **Compact multi-source PGN attachment panel** — replaces the oversized import dialog; supports multiple PGN files/pastes, per-source slicing via `InlineSliceEditor`, embedded `LinesPreviewPanel` |
| `pgn_inline_slice_editor.dart` | **Inline slice editor** — "All Lines" / "Slice" radio + position/header/sequence filters + isolate-computed match count + preview panel; used inside `PgnSourcesPanel` per source |
| `lines_preview_panel.dart` | **Browseable line list** — fuzzy search, virtualized scrolling, `HoverableMoveChips` per row with `FloatingBoardPreview` on hover; used in slice dialog and inline slice editor |
| `hoverable_move_chips.dart` | **Inline move chips with hover board preview** — renders SAN moves as compact chips, computes FEN on hover, triggers `BoardPreviewController.setPreview`; shared by `LinesPreviewPanel`, `LineItemRow`, PGN Viewer |
| `slice/position_filter.dart` | Shared position filter widget (FEN/SAN input + Apply/Clear + "Board position" chip) |
| `slice/header_filters.dart` | Shared header filters widget (dynamic field/mode/value rows) |
| `slice/sequence_filter.dart` | Shared move sequence filter widget ([gap]-separated groups) |
| `pgn_slice_dialog.dart` | Slice dataset dialog (position, sequence, header filters) | Default header row starts as Date ≥ (changeable field/mode like other rows); live preview via `LinesPreviewPanel` with hover board; skips recompute when effective filters unchanged, on empty filter rows, or 300ms-debounced header typing |
| `position_analysis_widget.dart` | Weakness UI |
| `engine_weakness_dialog.dart` | Weakness detail dialog |
| `lichess_db_info_icon.dart` | Lichess DB info + OAuth entry point |
| `tactics_control_panel.dart` | Tactics mode shell; **eagerly warms up** StockfishPool + Maia on page load (`_warmUpEngines` in `initState`) so imports start instantly; PGN tab uses [PgnWithEngine] — moves sync to PGN in real time (correct user moves and opponent replies are added via `addEphemeralMove` as they happen; no lazy replay on tab switch); `TacticsBoardUpdate.san` carries the SAN so `_applyBoardUpdate` pushes to PGN; FEN comparison in `onPositionChanged` prevents double-updates; shortcuts include **E** (inline engine), **J** (auto-advance), **1-5** (rate), arrows, Space/A/P/N/Esc |
| `tactics/tactics_training_panel.dart` | Puzzle UI; **Show Solution** = numbered SAN line + highlight only; star rating after solve/reveal |
| `tactics/tactics_browse_panel.dart` | Puzzle browser; per-row tappable star rating, 1-star rows dimmed, hide/show 1★ filter toggle |
| `tactics/tactics_import_panel.dart` | Import tactics from Lichess/Chess.com; **Session Settings** dialog (order, mistake-type filter, 1-star toggle) opened from toolbar button beside Browse Tactics; live matching count on Start Session |
| `tactics/puzzle_stats_display.dart` | Puzzle statistics display |
| `tactics/tactics_delayed_tooltip.dart` | Delayed tooltip for puzzle hints |
| `training/training_*.dart` | Training panels (progress, results, settings, board controls, repertoire selector); **J** toggles learn auto-advance (`learnRequiresClick`) on training screen + settings tooltip |
| `settings/settings_widgets.dart` | Reusable settings tiles |
| `eval_database_settings_panel.dart` | CdbDirect configuration |
| `lichess_db_selector.dart` | Explorer DB/speed/rating filters (widget retained; hidden from settings while Explorer mothballed) |
| `generation/build_progress_display.dart` | Generation progress UI |
| `generation/eval_sources_section.dart` | Eval source picker in generation |

### `lib/utils/`

| File | Purpose |
|------|---------|
| `chess_utils.dart` | UCI/SAN helpers |
| `fen_utils.dart` | FEN manipulation |
| `pgn_utils.dart` | PGN formatting, event title extraction |
| `pgn_comment_utils.dart` | Comment filtering |
| `coverage_helpers.dart` | Coverage UI helpers |
| `lines_filter_helpers.dart` | Line filter/sort/group (`getLineGroupName`) |
| `ease_utils.dart` | Ease display formatting |
| `eval_constants.dart` | Eval display thresholds |
| `chesscom_lichess_elo.dart` | Chess.com blitz → Lichess blitz Elo table + `chessComBlitzToLichessBlitz()` for Maia (tactics Chess.com import) |
| `app_messages.dart` | Snackbar helpers |
| `file_text_reader.dart` | UTF-8 file read with Latin-1 fallback (PGN / text imports) |
| `system_info.dart` | CPU core count (native/stub) |

### `lib/theme/`

| File | Purpose |
|------|---------|
| `app_colors.dart` | Dark theme palette, semantic colors (expectimax, danger, etc.) |

---

## Test coverage map

| Test file | Verifies |
|-----------|----------|
| `test/core/board_preview_controller_test.dart` | Preview debounce, clear |
| `test/core/repertoire_controller_test.dart` | Controller navigation (tree-path model), line sync, invariants |
| `test/models/move_tree_test.dart` | MoveTree: parse PGN, round-trip, addMove, navigation, variations, TreePath equality |
| `test/core/repertoire_writer_test.dart` | Add move, PGN append |
| `test/core/repertoire_writer_undo_test.dart` | Undo stack |
| `test/features/browse/candidate_service_test.dart` | Candidate merge/sort |
| `test/features/coverage/coverage_suggestion_service_test.dart` | Suggestions, coherence bonus |
| `test/features/coverage/coverage_result_test.dart` | `CoverageResult.findNextGap` / `findBiggestGap` gap ordering |
| `test/features/traps/trap_index_service_test.dart` | FEN index, line traps |
| `test/features/traps/trap_navigation_buttons_test.dart` | Trap jump UI |
| `test/features/traps/trap_walkthrough_test.dart` | Walkthrough navigation |
| `test/features/eval_tree/eval_tree_controller_test.dart` | Graph controller |
| `test/features/eval_tree/eval_tree_tab_test.dart` | Tab widget |
| `test/features/eval_tree/eval_tree_line_metrics_test.dart` | Line metrics |
| `test/features/eval_tree/eval_tree_layout_engine_test.dart` | Layout performance |
| `test/features/eval_tree/eval_tree_snapshot_adapter_test.dart` | Snapshot adapter |
| `test/features/eval_tree/tree_serialization_eval_tree_test.dart` | Tree JSON round-trip |
| `test/models/opening_tree_test.dart` | Opening tree mutations |
| `test/models/repertoire_metadata_test.dart` | Metadata parsing |
| `test/models/engine_settings_test.dart` | Settings persistence |
| `test/services/coherence_service_test.dart` | Coherence compute |
| `test/services/engine_lifecycle_test.dart` | State transitions, notify-count guards, full lifecycle cycle |
| `test/widgets/unified_engine_pane_lifecycle_test.dart` | Engine pane ↔ lifecycle feedback-loop regression via pane-coupling harness |
| `test/services/expectimax_line_service_test.dart` | Line following / MultiPV |
| `test/services/fp_growth_test.dart` | FP-Growth mining |
| `test/services/generation/tree_my_ease_test.dart` | myEase computation |
| `test/services/generation/repertoire_selector_test.dart` | Expectimax/engine selection, idempotent marking |
| `test/services/pgn_parsing_service_test.dart` | PGN parsing |
| `test/services/repertoire_service_test.dart` | Repertoire I/O |
| `test/services/trap_extractor_test.dart` | Trap extraction |
| `test/services/tactics/tactics_session_controller_test.dart` | Tactics session |
| `test/services/tactics_engine_test.dart` | `checkMoveAtIndex`, SAN normalization, mate-in-1 from mid-game FEN; `buildTrainableLine` fallback + Maia agree/disagree/low-confidence paths with mock evaluator |
| `test/services/eval/test_*.dart` | Eval provider chain (helpers) |
| `test/widgets/layout/edit_context_zone_test.dart` | Context zone multi-panel chips |
| `test/widgets/position_analysis_widget_test.dart` | Analysis widget |
| `test/screens/main_screen_test.dart` | Main screen smoke |
| `test/widget_test.dart` | App smoke |
| `test/utils/lines_filter_helpers_test.dart` | `filterSortAndGroupLines`, grouping, sort invariants |
| `test/utils/chesscom_lichess_elo_test.dart` | Chess.com→Lichess blitz anchor, interpolation, clamp |

**Gaps:** Few widget/integration tests for full `RepertoireScreen` layout, generate mode, or settings screen.

---

## External & non-Flutter components

| Path | Role |
|------|------|
| `tree_builder/` | C expectimax tree builder (`--eval-depth` default 14), CdbDirect reader; MultiPV line-0 PV reply stash + opponent injection (`engine_injected`, PGN `{engine-injected}`). **Build modes** (`--build-mode` in `tree.h`): `stockfish-expectimax` (default interleaved BFS), `maia-db-explore`, `db-explorer`, `trap-finder` (unimplemented). **SQLite cache** (`database.c`): explorer/eval/Maia/repertoire tables plus `build_metadata`. **`cli_args` persistence:** each run calls `save_config_to_db()` → `rdb_save_cli_config()` with the effective CLI as JSON (color, depth, build mode, PGN paths, eval sources, presets, etc.). **`--resume`:** `load_config_from_db()` in `main.c` restores from `cli_args`; `CliExplicit` records flags passed on the command line — saved values apply only for options *not* explicitly set (e.g. `--resume --threads 8` overrides stored thread count). Restores `-c` when omitted; DBs without `cli_args` fail with a clear error. **`--resume` skips** the legacy `check_build_metadata` color/ratings/speeds gate; without `--resume`, reopening an existing `.db` still **refuses** on mismatch (prints stored vs current settings and example `--resume` / fresh / `--input-db` commands). Legacy DBs with data but no metadata get a one-time note and recorded settings. **`--input-db` / `-I`:** copy eval/explorer cache tables (`evaluations`, `explorer_positions`/`explorer_moves`, `multipv_cache`, `maia_cache`) from another DB into a new/empty target via `rdb_import_cache_from` (ATTACH + INSERT OR IGNORE); not `repertoire_moves`. **Threads:** `-t` / `--threads` default is `default_thread_count()` — half of `_SC_NPROCESSORS_ONLN`, minimum 1 (not a fixed 4). **Build progress (TTY):** live line via `progress_line.c` — `[Depth N] X new + Y transpositions | total | rate/min | ~ETA`; depth-complete line uses unique node count at that ply (`g_nodes_created_at_depth`). **Tree resume** (stockfish-expectimax / maia-db-explore): if `<name>.tree.json` exists and `build_complete` is false, stage 1 continues BFS from unexplored frontier leaves (`resume_prepare_frontier` in `tree.c`); only `build_complete: true` skips building. SIGINT saves partial trees; nodes interrupted mid-expansion stay `explored: false` and are retried. **Engine pool:** Stockfish children call `setsid()` (Ctrl+C does not kill engines); `engine_pool_request_stop` from the signal handler sets `shutting_down` and wakes waiters so batch/single eval exits without spamming "all Stockfish engines are dead". `--build-now` / `--skip-build` still export without expanding. **DB explorer:** `--build-mode db-explorer --pgn <file>` (repeatable) → `pgn_freq.c` replays each game from the standard start position; when `--fen` or `--moves` defines a target, counting starts only after the canonical 4-field FEN matches (not SAN-prefix string matching). `--min-elo` (default 2100) skips games where both `[WhiteElo]` and `[BlackElo]` are present and below threshold; missing or partial Elo tags are kept. Games that never reach the target are skipped (aggregate log). Parallel per-file parse when multiple PGNs; binary cache `<name>.freq.bin` with manifest incl. `min_elo`, `--no-freq-cache` to force reparse; OOM aborts parse → `tree_build_from_freqmap` → deferred Stockfish pool start → `tree_enrich_evals` (project DB → external chain → Stockfish; abort if >50% nodes still unevaluated, else warn) → expectimax + PGN export. `fen_map_put` / PGN hash tables propagate resize OOM. Opponent `move_probability` = count/reach; our-move children = 1.0; `tree_recalculate_probabilities` chains cumulative probability. See `tree_builder/ALGORITHM.md`. |
| `browser-to-server-repertoire/` | Browser extension companion |
| `python/` | Offline scripts (Lichess builder, Maia experiments, TWIC) |
| `packages/cdbdirect_flutter_libs/` | Native ChessDB bindings |

---

## Audit gaps

Areas where behavior could not be fully determined without runtime testing:

1. **Browser extension server** — exact API surface and sync semantics with repertoire.
2. **Maia native availability** — platform matrix for real vs stub inference.
3. **Generation cancel/pause** — `GenerationSessionController` now survives dialog disposal (fixes broken GlobalKey); edge cases when pool threads are mid-eval remain untested.
4. **Cross-platform Stockfish** — bundled vs system binary resolution per OS.
5. **Lichess OAuth** — full flow on all desktop platforms (callback server binding).
6. **Compact vs wide layout** — all breakpoint transitions and state preservation paths in `RepertoireScreen` (complex conditional tree).
7. **Training FSRS parameters** — exact scheduling algorithm vs documented FSRS.

For planned work not yet in code, see **[`docs/FUTURE_FEATURES.md`](FUTURE_FEATURES.md)** (backlog only — do not treat as current behavior).
