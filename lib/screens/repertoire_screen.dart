/// Repertoire screen - Full-screen repertoire view
/// Shows repertoire positions with board + PGN + context tabs layout.
library;

import '../features/settings/controllers/eval_database_settings.dart';

import '../features/repertoires/models/builder_workspace_snapshot.dart';
import '../features/documents/models/pgn_document.dart';
import '../app/builder_lifetime.dart';
import '../features/repertoires/widgets/builder_copy_inspection_dialog.dart';
import '../l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/features/audit/services/repertoire_audit_service.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';

import '../features/generation/services/generation_artifacts.dart';
import '../app/generation_dependencies.dart' show showGenerationRecovery;

import '../app/legacy_theme_boundary.dart';
import '../features/generation/controllers/generation_publication_controller.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dartchess/dartchess.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../features/studies/controllers/study_import_controller.dart';
import '../features/studies/models/study_import_state.dart';
import '../l10n/study_import_labels.dart';
import '../features/repertoires/controllers/builder_workspace_controller.dart';
import '../core/generation_session_controller.dart';
import '../core/generation_session_types.dart';
import '../features/audit/controllers/audit_session_controller.dart';
import '../features/coverage/controllers/coverage_controller.dart';
import '../features/settings/controllers/engine_settings.dart';
import '../models/repertoire_line.dart';
import '../features/repertoires/models/repertoire_metadata.dart';
import '../utils/app_messages.dart';
import '../utils/log.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../widgets/chess_board_widget.dart';
import '../features/coverage/widgets/coverage_calculator_widget.dart';
import '../widgets/interactive_pgn_editor.dart';
import '../features/repertoires/repositories/repertoire_catalog_repository.dart';
import '../widgets/pgn_import_dialog.dart';
import '../widgets/repertoire_generation_tab.dart';
import '../features/generate/widgets/generate_position_pane.dart';
import '../features/generate/widgets/position_generation_settings.dart';
import '../widgets/generation/generation_lock_overlay.dart';
import '../features/repertoire/widgets/repertoire_board_pane.dart';
import '../widgets/layout/bottom_pane.dart';
import '../widgets/layout/repertoire_status_bar.dart';
import '../widgets/chapter_list_body.dart' show ChapterPick;
import '../features/repertoires/widgets/repertoire_list_body.dart';
import '../widgets/repertoire_lines_browser.dart';
import '../constants/ui_breakpoints.dart';
import '../features/repertoire/models/repertoire_reload_summary.dart';
import '../features/repertoire/widgets/repertoire_settings_body.dart';
import '../features/repertoire/widgets/repertoire_reload_dialog.dart';
import '../features/repertoire/widgets/repertoire_toolbar.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../features/repertoire/widgets/repertoire_shortcuts.dart';
import '../features/repertoire/widgets/repertoire_nav_controls.dart';
import '../features/repertoire/widgets/repertoire_tab_labels.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/pgn/pgn_annotation_panel.dart';
import '../services/jobs/repertoire_job.dart';
import '../features/audit/models/audit_finding.dart';
import '../features/audit/models/ephemeral_finding_preview.dart';
import '../features/audit/services/audit_board_annotations.dart';
import '../features/audit/widgets/audit_config_panel.dart';
import '../features/audit/widgets/audit_findings_panel.dart';
import '../features/audit/widgets/ephemeral_finding_bar.dart';
import '../features/traps/widgets/trap_navigation_buttons.dart';
import '../features/traps/widgets/trap_tour_bar.dart';
import '../features/traps/widgets/traps_browser.dart';
import '../widgets/engine/floating_board_preview.dart';
import '../features/repertoire/controllers/repertoire_layout_prefs.dart';
import '../features/repertoire/widgets/repertoire_workspace_panel.dart';
import '../design_system/components/name_entry_dialog.dart';
import '../features/repertoire/services/repertoire_outline_service.dart';
import '../features/repertoire/widgets/build_config_screen.dart';
import '../features/repertoire/widgets/repertoire_outline_controls.dart';
import '../features/repertoire/widgets/repertoire_database_pane.dart';
import '../features/traps/controllers/trap_session_controller.dart';
import '../features/traps/services/trap_line_builder.dart';
import 'package:chess_auto_prep/chess_core/generation/trap_line_info.dart';
import '../theme/app_colors.dart';
import '../widgets/layout/jobs_panel.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';
import '../models/board_annotation.dart';
import '../models/explorer_response.dart';
import '../utils/chess_utils.dart' show sanToUci;
import '../features/repertoires/widgets/repertoire_chapters_screen.dart';
import '../features/repertoires/widgets/repertoire_selection_screen.dart';
import '../features/repertoire/controllers/generation_notification_router.dart';
import '../features/repertoire/controllers/audit_entry_router.dart';
import '../features/repertoire/controllers/repertoire_outline_controller.dart';
import '../features/repertoire/models/repertoire_outline.dart';
import '../features/repertoire/widgets/repertoire_outline_panel.dart';
import '../features/repertoire/widgets/repertoire_loading_frame.dart';
import '../features/planner/controllers/plan_runner.dart';
import '../features/planner/widgets/plan_build_screen.dart';
import '../features/planner/services/plan_data_source.dart';
import '../features/planner/widgets/plan_runner_banner.dart';
import '../services/generation/generation_config.dart';
import '../services/generation/generation_presets.dart';
import '../constants/chess_constants.dart';
import '../design_system/layout/workspace_navigation_controller.dart';
import '../design_system/layout/workspace_shell.dart';
import '../app/navigation/workspace_destination_toolbar.dart';

import '../services/storage/app_paths.dart';

part 'repertoire/repertoire_screen_layout.dart';
part 'repertoire/repertoire_screen_session.dart';
part 'repertoire/repertoire_screen_tabs.dart';

class RepertoireScreen extends StatefulWidget {
  const RepertoireScreen({super.key});

  @override
  State<RepertoireScreen> createState() => _RepertoireScreenState();
}

/// Fields and small shared helpers for [_RepertoireScreenState].
///
/// The heavier member groups (layout builders, tab content builders, trap
/// handling, session wiring) live in private mixins under `repertoire/` —
/// see the `part` directives at the top of this file.
abstract class _RepertoireScreenStateBase extends State<RepertoireScreen>
    with TickerProviderStateMixin {
  late final BuilderWorkspaceController _controller;
  final _workspaceNavigation = WorkspaceNavigationController();
  AppState? _appState;
  late final GenerationSessionController _generationController =
      GenerationSessionController(
        databases: context.read<EvalDatabaseSettings>(),
        jobs: _jobManager,
        enginePool: context.read<StockfishPool>(),
        engineLifecycle: context.read<EngineLifecycle>(),
        publication: context.read<GenerationPublicationFactory>()(),
        artifacts: context.read<GenerationArtifacts>(),
      );
  late final AuditSessionController _auditController = AuditSessionController(
    service: RepertoireAuditService(pool: context.read<StockfishPool>()),
    prepareEngine: () => context.read<EngineLifecycle>().enterGeneration(1),
    releaseEngine: () => context.read<EngineLifecycle>().exitGeneration(),
  );

  /// Open/closed state of the bottom pane. Owned here rather than reached
  /// into through a GlobalKey, so opening a tab is a call that always lands.
  final BottomPaneController _bottomPane = BottomPaneController();
  final GlobalKey<AuditFindingsPanelState> _findingsPanelKey =
      GlobalKey<AuditFindingsPanelState>();
  bool _isCompactLayout = false;

  /// Whether pressing Audit means "configure a run" or "show me what the
  /// last one found".
  static const AuditEntryRouter _auditEntry = AuditEntryRouter();

  /// Guards against stacking a second copy of a config route when the same
  /// entry point is triggered twice (menu, shortcut, jobs panel).
  bool _configRouteOpen = false;

  /// Whether the run that just finished was a board-side position generation.
  /// One that was should leave the reader where they started it, so the Lines
  /// surface is not pushed over the board they were generating from.
  bool _lastRunWasPositionGeneration = false;

  final JobManager _jobManager = JobManager.instance;

  final BoardPreviewController _boardPreview = BoardPreviewController();
  final NavigationStack _navigationStack = NavigationStack();

  bool _boardFlipped = false;

  /// Decides what a generation notification means for this screen (run just
  /// ended? re-cluster?). Stateful, so it lives outside
  /// the listener where it can be tested.
  final GenerationNotificationRouter _generationRouter =
      GenerationNotificationRouter();

  /// Missing-move finding currently previewed on the board — the move played
  /// for looking at only, never written to the tree.
  EphemeralFindingPreview? _ephemeralPreview;

  /// Loaded traps, their position index, and the tour's open/closed state.
  late final TrapSessionController _trapSession = TrapSessionController(
    loadFile: context.read<GenerationArtifacts>().readTraps,
  );
  final GlobalKey<TrapTourBarState> _trapTourKey =
      GlobalKey<TrapTourBarState>();

  final CoverageController _coverageController = CoverageController();

  late final TabController _toolsTabController;

  /// Wide layout only: Engine | Database | Tree tabs inside the analysis
  /// panel on the right — the PGN editor stays visible in the middle column
  /// and the outline (chapters and lines) holds the left column.
  late final TabController _sidePanelTabController;

  /// Persisted with the rest of the Builder layout, so the source you chose
  /// is the one the Database pane opens on next time.
  int get _databaseSource => _layout.databaseSource;
  bool _showTrapsInLinesTab = false;

  /// The repertoire as chapters, folders and lines — the left column. Reads
  /// the folder on disk; the screen tells it which chapter is active.
  late final RepertoireOutlineController _outline;

  /// The outline column shows the plain chapter/line tree by default; this
  /// swaps it for the metrics browser (coverage, ease, coherence).
  bool _showLineMetrics = false;

  /// The repertoire folder the outline is currently reading, so a chapter
  /// switch inside the same repertoire only refreshes rather than reopens.
  String? _outlineRoot;

  /// Identity of the last PGN text the outline was refreshed for. A save
  /// replaces [BuilderWorkspaceController.repertoirePgn], which is the signal that
  /// the chapter's lines may have changed.
  String? _outlinePgnSeen;

  /// The chapter path the outline was last synced for.
  String? _outlineChapterSeen;

  /// Runs a planned build: creates the chapters, then generates them one by
  /// one through [_generationController]. Lives on the screen so it outlives
  /// the planner route.
  late final PlanRunner _planRunner;

  /// Persisted wide-layout shape: side panel collapsed/width, board column
  /// size. Shrinking the board is how the user hands width to the engine
  /// lines and PGN beside it.
  final RepertoireLayoutPrefs _layout = RepertoireLayoutPrefs();

  String? _lastRepertoireId;

  final FocusNode _focusNode = FocusNode();
  final GlobalKey _linesPreviewStackKey = GlobalKey();

  bool _navigatingToFinding = false;

  void _updateCompactLayout(bool isCompact) {
    if (_isCompactLayout == isCompact) return;
    _isCompactLayout = isCompact;
    setState(() {});
  }

  /// Bring the Lines/Draft/Session surface into view: the second tab when
  /// compact, the outline column (expanding it if collapsed) when wide.
  void _showLinesSurface() {
    if (_isCompactLayout) {
      _toolsTabController.animateTo(1);
    } else {
      unawaited(_layout.setOutlinePanelCollapsed(false));
    }
  }

  void _openBottomPane(BottomPaneTab tab) => _bottomPane.open(tab);

  void _toggleBottomPane(BottomPaneTab tab) => _bottomPane.toggle(tab);

  void _closeBottomPane() => _bottomPane.close();

  /// Name shown in a config route's app bar — the chapter's own name, which
  /// is what the breadcrumb title shows too.
  String get _configRouteTitle =>
      _controller.document.currentRepertoire?.name ?? '';

  /// Reveal generation beside the board at its current position.
  Future<void> _openGenerateTab() async {
    if (!mounted) return;
    unawaited(_layout.setDatabaseSource(3));
    if (_isCompactLayout) {
      _toolsTabController.animateTo(2);
    } else {
      unawaited(_layout.setAnalysisCollapsed(false));
      _sidePanelTabController.animateTo(1);
    }
    _reclaimFocus();
  }

  /// Line planning and trimming use their own configuration route.
  Future<void> _openLineBuildDialog({
    bool cutOnly = false,
    TreeBuildConfig? initialConfig,
  }) async {
    if (_configRouteOpen) return;
    final document = _controller.document;
    final repertoire = document.currentRepertoire;
    var admittedGeneration = document.loadGeneration;
    final title = _configRouteTitle;
    final fen = _controller.board.fen;
    final isWhite = document.isRepertoireWhite;
    final moves = List<String>.unmodifiable(
      _controller.board.currentMoveSequence,
    );
    final startFen = _controller.board.startingFen ?? kStandardStartFen;
    final lineMoves = List<List<String>>.unmodifiable([
      for (final line in document.repertoireLines)
        List<String>.unmodifiable(line.moves),
    ]);
    bool sourceIsCurrent() =>
        mounted &&
        document.isCurrent(admittedGeneration) &&
        !document.isLoading &&
        document.loadError == null &&
        document.repertoirePgn != null &&
        document.currentRepertoire?.filePath == repertoire?.filePath;
    if (!sourceIsCurrent()) return;
    late final Route<void> route;
    bool isCurrent() => route.isCurrent && sourceIsCurrent();
    route = LegacyPageRoute<void>(
      builder: (_) => BuildConfigScreen(
        repertoireName: title,
        title: cutOnly
            ? 'Cut lines'
            : initialConfig?.isChessDbBook == true
            ? 'Build ChessDB repertoire'
            : 'Build planned lines',
        startSignal: _generationController,
        hasStarted: () => _generationController.isGenerating,
        child: RepertoireGenerationTab(
          cutOnly: cutOnly,
          initialConfig: initialConfig,
          fen: fen,
          isWhiteRepertoire: isWhite,
          currentRepertoire: repertoire,
          currentMoveSequence: moves,
          repertoireStartFen: startFen,
          generationController: _generationController,
          existingLineMoves: lineMoves,
          onTrimLines: (droppedKeys) async {
            if (!isCurrent()) return null;
            final result = await document.deleteLines([
              for (final line in document.repertoireLines)
                if (droppedKeys.contains(line.moves.join(' '))) line,
            ], expectedGeneration: admittedGeneration);
            if (result == null) return null;
            final refreshed = result.refreshedGeneration;
            if (refreshed != null && document.isCurrent(refreshed)) {
              admittedGeneration = refreshed;
            }
            return (
              removed: result.removed,
              remainingMoves: !isCurrent() || result.remainingLines == null
                  ? null
                  : List<List<String>>.unmodifiable([
                      for (final line in result.remainingLines!)
                        List<String>.unmodifiable(line.moves),
                    ]),
            );
          },
          createPublicationReceiver: () =>
              isCurrent() ? document.publishedDocumentReceiver : null,
          onCreateStudy: (name, pgn) async {
            final importer = context.read<StudyImportController>();
            final app = context.read<AppState>();
            final labels = AppLocalizations.of(context);
            try {
              final result = await importer.publishStudy(name: name, pgn: pgn);
              if (!mounted) return;
              final path = result.studyPath;
              if (path == null) {
                showAppSnackBar(
                  context,
                  studyImportFailureLabel(
                    labels,
                    result.failure ?? StudyImportFailure.publication,
                  ),
                  isError: true,
                  actionLabel: labels.studyImportReviewAction,
                  onAction: () => app.setMode(AppMode.study),
                );
                return;
              }
              await _workspaceNavigation.maybePop();
              if (mounted) app.switchToStudyEdit(path: path);
            } on StudyImportRejected catch (error) {
              if (!mounted) return;
              showAppSnackBar(
                context,
                studyImportFailureLabel(labels, error.failure),
                isError: true,
              );
            }
          },
        ),
      ),
    );
    _configRouteOpen = true;
    try {
      await _workspaceNavigation.push(route);
    } finally {
      _configRouteOpen = false;
    }
    if (!mounted) return;
    if (_generationController.isGenerating) _openBottomPane(BottomPaneTab.jobs);
    _reclaimFocus();
  }

  /// Opens the audit config full-screen, the same way.
  Future<void> _openAuditConfigRoute() async {
    if (_configRouteOpen) return;
    _configRouteOpen = true;
    final tree = _controller.document.openingGraph;
    final path = _repertoireFilePath;
    final isWhite = _controller.document.isRepertoireWhite;
    final label = _controller.document.currentRepertoire?.name;
    await _workspaceNavigation.push(
      LegacyPageRoute<void>(
        builder: (_) => BuildConfigScreen(
          repertoireName: _configRouteTitle,
          title: 'Check this chapter',
          startSignal: _auditController,
          hasStarted: () => _auditController.isAuditing,
          child: AuditConfigPanel(
            openingTree: _controller.document.openingGraph,
            isWhiteRepertoire: _controller.document.isRepertoireWhite,
            currentFen: _controller.board.fen,
            currentMoveSequence: _controller.board.currentMoveSequence,
            repertoireFilePath: _repertoireFilePath,
            onStart: (config, startFen) {
              if (!mounted || tree == null) return;
              unawaited(
                _auditController.launch(
                  config: config,
                  tree: tree,
                  isWhiteRepertoire: isWhite,
                  jobManager: _jobManager,
                  repertoireLabel: label,
                  repertoireFilePath: path,
                  startFen: startFen,
                ),
              );
              _openBottomPane(BottomPaneTab.findings);
            },
          ),
        ),
      ),
    );
    _configRouteOpen = false;
    if (!mounted) return;
    _reclaimFocus();
  }

  void _openAuditDialog({bool forceConfig = false}) {
    final target = _auditEntry.resolve(
      forceConfig: forceConfig,
      auditHasSomethingToShow:
          _auditController.isAuditing || _auditController.hasResults,
    );
    switch (target) {
      case AuditEntry.findings:
        _openBottomPane(BottomPaneTab.findings);
      case AuditEntry.config:
        unawaited(_openAuditConfigRoute());
    }
  }

  String? get _repertoireFilePath =>
      _controller.document.currentRepertoire?.filePath;

  /// Run [action] on the findings panel, but only while the findings panel is
  /// the thing on screen — the bottom pane open, showing the Findings tab.
  ///
  /// Returns whether the shortcut was handled, so an unhandled key falls
  /// through to whatever else claims it rather than being swallowed by a
  /// panel the user cannot see.
  bool _whenFindingsPanelHasKeys(
    bool Function(AuditFindingsPanelState) action,
  ) {
    if (!_bottomPane.isShowing(BottomPaneTab.findings)) return false;
    final panel = _findingsPanelKey.currentState;
    return panel != null && action(panel);
  }

  void _reclaimFocus() => reclaimFocusAfterFrame(
    _focusNode,
    mounted: () =>
        mounted &&
        !_workspaceNavigation.hasDestination &&
        (_appState?.currentMode == AppMode.repertoire),
  );

  // Outline column actions, implemented on the concrete state and called
  // from the layout mixin.
  Future<int?> _openChapterPath(String path);
  Future<void> _openOutlineLine(String chapterPath, OutlineLine line);
  Future<void> _generateIntoChapter(String chapterPath);
  Future<void> _auditChapter(String chapterPath);
  void _trainChapter(String chapterPath);
  void _trainOutlineLine(String chapterPath, OutlineLine line);
  Future<void> _openPlanner();
}

class _RepertoireScreenState extends _RepertoireScreenStateBase
    with _RepertoireSessionHandlers, _RepertoireTabContent, _RepertoireLayout {
  @override
  void initState() {
    super.initState();

    _toolsTabController = TabController(length: 4, vsync: this);
    _sidePanelTabController = TabController(length: 2, vsync: this);
    _outline = RepertoireOutlineController(
      service: context.read<RepertoireOutlineService>(),
      catalog: context.read<RepertoireCatalogRepository>(),
      onActiveChapterMoved: _onActiveChapterMoved,
    );
    _planRunner =
        PlanRunner(
            generation: _generationController,
            outline: context.read<RepertoireOutlineService>(),
          )
          ..onChapterChanged = _onPlannedChapterChanged
          ..addListener(_onPlanRunnerChanged);
    _layout.addListener(_onLayoutChanged);
    unawaited(_layout.load());
    _workspaceNavigation.addListener(_onAppStateChanged);
    _controller = context.read<BuilderLifetime>().workspace;
    _controller.addListener(_onRepertoireChanged);
    _generationController.addListener(_onGenerationChanged);
    _auditController.addListener(_onAuditChanged);
    _coverageController.addListener(_onCoverageChanged);
    _trapSession.addListener(_onTrapsChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      _appState = appState;
      appState.addListener(_onAppStateChanged);
      // Recovery may restore the application-owned workspace before this
      // route is first mounted. Adopt its existing document presentation.
      _onRepertoireChanged();

      if (appState.hasPending<OpenBuilder>()) {
        _onAppStateChanged();
      }
    });
  }

  bool _handoffCheckQueued = false;
  void _onAppStateChanged() {
    if (!mounted || _handoffCheckQueued) return;
    _handoffCheckQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handoffCheckQueued = false;
      if (mounted) unawaited(_applyPendingHandoff());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _applyPendingHandoff() async {
    // Preserve the document underlying an open picker/configuration. A new
    // source request waits until that destination closes and generation ends.
    if (_workspaceNavigation.hasDestination ||
        _generationController.isGenerating) {
      return;
    }
    final appState = _appState;
    if (appState == null) return;
    if (appState.currentMode != AppMode.repertoire) return;
    _reclaimFocus();

    final handoff = appState.takeHandoff<OpenBuilder>();
    if (handoff == null) return;

    final document = _controller.document;
    final moves = handoff.moveSequence == null
        ? null
        : List<String>.of(handoff.moveSequence!);
    // Own this request's load, including a same-file request that supersedes
    // pending work. A ready document needs no reload or asynchronous gap.
    final load =
        document.currentRepertoire?.filePath != handoff.repertoirePath ||
            handoff.reloadFromDisk ||
            document.isLoading ||
            document.loadError != null ||
            document.repertoirePgn == null
        ? document.setRepertoire(
            RepertoireMetadata(
              filePath: handoff.repertoirePath,
              name: p.basenameWithoutExtension(handoff.repertoirePath),
              lastModified: DateTime.now(),
            ),
          )
        : null;
    final generation = document.loadGeneration;
    if (load != null) await load;
    if (!mounted ||
        !document.isCurrent(generation) ||
        document.isLoading ||
        document.loadError != null ||
        document.repertoirePgn == null ||
        document.currentRepertoire?.filePath != handoff.repertoirePath ||
        appState.currentMode != AppMode.repertoire ||
        appState.hasPending<OpenBuilder>() ||
        _workspaceNavigation.hasDestination ||
        _generationController.isGenerating) {
      return;
    }

    if (handoff.lineId != null) {
      final line = document.repertoireLines
          .where((line) => line.id == handoff.lineId)
          .firstOrNull;
      if (line != null) _controller.selectLine(line);
    }
    if (moves != null) _controller.composeMoves(moves);
  }

  void _onTrapsChanged() {
    if (mounted) setState(() {});
  }

  void _onLayoutChanged() {
    if (mounted) setState(() {});
  }

  /// [BuilderWorkspaceController.structureVersion] the screen last rebuilt for.
  /// A notification that leaves it unchanged is a cursor move, which only
  /// the position zones need to hear about.
  int _structureSeen = -1;
  String? _lastArtifactSource;

  /// The repertoire the colour question has already been put for, and whether
  /// that dialog is on screen right now.
  ///
  /// The dialog is dismissable ("Not now"), but the check that posts it lives
  /// outside the repertoire-switch guard and runs on *every* structure change
  /// — so without these two, dismissing it once meant it came back on the
  /// next move played, and a burst of structure changes could stack several
  /// copies of it. Asked once per repertoire per session; switching away and
  /// back asks again, which is what "asks again next time" meant.
  String? _colorPromptAskedFor;
  bool _colorPromptOpen = false;

  void _onRepertoireChanged() {
    if (!mounted) return;

    // A pure cursor move reaches the board, PGN, outline and analysis zones
    // through their own [ListenableBuilder]s (see [_cursorScoped]); the rest
    // of the screen — toolbar, banners, bottom pane, status bar — shows
    // nothing that depends on the cursor and stays as built.  Only the
    // ephemeral-preview reset below needs the screen itself when the user
    // navigates away from a previewed finding.
    final structureChanged = _controller.structureVersion != _structureSeen;
    if (!structureChanged &&
        (_ephemeralPreview == null || _navigatingToFinding)) {
      return;
    }
    _structureSeen = _controller.structureVersion;

    String? newRepertoireId;
    setState(() {
      // Clear ephemeral state when the user navigates normally (not via finding).
      if (!_navigatingToFinding) _ephemeralPreview = null;

      if (_controller.document.currentRepertoire != null &&
          !_controller.document.isLoading) {
        final currentId = _controller.document.currentRepertoire!.filePath;
        if (currentId != _lastRepertoireId) {
          _auditController.onRepertoireSwitching(_lastRepertoireId);
          _lastRepertoireId = currentId;
          _boardFlipped = !_controller.document.isRepertoireWhite;
          // Drop the old repertoire's trees now, then bring in whatever this
          // one saved — the last full build and every probe since.
          _generationController.clearTree();
          unawaited(_generationController.loadSavedTreeFor(currentId));
          _coverageController.clear();
          // A tour from the previous repertoire's traps makes no sense here.
          _trapSession.endTourForRepertoireSwitch();
          context.read<EngineSettings>().probabilityStartMoves =
              _controller.document.rootMoves;
          unawaited(_trapSession.loadFromFile(currentId));
          newRepertoireId = currentId;
        }

        final source = _controller.document.repertoirePgn;
        if (!_generationController.isGenerating &&
            source != _lastArtifactSource) {
          _lastArtifactSource = source;
          if (newRepertoireId == null) {
            _generationController.clearTree();
            unawaited(_generationController.loadSavedTreeFor(currentId));
            _trapSession.endTourForRepertoireSwitch();
            unawaited(_trapSession.loadFromFile(currentId));
          }
        }

        if (_controller.document.needsColorSelection &&
            !_colorPromptOpen &&
            _colorPromptAskedFor != currentId) {
          _colorPromptAskedFor = currentId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_showColorSelectionDialog());
          });
        }
      }
    });

    if (newRepertoireId != null) {
      unawaited(_auditController.tryRestore(newRepertoireId!));
    }
    _syncOutline();
  }

  // ── Outline (left column) ────────────────────────────────────────

  /// Keep the outline pointed at the open repertoire and fresh after saves.
  ///
  /// Called from every controller notification, so it returns immediately
  /// unless the chapter or its PGN text actually changed.
  void _syncOutline() {
    final current = _controller.document.currentRepertoire;
    if (current == null || _controller.document.isLoading) return;
    final generation = _controller.document.loadGeneration;
    final isWhite = _controller.document.isRepertoireWhite;
    final chapterPath = current.filePath;
    final pgn = _controller.document.repertoirePgn;
    final sameChapter =
        _outlineChapterSeen != null &&
        p.equals(_outlineChapterSeen!, chapterPath);
    if (sameChapter && identical(pgn, _outlinePgnSeen)) return;

    // Claim both halves of the cache key before awaiting. They used to be
    // written on opposite sides of the await, so a notification arriving
    // mid-flight saw a half-updated key, failed the early return and started
    // a duplicate open() against the same chapter.
    final pgnChanged = !identical(pgn, _outlinePgnSeen);
    _outlineChapterSeen = chapterPath;
    _outlinePgnSeen = pgn;

    unawaited(() async {
      final root = await _repertoireRootFor(chapterPath);
      if (!mounted || !_controller.document.isCurrent(generation)) return;
      final sameRoot = _outlineRoot != null && p.equals(_outlineRoot!, root);
      if (!sameRoot) {
        _outlineRoot = root;
        await _outline.open(
          rootPath: root,
          activeChapterPath: chapterPath,
          isWhite: isWhite,
        );
      } else {
        if (_outline.activeChapterPath == null ||
            !p.equals(_outline.activeChapterPath!, chapterPath)) {
          _outline.setActiveChapter(chapterPath);
        }
        if (pgnChanged) await _outline.refresh();
      }
    }());
  }

  /// The repertoire folder that holds [chapterPath]: the ancestor directly
  /// under the app's repertoires directory. Chapters may sit in nested
  /// sub-folders, so the immediate parent is not necessarily the root.
  Future<String> _repertoireRootFor(String chapterPath) async {
    try {
      final base = (await AppPaths.repertoiresDirectory()).path;
      var dir = p.dirname(chapterPath);
      if (p.isWithin(base, dir)) {
        while (!p.equals(p.dirname(dir), base)) {
          dir = p.dirname(dir);
        }
        return dir;
      }
    } catch (_) {
      // Fall through to the immediate parent.
    }
    return p.dirname(chapterPath);
  }

  /// The outline renamed, moved or deleted the chapter the board shows.
  void _onActiveChapterMoved(String? newPath) {
    if (!mounted) return;
    if (newPath == null) {
      // The active chapter is gone: fall back to any remaining chapter, or
      // leave the editor on an unsaved buffer.
      final next = _outline.outline?.allChapters.firstOrNull;
      if (next != null) {
        unawaited(_openChapterPath(next.path));
      }
      return;
    }
    final current = _controller.document.currentRepertoire;
    if (current != null && p.equals(current.filePath, newPath)) {
      // Same file, new contents (a line moved in or out): reload in place.
      // Silent, not the reload dialog — we already know what changed, and a
      // summary window over a move the user just made would be noise.
      unawaited(_controller.document.loadRepertoire());
      return;
    }
    unawaited(_openChapterPath(newPath));
  }

  /// Switch the board/editor to the chapter file at [path].
  @override
  Future<int?> _openChapterPath(String path) async {
    final document = _controller.document;
    if (!document.isLoading && document.currentRepertoire?.filePath == path) {
      return document.loadError == null ? document.loadGeneration : null;
    }
    final loading = document.setRepertoire(
      RepertoireMetadata(
        filePath: path,
        name: p.basenameWithoutExtension(path),
        lastModified: DateTime.now(),
      ),
    );
    final generation = document.loadGeneration;
    await loading;
    if (!mounted ||
        !document.isCurrent(generation) ||
        document.loadError != null) {
      return null;
    }
    _reclaimFocus();
    return generation;
  }

  /// A line picked in the outline: switch chapter if needed, then load it.
  @override
  Future<void> _openOutlineLine(String chapterPath, OutlineLine line) async {
    final generation = await _openChapterPath(chapterPath);
    if (!mounted ||
        generation == null ||
        !_controller.document.isCurrent(generation)) {
      return;
    }
    final match = _controller.document.repertoireLines
        .where((l) => l.gameIndex == line.gameIndex)
        .firstOrNull;
    if (match != null) {
      _selectLine(match);
    } else {
      _controller.composeMoves(line.moves);
    }
  }

  /// "Generate lines into this chapter": make it the active chapter, put the
  /// board on the chapter's root — the moves every line in it shares, or the
  /// start position for an empty chapter — and open the generation setup,
  /// which builds from the board. Generated lines land in the active
  /// chapter's file, so this is what "into this chapter" means.
  @override
  Future<void> _generateIntoChapter(String chapterPath) async {
    final generation = await _openChapterPath(chapterPath);
    if (!mounted ||
        generation == null ||
        !_controller.document.isCurrent(generation)) {
      return;
    }
    _controller.composeMoves(
      _commonPrefix(_controller.document.repertoireLines.map((l) => l.moves)),
    );
    unawaited(_openGenerateTab());
  }

  /// The longest SAN prefix shared by every sequence; empty for no lines.
  static List<String> _commonPrefix(Iterable<List<String>> sequences) {
    List<String>? prefix;
    for (final seq in sequences) {
      if (prefix == null) {
        prefix = List.of(seq);
        continue;
      }
      var n = 0;
      while (n < prefix.length && n < seq.length && prefix[n] == seq[n]) {
        n++;
      }
      prefix = prefix.sublist(0, n);
      if (prefix.isEmpty) break;
    }
    return prefix ?? const [];
  }

  @override
  Future<void> _auditChapter(String chapterPath) async {
    final generation = await _openChapterPath(chapterPath);
    if (!mounted ||
        generation == null ||
        !_controller.document.isCurrent(generation)) {
      return;
    }
    _openAuditDialog(forceConfig: true);
  }

  @override
  void _trainChapter(String chapterPath) {
    context.read<AppState>().switchToTrainer(repertoirePath: chapterPath);
  }

  // ── Planner ──────────────────────────────────────────────────

  void _onPlanRunnerChanged() {
    if (mounted) setState(() {});
  }

  void _onPlannedChapterChanged(String chapterPath) {
    if (!mounted) return;
    unawaited(_outline.refresh());
    final current = _controller.document.currentRepertoire;
    if (current != null && p.equals(current.filePath, chapterPath)) {
      unawaited(_controller.document.loadRepertoire());
    }
  }

  /// Full-width planning mode: answer the forks, get chapters, generate.
  @override
  Future<void> _openPlanner() async {
    if (_controller.document.currentRepertoire == null) return;
    if (_planRunner.isRunning || _generationController.isGenerating) {
      showAppSnackBar(
        context,
        'A build is already running — let it finish or stop it first.',
        isError: true,
      );
      return;
    }
    final root = _outlineRoot;
    if (root == null) return;
    final appState = _appState ?? context.read<AppState>();
    final isWhite = _controller.document.isRepertoireWhite;
    // Reuse the last run's settings only when they were for this colour.
    // With `relativeEval` off the eval window is absolute, so a White window
    // carried onto a Black repertoire prunes every line that is merely equal.
    // (With it on — the default — the window is an offset from the root and
    // colour does not enter into it, but the guard still has to hold for the
    // absolute case.)
    final last = _generationController.lastConfig;
    final base = last != null && last.playAsWhite == isWhite
        ? last
        : TreeBuildConfig.formDefaults(
            startFen: kStandardStartFen,
            playAsWhite: isWhite,
          );
    final databases = context.read<EvalDatabaseSettings>().state.committed;
    if (databases == null) {
      showAppSnackBar(
        context,
        'Load evaluation preferences in Settings before planning.',
        isError: true,
      );
      return;
    }
    final source = DefaultPlanDataSource(
      databases: databases,
      pool: context.read<StockfishPool>(),
      lifecycle: context.read<EngineLifecycle>(),
    );
    final result = await _workspaceNavigation.push<PlanBuildResult>(
      LegacyPageRoute<PlanBuildResult>(
        fullscreenDialog: true,
        builder: (_) => PlanBuildScreen(
          dataSource: source,
          isWhite: isWhite,
          repertoireName: p.basename(root),
          outline: _outline.outline,
          initialMoves: List.of(_controller.board.currentMoveSequence),
          baseConfig: base,
          chesscomUsername: appState.chesscomUsername,
          lichessUsername: appState.lichessUsername,
          defaultElo: base.maiaElo,
        ),
      ),
    );
    if (result == null || !mounted) return;
    _reclaimFocus();
    unawaited(
      _planRunner.run(
        plan: result.plan,
        folderPath: root,
        config: result.config,
        generate: result.generate,
      ),
    );
    if (result.generate) _openBottomPane(BottomPaneTab.jobs);
  }

  @override
  void _trainOutlineLine(String chapterPath, OutlineLine line) {
    context.read<AppState>().switchToTrainer(
      repertoirePath: chapterPath,
      lineId: line.id,
    );
  }

  Future<void> _showColorSelectionDialog() async {
    if (_colorPromptOpen) return;
    _colorPromptOpen = true;
    try {
      await _askRepertoireColor();
    } finally {
      _colorPromptOpen = false;
    }
  }

  Future<void> _askRepertoireColor() async {
    final name =
        _controller.document.currentRepertoire?.name ?? 'this repertoire';
    final isWhite = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Which color is this repertoire for?'),
        content: Text(
          '"$name" doesn\'t say, and nothing in the file does either. '
          'Your answer is saved, so this is asked once.',
        ),
        actions: [
          // Escapable on purpose: the question is worth asking, but not
          // worth trapping someone who only wanted to look at the file.
          // Dismissing leaves the colour unset and asks again next time.
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Not now'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(context, false),
            // Near-black fill + visible outline: a plain black disc is
            // invisible on the dark dialog surface.
            icon: const Stack(
              alignment: Alignment.center,
              children: [
                Icon(Icons.circle, color: AppColors.surface),
                Icon(Icons.circle_outlined, color: AppColors.onSurfaceSoft),
              ],
            ),
            label: const Text('Black'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.circle_outlined),
            label: const Text('White'),
          ),
        ],
      ),
    );
    if (isWhite != null && mounted) {
      await _setRepertoireSide(isWhite);
      // The flip is chosen when a repertoire is opened, which for a file
      // with no colour happens before the colour is known. Re-apply it now
      // rather than leaving a Black repertoire looking at White's side.
      if (mounted) {
        setState(() => _boardFlipped = !_controller.document.isRepertoireWhite);
      }
    }
  }

  Future<void> _setRepertoireSide(bool isWhite) async {
    try {
      await _controller.document.setRepertoireColor(isWhite);
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Playing side was not saved: $error',
        isError: true,
      );
    }
  }

  @override
  void dispose() {
    if (_auditController.isAuditing) {
      _auditController.saveProgress(_repertoireFilePath);
    }
    _bottomPane.dispose();
    _trapSession.removeListener(_onTrapsChanged);
    _trapSession.dispose();
    _layout.removeListener(_onLayoutChanged);
    _layout.dispose();
    _toolsTabController.dispose();
    _sidePanelTabController.dispose();
    _outline.dispose();
    _planRunner.dispose();
    _focusNode.dispose();
    _workspaceNavigation.removeListener(_onAppStateChanged);
    _workspaceNavigation.dispose();
    _boardPreview.dispose();
    _coverageController.removeListener(_onCoverageChanged);
    _coverageController.dispose();
    _auditController.removeListener(_onAuditChanged);
    _auditController.dispose();
    _generationController.removeListener(_onGenerationChanged);
    _generationController.dispose();
    _controller.removeListener(_onRepertoireChanged);

    _appState?.removeListener(_onAppStateChanged);
    _appState = null;

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final root = _buildWorkspaceRoot(context);
    final shell = WorkspaceShell(
      navigation: _workspaceNavigation,
      appBar: PreferredSize(
        preferredSize: root.appBar.preferredSize,
        child: AbsorbPointer(
          absorbing:
              _controller.document.isLoading && _lastRepertoireId != null,
          child: ExcludeFocus(
            excluding:
                _controller.document.isLoading && _lastRepertoireId != null,
            child: LegacyThemeBoundary(child: root.appBar),
          ),
        ),
      ),
      destinationAppBar: WorkspaceDestinationToolbar(
        mode: AppMode.repertoire,
        navigation: _workspaceNavigation,
      ),
      body: LegacyThemeBoundary(child: root.body),
    );
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => Material(
        child: Column(
          children: [
            for (final copy in _controller.uncertainCopies)
              MaterialBanner(
                content: Text(
                  AppLocalizations.of(
                    context,
                  ).builderCopyNeedsVerification(copy.destination),
                ),
                actions: [
                  TextButton(
                    onPressed: _controller.copyInProgress(copy.draftKey)
                        ? null
                        : () => unawaited(_inspectDraftCopy(copy)),
                    child: Text(
                      AppLocalizations.of(context).builderInspectCopy,
                    ),
                  ),
                ],
              ),
            if (_controller.saveError != null)
              MaterialBanner(
                content: Text(
                  AppLocalizations.of(context).builderLineSaveFailed,
                ),
                actions: [
                  TextButton(
                    onPressed: () => unawaited(_controller.saveActiveLine()),
                    child: Text(AppLocalizations.of(context).retry),
                  ),
                ],
              ),
            if (_controller.sourceChanged)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(AppLocalizations.of(context).builderSourceChanged),
              ),
            if (_controller.captureWorkspace().activeKey != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('save-builder-draft-copy'),
                  onPressed: _saveCurrentDraft,
                  icon: const Icon(Icons.save_as),
                  label: Text(
                    AppLocalizations.of(context).builderSaveDraftCopy,
                  ),
                ),
              ),
            if (_controller.retainedDrafts.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: PopupMenuButton(
                  tooltip: AppLocalizations.of(
                    context,
                  ).builderRetainedDraftsTooltip,
                  itemBuilder: (context) => [
                    for (final draft in _controller.retainedDrafts)
                      PopupMenuItem(
                        value: draft,
                        child: Text(
                          '${draft.repertoire?.name ?? AppLocalizations.of(context).builderScratch} · ${draft.title}',
                        ),
                      ),
                  ],
                  onSelected: (draft) async {
                    try {
                      await _controller.openRetainedDraft(draft);
                    } catch (error) {
                      if (context.mounted) {
                        showAppSnackBar(
                          context,
                          AppLocalizations.of(context).builderDraftRetained,
                          isError: true,
                        );
                      }
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      AppLocalizations.of(context).builderRetainedDraftCount(
                        _controller.retainedDrafts.length,
                      ),
                    ),
                  ),
                ),
              ),
            Expanded(child: shell),
          ],
        ),
      ),
    );
  }

  ({PreferredSizeWidget appBar, Widget body}) _buildWorkspaceRoot(
    BuildContext context,
  ) {
    if (_controller.document.isLoading && _lastRepertoireId == null) {
      return (
        appBar: RepertoireToolbar(
          title: const Text('Repertoire Builder'),
          onRecoverAnalysis: () => unawaited(
            showGenerationRecovery(
              context,
              artifacts: context.read<GenerationArtifacts>(),
            ),
          ),
          onSettingsClosed: _reclaimFocus,
        ),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading repertoire...'),
            ],
          ),
        ),
      );
    }

    final loadError = _controller.document.loadError;
    if (_controller.document.currentRepertoire == null &&
        _controller.captureWorkspace().activeKey != null) {
      return (
        appBar: RepertoireToolbar(
          title: Text(AppLocalizations.of(context).builderScratch),
          showSelectRepertoireAction: true,
          onSettingsClosed: _reclaimFocus,
          onSelectRepertoire: _showRepertoireSelection,
        ),
        body: RepertoireLoadingFrame(
          loadError: loadError,
          onDismissError: _controller.document.dismissLoadError,
          isLoading: _controller.document.isLoading,
          child: _buildShortcuts(child: _buildCompactLayout()),
        ),
      );
    }
    if (loadError != null && _controller.document.currentRepertoire == null) {
      return (
        appBar: RepertoireToolbar(
          title: const Text('Repertoire Builder'),
          onRecoverAnalysis: () => unawaited(
            showGenerationRecovery(
              context,
              artifacts: context.read<GenerationArtifacts>(),
            ),
          ),
          showSelectRepertoireAction: true,
          onSettingsClosed: _reclaimFocus,
          onSelectRepertoire: _showRepertoireSelection,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 64,
                  color: AppColors.danger,
                ),
                const SizedBox(height: 16),
                Text(loadError, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () =>
                      unawaited(_controller.document.loadRepertoire()),
                  icon: const Icon(Icons.refresh),
                  label: Text(AppLocalizations.of(context).retry),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_controller.document.currentRepertoire == null) {
      return (
        appBar: RepertoireToolbar(
          title: const Text('Repertoire Builder'),
          onRecoverAnalysis: () => unawaited(
            showGenerationRecovery(
              context,
              artifacts: context.read<GenerationArtifacts>(),
            ),
          ),
          showSelectRepertoireAction: true,
          onSettingsClosed: _reclaimFocus,
          onSelectRepertoire: _showRepertoireSelection,
        ),
        body: RepertoireListBody(
          onRepertoireSelected: _openSelectedRepertoire,
          onSelected: _openSelectedRepertoire,
        ),
      );
    }

    final repertoire = _controller.document.currentRepertoire!;
    final generation = _controller.document.loadGeneration;
    return (
      appBar: RepertoireToolbar(
        title: RepertoireBreadcrumbTitle(
          key: ValueKey(generation),
          chapter: repertoire,
          catalog: context.read<RepertoireCatalogRepository>(),
          isCurrent: () =>
              mounted &&
              _controller.document.isCurrent(generation) &&
              !_generationController.isGenerating,
          enabled: !_generationController.isGenerating,
          onSwitchRepertoire: _showRepertoireSelection,
          onSelectChapter: (chapter) =>
              unawaited(_openChapterPath(chapter.filePath)),
          onAddChapter: _addChapterInline,
          onViewChapters: _showChapterList,
        ),
        isGenerating: _generationController.isGenerating,
        isGenerationPaused: _generationController.isPaused,
        isExpectimaxProbe: _generationController.isExpectimaxProbe,
        showTrainAction: true,
        showSelectRepertoireAction: true,
        generationLocked: _generationController.isGenerating,
        onSettingsClosed: _reclaimFocus,
        onSelectRepertoire: _showRepertoireSelection,
        onTrainRepertoire: _trainRepertoire,
        onOpenGeneration: _openGenerateTab,
        onPlanBuild: () => unawaited(_openPlanner()),
        onOpenAudit: _openAuditDialog,
        onImportPgn: _importPgn,
        onReload: _reloadRepertoire,
        onRecoverAnalysis: () => unawaited(
          showGenerationRecovery(
            context,
            path: repertoire.filePath,
            artifacts: context.read<GenerationArtifacts>(),
          ),
        ),
        onGenerationSettings: () =>
            showPositionGenerationSettings(context, _generationController),
        trapNavigation: _buildTrapNavigation(),
        repertoireSettingsBuilder: (_) => RepertoireSettingsBody(
          isWhiteRepertoire: _controller.document.isRepertoireWhite,
          sideChangeEnabled: !_generationController.isGenerating,
          onSideChanged: _setRepertoireSide,
          boardSize: _layout.boardSize,
          onBoardSizeChanged: _layout.setBoardSize,
        ),
      ),
      body: RepertoireLoadingFrame(
        loadError: loadError,
        onDismissError: _controller.document.dismissLoadError,
        isLoading: _controller.document.isLoading,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _reclaimFocus,
          child: _buildShortcuts(
            child: Column(
              children: [
                // Paused builds free the tab and the engine; a slim banner
                // keeps resume/discard in reach.
                if (_planRunner.isRunning)
                  PlanRunnerBanner(
                    runner: _planRunner,
                    isPaused: _generationController.isPaused,
                    onPause: _generationController.pauseBuild,
                    onResume: _generationController.resumeBuild,
                  )
                else if (_generationController.isGenerating &&
                    _generationController.isPaused)
                  GenerationPausedBanner(
                    onResume: _generationController.resumeBuild,
                    onDiscard: _confirmDiscardBuild,
                  ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final isCompact =
                              constraints.maxWidth < kCompactBreakpoint;
                          if (isCompact != _isCompactLayout) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) _updateCompactLayout(isCompact);
                            });
                          }
                          if (isCompact) {
                            return _buildCompactLayout();
                          }
                          return _buildWideLayout();
                        },
                      ),
                      // Lock the whole tab (board, PGN editor, engine panes)
                      // while a build actively runs; the bottom pane and status
                      // bar stay reachable below for job progress.
                      // A probe borrows the engine but leaves the board and
                      // the panes alone — browsing the database while it
                      // runs is the point.
                      if (_generationController.isGenerating &&
                          !_generationController.isPaused &&
                          !_generationController.isExpectimaxProbe)
                        GenerationLockOverlay(
                          statusText: _generationController.progress.status,
                          canPause: _generationController.canPause,
                          isCancelling: _generationController.isCancelling,
                          onPause: _generationController.pauseBuild,
                          isAwaitingMasterGames:
                              _generationController.isAwaitingMasterGames,
                          onSkipMasterGames:
                              _generationController.skipMasterGamesDownload,
                        ),
                    ],
                  ),
                ),
                if (_trapSession.tourVisible && _trapSession.index != null)
                  TrapTourBar(
                    key: _trapTourKey,
                    trapIndex: _trapSession.index!,
                    initialTrap: _trapSession.tourInitialTrap,
                    onClose: _trapSession.closeTour,
                    // Each stop loads the annotated trap line into the PGN
                    // tab, where the moves are clickable.
                    onShowTrap: _showTrapLine,
                  ),
                _buildBottomPane(),
                RepertoireStatusBar(
                  findingsCount: _auditController.activeFindingCount,
                  jobsStatus: _generationController.isGenerating
                      ? (_generationController.isPaused
                            ? 'Paused'
                            : 'Generating...')
                      : _auditController.isAuditing
                      ? (_auditController.isPaused
                            ? 'Audit paused'
                            : 'Auditing...')
                      : null,
                  onFindingsTap: () =>
                      _toggleBottomPane(BottomPaneTab.findings),
                  onJobsTap: () => _toggleBottomPane(BottomPaneTab.jobs),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
