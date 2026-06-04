# Component Map

**Source of truth for what is currently implemented** in the Chess Auto Prep Flutter/Dart app. Use this document to audit behavior, trace data flows, and plan fixes.

| Document | Purpose |
|----------|---------|
| **This file** | Current implementation — screens, services, widgets, tests |
| [`FUTURE_FEATURES.md`](FUTURE_FEATURES.md) | Backlog only — not yet built or incomplete |
| [`ALGORITHM.md`](ALGORITHM.md) | Flutter expectimax / tree-generation pipeline |
| [`../tree_builder/ALGORITHM.md`](../tree_builder/ALGORITHM.md) | C `tree_builder` CLI pipeline (incl. db-explorer) |
| [`tree-display-architecture.md`](tree-display-architecture.md) | Eval-tree graph performance principles |

Last reviewed against `lib/` (May 2026). When you change code, update the matching section here.

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
| **Features** | Domain-vertical modules (browse, traps, coverage, eval tree) | `features/` |
| **Core** | Session controllers shared across repertoire UI | `core/` |
| **Services** | Business logic, engines, I/O | `services/` |
| **Models** | Immutable / serializable data | `models/` |
| **Constants / utils / theme** | Shared helpers | `constants/`, `utils/`, `theme/` |

**State management:** Provider (`ChangeNotifier`) — primarily `AppState`, `RepertoireController`, singletons (`EngineSettings`, `EngineLifecycle`, `EvalDatabaseSettings`).

**Chess logic:** `dartchess` for rules/FEN; `flutter_chess_board` for display.

---

## Entry points & navigation

### Application bootstrap

```
main.dart
  ├─ EngineSettings.loadFromPrefs()
  ├─ EvalDatabaseSettings.instance.load()
  ├─ EngineLifecycle.loadPersistedState()  // engine on unless pref `engine_lifecycle.toggle_on` is false
  ├─ BrowserExtensionServerFactory.start()  (desktop IO only)
  ├─ DefaultPgnService.ensureExtracted()
  └─ ChessAutoPrepApp → MainScreen
```

| File | Purpose |
|------|---------|
| `lib/main.dart` | `WidgetsFlutterBinding`, window manager, settings init, `MaterialApp` dark theme, `AppState` provider |
| `lib/core/app_state.dart` | Global mode enum, usernames, loaded games, builder↔trainer pending path handoff |
| `lib/screens/main_screen.dart` | `IndexedStack` of mode views; disposes engine when leaving repertoire |

### App modes (`AppMode`)

| Mode | Screen | Primary use |
|------|--------|-------------|
| `tactics` | Embedded `_TacticsModeView` | Lichess tactics puzzles |
| `positionAnalysis` | `AnalysisScreen` | Weak positions from user games |
| `repertoire` | `RepertoireScreen` | Opening repertoire builder |
| `repertoireTrainer` | `RepertoireTrainingScreen` | Spaced repetition training |
| `pgnViewer` | `PgnViewerScreen` | Standalone game PGN + inline engine |

Mode switcher: `widgets/app_mode_menu_button.dart`.

### Repertoire screen layout (high level)

```
RepertoireScreen
  ├─ RepertoireController (position, PGN, lines, opening tree)
  ├─ BoardPreviewController (hover preview FEN)
  ├─ NavigationStack (breadcrumb trail)
  ├─ CoherenceService, TrapIndexService, CoverageResult
  │
  ├─ Wide (≥ kCompactBreakpoint): board 40% | PGN 30% | context panels 30% (multi-select chips)
  │     Context tabs: Browse | Engine | Expectimax | Lines | Tree
  ├─ Generate mode: board 40% | RepertoireGenerationTab 60% (replaces PGN + context)
  ├─ Compact (<960px): board + PGN | Context tabs (context pane has same sub-tabs)
  └─ RepertoireStatusBar + optional TrapWalkthrough overlay
```

Breakpoints: `constants/ui_breakpoints.dart` (`kCompactBreakpoint=960`, `kWideBreakpoint=1100`).

Settings: gear → `screens/settings_screen.dart` (from repertoire toolbar).

---

## Major data flows

### Repertoire load & edit

```
RepertoireSelectionScreen
  → RepertoireService.loadRepertoire(path)
  → RepertoireController (OpeningTree, RepertoireLine list, PGN text)
  → InteractivePgnEditor + OpeningTreeWidget
  → disk writes via RepertoireService / RepertoireWriter (browse adds)
```

### Tree generation (expectimax pipeline)

```
RepertoireGenerationTab
  → EngineLifecycle.enterGeneration(threads)
  → TreeBuildService.build(TreeBuildConfig)     [Phase 1 BFS]
  → calculateTreeEase + EcaCalculator           [Phase 2]
  → calculateMyEase                               [myEase on our moves]
  → RepertoireSelector + LineExtractor
  → TrapExtractor → *_traps.json
  → tree.json persisted beside repertoire PGN
  → EngineLifecycle.exitGeneration()
```

See `docs/ALGORITHM.md` for algorithm detail.

### Browse → one-click add

```
BrowsePanel
  → CandidateService.getCandidates(fen, tree + Lichess Explorer)
       → inRepertoire via OpeningTree.hasMoveOnPath(pathFromRoot, san)
  → tap in repertoire → RepertoireController.userPlayedMoveOnCurrentPath(san)
       (navigateToLineMove on currentMoveSequence + san; avoids SAN-only branch ambiguity)
  → tap unexplored → RepertoireWriter.addMoveAtPosition()
       → RepertoireService.appendMoveAtPath (atomic PGN)
       → RepertoireController.appendMoveToExistingLine
       → userPlayedMoveOnCurrentPath(san)
  → Ctrl+Z → RepertoireWriter.undo()
```

### Coverage & suggestions

```
CoverageCalculatorWidget / CoverageService
  → CoverageResult (gaps, unaccounted moves, covered %)
  → CoverageSuggestionService.generateSuggestions()
  → SuggestionPanel → RepertoireWriter.acceptSuggestion()
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
  → AnalysisService → StockfishPool / EvalWorker
  → Eval chain: session cache → CdbDirect → Lichess API → Stockfish
  → Hover on MOVE or PV line → BoardPreviewController (floating) → FloatingBoardPreview overlay
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
  → game change (N/P, dropdown, slice, sort): `loadCurrentGame` resets `currentPosition` to start; `PgnViewerWidget._loadGame` also calls `onPositionChanged` so board and inline engine stay in sync
Game nav bar (when games loaded): Copy PGN → `filteredGames[currentGameIndex].pgnText` → `Clipboard.setData` + `AppMessages.pgnCopied` snackbar
Analysis tab / inline engine: tap best line or Maia move → `PgnViewerWidgetController.goToMainLineIndex(branchPly)` + `addEphemeralMove` (new RAV per distinct line; prior RAVs kept)
Clear annotations → nav bar `onClearAnnotations` or PGN variation context menu / Escape / Home → `clearEphemeralMoves` (removes ephemeral nodes only)
```

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
| `board_preview_controller.dart` | Debounced hover FEN overlay for board | `setPreview`, `clearPreview`, `previewFen`, `isPreview` |
| `navigation_stack.dart` | Breadcrumb stack for repertoire navigation | push/pop/jump |
| `pgn_viewer_controller.dart` | PGN viewer file load, game index & navigation | `loadFile`, `errorMessage`, slice/export/tree APIs; `loadCurrentGame` resets board to game start (`currentPosition`, engine-line highlight); `applySlice` no-ops when indices + `SliceConfig` unchanged (skips opening-tree rebuild); used by `PgnViewerScreen` |
| `repertoire_controller.dart` | **Central repertoire session state**: FEN, move sequence, lines, tree, PGN sync | `userPlayedMove`, `userPlayedMoveOnCurrentPath`, `userSelectedTreeMove`, `navigateToLineMove`, `loadMoveSequence`, `appendMoveToExistingLine`, `restoreRepertoireFromPgn` |
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
| `opening_tree.dart` | In-memory repertoire tree indexed by FEN; `hasMove`, `appendLine` |
| `pgn_filter_models.dart` | PGN import filter types |
| `position_analysis.dart` | Position analysis aggregate |
| `repertoire_line.dart` | Trainable line extracted from PGN (moves, title, probability) |
| `repertoire_metadata.dart` | Side, starting FEN, headers |
| `repertoire_move_progress.dart` | Training progress per move |
| `repertoire_review_entry.dart` | FSRS-style review scheduling |
| `repertoire_review_history_entry.dart` | Review history log |
| `settings_enums.dart` | `CandidateSource`, `SelectionMode`, `OpponentProbabilityMode`, etc. |
| `tactics_position.dart` | Tactics puzzle position |
| `training_settings.dart` | Trainer behavior (persisted) |

### `lib/features/browse/`

| File | Purpose |
|------|---------|
| **services/candidate_service.dart** | Merges `BuildTree` + Lichess DB + coverage delta into `CandidateMove` list |
| **widgets/browse_panel.dart** | Candidate list, rare-move collapse, back/root/undo nav |
| **widgets/candidate_row.dart** | Per-move row: eval, ease, traps, DB stats, coherence hint |
| **widgets/expanded_trap_list.dart** | Trap sub-list when expanding trappy candidate |

### `lib/features/coverage/`

| File | Purpose |
|------|---------|
| **services/coverage_service.dart** | Lichess explorer queries, gap detection, `CoverageResult` (`findNextGap`, `findBiggestGap`) |
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

Implements principles from `docs/tree-display-architecture.md` (focused window, flat index, pre-sorted children).

### `lib/screens/`

| File | Purpose |
|------|---------|
| `main_screen.dart` | Mode `IndexedStack`, engine lifecycle on mode exit |
| `repertoire_screen.dart` | **Primary builder UI** — board + PGN + multi-panel context zone, generate mode, traps, coverage |
| `repertoire_selection_screen.dart` | Pick/create repertoire |
| `repertoire_training_screen.dart` | Training mode shell |
| `analysis_screen.dart` | Game weakness / position analysis |
| `pgn_viewer_screen.dart` | Standalone PGN + `InlineEngineBar`; surfaces `loadFile` errors via SnackBar and empty-state text |
| `player_selection_screen.dart` | Lichess player pick for analysis |
| `settings_screen.dart` | Global engine, opponent, **on-the-fly expectimax** (live dock; separate from Generation tab Engine Depth), DB settings |

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
| `eval_cache.dart` | Eval cache facade |
| `eval/eval_canonicalize.dart` | FEN normalization for lookup |

#### Generation pipeline

| File | Purpose |
|------|---------|
| `tree_build_service.dart` | BFS tree build; MultiPV line-0 PV reply stash + opponent-node injection when Maia/Lichess omit it |
| `generation/line_extractor.dart` | Extract lines from tree; PGN `{engine-injected}` on injected opponent moves |
| `generation/pgn_export.dart` | Export generated lines to PGN (includes `{engine-injected}` annotation) |
| `generation/generation_config.dart` | `TreeBuildConfig` (default `evalDepth` 14, `relativeEval` true), build modes |
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
| `probability_service.dart` | Move probability helpers |

#### Maia & Lichess

| File | Purpose |
|------|---------|
| `maia_service.dart`, `maia_native.dart`, `maia_stub.dart`, `maia_factory.dart`, `maia_tensor.dart` | Human move prediction |
| `lichess_api_client.dart` | Authenticated API |
| `lichess_auth_service.dart` | OAuth/PAT token storage |
| `ease_calculator.dart` | Standalone ease helpers |

#### Tactics & training

| File | Purpose |
|------|---------|
| `tactics_engine.dart` | Puzzle validation |
| `tactics_database.dart` | Local puzzle store |
| `tactics_import_service.dart` | Import from Lichess |
| `tactics_export_import.dart` | Export/import facade |
| `tactics_export_import_io.dart` / `tactics_export_import_stub.dart` | Platform export/import |
| `tactics_parallel_analyzer.dart` / `tactics_parallel_analyzer_stub.dart` | Parallel puzzle analysis |
| `tactics/tactics_session_controller.dart` | Puzzle session |
| `tactics/tactics_import_coordinator.dart` | Import UI coordination |
| `training/training_session_controller.dart` | Repertoire training flow |
| `training/training_phase.dart` | Phase enum/state |

#### Storage & platform

| File | Purpose |
|------|---------|
| `storage/storage_service.dart` | Abstract file I/O |
| `storage/io_storage_service.dart` | Desktop/mobile IO; `_resolveFile` maps relative paths to app documents; `readFile` / PGN reads use UTF-8 with Latin-1 fallback via `utils/file_text_reader.dart` |
| `storage/storage_factory.dart` | Platform factory |
| `storage/app_paths.dart` | App data directories |
| `browser_extension_server/*` | Local HTTP server for browser extension (IO/stub) |

### `lib/widgets/` (grouped)

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
| `layout/repertoire_status_bar.dart` | Bottom metrics bar |
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
| `repertoire_generation_tab.dart` | Full generation UI + config; **Engine Depth (tree build)** default 14 |
| `repertoire_analysis_dock.dart` | Resizable Engine/Expectimax dock above PGN |
| `repertoire_lines_browser.dart` | Filter/sort/group lines |
| `interactive_pgn_editor.dart` | Tree-structured PGN editor, trap dots, hover preview hooks |
| `opening_tree_widget.dart` | Compact tree navigator |
| `opening_tree/opening_tree_move_row.dart` | Tree row |
| `opening_tree/coverage_annotation.dart` | Coverage badges on tree |
| `coverage_calculator_widget.dart` | Run coverage analysis UI |
| `coherence_panel.dart` | Cluster list + global coherence score |

#### Engine widgets

| File | Purpose |
|------|---------|
| `engine/unified_engine_pane.dart` | MultiPV table, hoverable PV via `ClickableMoveLineWidget`; FEN changes schedule analysis post-frame (avoids setState-during-build) |
| `engine/expectimax_lines_pane.dart` | Precomputed + on-the-fly expectimax lines; floating hover preview |
| `engine/expectimax_panel_host.dart` | Owns [OnTheFlyExpectimaxService] (or accepts external); auto-computes when [hasPrecomputedExpectimaxAtPly] is false at FEN (`onTheFlyMaxDepth`); used by [EditContextZone] and [RepertoireAnalysisDock] |
| `engine/inline_engine_bar.dart` | Compact engine for PGN viewer |
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
| `analysis_tab.dart` | Legacy browse/analysis tab wrapper |
| `analysis/analysis_settings_sheet.dart` | Analysis mode settings sheet |
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
| `pgn_import_dialog.dart` | PGN file import dialog; live preview counts **lines** via `countPgnGames` (matches Lines list) |
| `pgn_slice_dialog.dart` | Slice dataset dialog (position, sequence, header filters) | Live preview via isolate; skips recompute when effective filters unchanged, on empty filter rows, or 300ms-debounced header/date typing |
| `position_analysis_widget.dart` | Weakness UI |
| `engine_weakness_dialog.dart` | Weakness detail dialog |
| `lichess_db_info_icon.dart` | Lichess DB info + OAuth entry point |
| `tactics_control_panel.dart` | Tactics mode shell |
| `tactics/tactics_training_panel.dart` | Puzzle UI |
| `tactics/tactics_browse_panel.dart` | Puzzle browser |
| `tactics/tactics_import_panel.dart` | Import tactics from Lichess |
| `tactics/puzzle_stats_display.dart` | Puzzle statistics display |
| `tactics/tactics_delayed_tooltip.dart` | Delayed tooltip for puzzle hints |
| `training/training_*.dart` | Training panels (progress, results, settings, board controls, repertoire selector) |
| `settings/settings_widgets.dart` | Reusable settings tiles |
| `eval_database_settings_panel.dart` | CdbDirect configuration |
| `lichess_db_selector.dart` | Explorer DB/speed/rating filters |
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
| `test/core/repertoire_controller_test.dart` | Controller navigation, line sync |
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
| `test/services/tactics_engine_test.dart` | `checkMoveAtIndex`, SAN normalization, mate-in-1 from mid-game FEN |
| `test/services/eval/test_*.dart` | Eval provider chain (helpers) |
| `test/widgets/layout/edit_context_zone_test.dart` | Context zone multi-panel chips |
| `test/widgets/position_analysis_widget_test.dart` | Analysis widget |
| `test/screens/main_screen_test.dart` | Main screen smoke |
| `test/widget_test.dart` | App smoke |
| `test/utils/lines_filter_helpers_test.dart` | `filterSortAndGroupLines`, grouping, sort invariants |

**Gaps:** Few widget/integration tests for full `RepertoireScreen` layout, generate mode, or settings screen.

---

## External & non-Flutter components

| Path | Role |
|------|------|
| `tree_builder/` | C expectimax tree builder (`--eval-depth` default 14), CdbDirect reader; MultiPV line-0 PV reply stash + opponent injection (`engine_injected`, PGN `{engine-injected}`). **Build modes** (`--build-mode` in `tree.h`): `stockfish-expectimax` (default interleaved BFS), `maia-db-explore`, `db-explorer`, `trap-finder` (unimplemented). **SQLite cache** (`database.c`): explorer/eval/Maia/repertoire tables plus `build_metadata` (color, `-r` ratings, `-s` speeds, `created_at` / `last_run_at`). On reuse of an existing `.db`, compares stored metadata to current CLI flags — **refuses** on any mismatch (prints stored vs current settings and example resume/fresh/`--input-db` commands, exit 1); informational resume when settings match; legacy DBs with data but no metadata get a one-time note and recorded settings. **`--input-db` / `-I`:** copy eval/explorer cache tables (`evaluations`, `explorer_positions`/`explorer_moves`, `multipv_cache`, `maia_cache`) from another DB into a new/empty target via `rdb_import_cache_from` (ATTACH + INSERT OR IGNORE); not `repertoire_moves`. **Build progress (TTY):** live line via `progress_line.c` — `[Depth N] X new + Y transpositions | total | rate/min | ~ETA`; depth-complete line uses unique node count at that ply (`g_nodes_created_at_depth`). **Resume** (stockfish-expectimax / maia-db-explore): if `<name>.tree.json` exists and `build_complete` is false, stage 1 continues BFS from unexplored frontier leaves (`resume_prepare_frontier` in `tree.c`); only `build_complete: true` skips building. SIGINT saves partial trees; nodes interrupted mid-expansion stay `explored: false` and are retried. **Engine pool:** Stockfish children call `setsid()` (Ctrl+C does not kill engines); `engine_pool_request_stop` from the signal handler sets `shutting_down` and wakes waiters so batch/single eval exits without spamming "all Stockfish engines are dead". `--build-now` / `--skip-build` still export without expanding. **DB explorer:** `--build-mode db-explorer --pgn <file>` (repeatable) → `pgn_freq.c` (freq map from startpos; parallel per-file parse when multiple PGNs; binary cache `<name>.freq.bin` with manifest, `--no-freq-cache` to force reparse; aggregate log when games skip `--moves` prefix; OOM aborts parse) → `tree_build_from_freqmap` → deferred Stockfish pool start → `tree_enrich_evals` (project DB → external chain → Stockfish; abort if >50% nodes still unevaluated, else warn) → expectimax + PGN export. `fen_map_put` / PGN hash tables propagate resize OOM. Opponent `move_probability` = count/reach; our-move children = 1.0; `tree_recalculate_probabilities` chains cumulative probability. See `tree_builder/ALGORITHM.md`. |
| `browser-to-server-repertoire/` | Browser extension companion |
| `python/` | Offline scripts (Lichess builder, Maia experiments, TWIC) |
| `packages/cdbdirect_flutter_libs/` | Native ChessDB bindings |

---

## Audit gaps

Areas where behavior could not be fully determined without runtime testing:

1. **Browser extension server** — exact API surface and sync semantics with repertoire.
2. **Maia native availability** — platform matrix for real vs stub inference.
3. **Generation cancel/pause** — edge cases when pool threads are mid-eval.
4. **Cross-platform Stockfish** — bundled vs system binary resolution per OS.
5. **Lichess OAuth** — full flow on all desktop platforms (callback server binding).
6. **Compact vs wide layout** — all breakpoint transitions and state preservation paths in `RepertoireScreen` (complex conditional tree).
7. **Training FSRS parameters** — exact scheduling algorithm vs documented FSRS.

For planned work not yet in code, see **[`docs/FUTURE_FEATURES.md`](FUTURE_FEATURES.md)** (backlog only — do not treat as current behavior).
