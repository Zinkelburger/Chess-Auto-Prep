/// Repertoire screen - Full-screen repertoire view
/// Shows repertoire positions with board + PGN + context tabs layout.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dartchess/dartchess.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/repertoire_controller.dart';
import '../core/generation_session_controller.dart';
import '../features/audit/controllers/audit_session_controller.dart';
import '../features/coverage/controllers/coverage_controller.dart';
import '../models/engine_settings.dart';
import '../models/repertoire_line.dart';
import '../models/repertoire_metadata.dart';
import '../services/repertoire_service.dart';
import '../utils/app_messages.dart';
import '../utils/log.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/master_games_prompt_banner.dart';
import '../features/coverage/widgets/coverage_calculator_widget.dart';
import '../widgets/pgn_with_analysis_pane.dart';
import '../services/storage/storage_factory.dart';
import '../widgets/app_settings_button.dart';
import '../widgets/pgn_import_dialog.dart';
import '../widgets/repertoire_generation_tab.dart';
import '../widgets/generation/generation_lock_overlay.dart';
import '../widgets/layout/board_zone.dart';
import '../widgets/layout/bottom_pane.dart';
import '../widgets/layout/repertoire_status_bar.dart';
import '../widgets/repertoire_list_body.dart';
import '../widgets/repertoire_lines_browser.dart';
import '../constants/ui_breakpoints.dart';
import '../features/repertoire/models/repertoire_reload_summary.dart';
import '../features/repertoire/widgets/repertoire_options_dialog.dart';
import '../features/repertoire/widgets/repertoire_reload_dialog.dart';
import '../features/repertoire/widgets/repertoire_toolbar.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../features/repertoire/widgets/repertoire_shortcuts.dart';
import '../features/repertoire/widgets/repertoire_nav_controls.dart';
import '../features/repertoire/widgets/repertoire_tab_labels.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/engine/inline_expectimax_bar.dart';
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
import '../features/traps/widgets/traps_tab_content.dart';
import '../widgets/engine/floating_board_preview.dart';
import '../features/repertoire/controllers/repertoire_layout_prefs.dart';
import '../features/repertoire/services/chapter_store.dart';
import '../features/repertoire/widgets/add_chapter_dialog.dart';
import '../features/repertoire/widgets/build_config_screen.dart';
import '../features/repertoire/widgets/repertoire_lines_side_panel.dart';
import '../features/repertoire/widgets/repertoire_tree_pane.dart';
import '../features/repertoire/widgets/repertoire_database_pane.dart';
import '../features/traps/controllers/trap_session_controller.dart';
import '../features/traps/services/trap_line_builder.dart';
import 'package:chess_auto_prep/models/trap_line_info.dart';
import '../services/build_by_playing/build_by_playing_config.dart';
import '../services/build_by_playing/build_by_playing_controller.dart';
import '../services/games_repertoire/games_draft_controller.dart';
import '../theme/app_colors.dart';
import '../widgets/build_by_playing/build_session_board_bar.dart';
import '../widgets/build_by_playing/build_session_pane.dart';
import '../widgets/games_repertoire/draft_review_pane.dart';
import '../widgets/layout/jobs_tab_content.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';
import '../models/board_annotation.dart';
import '../models/explorer_response.dart';
import '../utils/chess_utils.dart' show sanToUci;
import 'repertoire_chapters_screen.dart';
import 'repertoire_selection_screen.dart';
import '../features/repertoire/controllers/build_launcher.dart';
import '../features/repertoire/controllers/generation_notification_router.dart';
import '../features/repertoire/controllers/audit_entry_router.dart';
import '../features/repertoire/controllers/repertoire_outline_controller.dart';
import '../features/repertoire/models/repertoire_outline.dart';
import '../features/repertoire/widgets/repertoire_outline_panel.dart';
import '../features/planner/controllers/plan_runner.dart';
import '../features/planner/widgets/plan_build_screen.dart';
import '../features/planner/widgets/plan_runner_banner.dart';
import '../services/generation/generation_config.dart';
import '../constants/chess_constants.dart';
import '../services/storage/app_paths.dart';

part 'repertoire/repertoire_screen_layout.dart';
part 'repertoire/repertoire_screen_session.dart';
part 'repertoire/repertoire_screen_tabs.dart';

class RepertoireScreen extends StatefulWidget {
  const RepertoireScreen({super.key});

  @override
  State<RepertoireScreen> createState() => _RepertoireScreenState();
}

/// How often the screen may repaint while a generation run reports progress.
const _kGenRebuildInterval = Duration(milliseconds: 250);

/// Fields and small shared helpers for [_RepertoireScreenState].
///
/// The heavier member groups (layout builders, tab content builders, trap
/// handling, session wiring) live in private mixins under `repertoire/` —
/// see the `part` directives at the top of this file.
abstract class _RepertoireScreenStateBase extends State<RepertoireScreen>
    with TickerProviderStateMixin {
  late final RepertoireController _controller;
  AppState? _appState;
  final GenerationSessionController _generationController =
      GenerationSessionController();
  final GlobalKey<RepertoireGenerationTabState> _generationTabKey =
      GlobalKey<RepertoireGenerationTabState>();
  final AuditSessionController _auditController = AuditSessionController();

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

  final JobManager _jobManager = JobManager.instance;

  final BoardPreviewController _boardPreview = BoardPreviewController();
  final NavigationStack _navigationStack = NavigationStack();

  bool _boardFlipped = false;

  /// Decides what a generation notification means for this screen (run just
  /// ended? re-cluster? coalesce the rebuild?). Stateful, so it lives outside
  /// the listener where it can be tested.
  final GenerationNotificationRouter _generationRouter =
      GenerationNotificationRouter();

  /// Coalesces whole-screen rebuilds during generation progress ticks.
  Timer? _genRebuildThrottle;

  /// Missing-move finding currently previewed on the board — the move played
  /// for looking at only, never written to the tree.
  EphemeralFindingPreview? _ephemeralPreview;

  /// Loaded traps, their position index, and the tour's open/closed state.
  final TrapSessionController _trapSession = TrapSessionController();
  final GlobalKey<TrapTourBarState> _trapTourKey =
      GlobalKey<TrapTourBarState>();

  final CoverageController _coverageController = CoverageController();

  late final TabController _toolsTabController;

  /// Wide layout only: Engine | Database | Tree tabs inside the analysis
  /// panel on the right — the PGN editor stays visible in the middle column
  /// and the outline (chapters and lines) holds the left column.
  late final TabController _sidePanelTabController;
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
  /// replaces [RepertoireController.repertoirePgn], which is the signal that
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

  // ── Build-from-games draft session (inline in the Lines/Draft tab) ──
  final GamesDraftController _draftController = GamesDraftController();

  bool get _isDraftActive => _draftController.isActive;

  // ── Build-by-playing session (takes over the Lines/Draft tab) ──
  late final BuildByPlayingController _buildSession;
  bool _wasBuildSessionActive = false;

  bool get _isBuildSessionActive => _buildSession.isActive;

  /// Owns the build-from-games and build-by-playing launch flows
  /// (form → config → controller); the screen only lends it a context.
  late final BuildLauncher _buildLauncher;

  String? _lastRepertoireId;

  /// Reads and creates the chapters of the active repertoire folder.
  final ChapterStore _chapterStore = ChapterStore();

  /// Sibling chapters of the current repertoire folder, for the toolbar
  /// breadcrumb's chapter dropdown. Reloaded whenever the active chapter
  /// changes or chapters are added/renamed/deleted.
  List<RepertoireMetadata> _chapters = [];

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
  String get _configRouteTitle => _controller.currentRepertoire?.name ?? '';

  /// Opens the generation config full-screen. The route closes itself once
  /// the build starts; we then bring the Jobs pane forward so the progress
  /// it kicked off is the first thing back on screen.
  Future<void> _openGenerationDialog() async {
    if (_configRouteOpen) return;
    _configRouteOpen = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BuildConfigScreen(
          repertoireName: _configRouteTitle,
          title: 'Generate from here',
          startSignal: _generationController,
          hasStarted: () => _generationController.isGenerating,
          child: RepertoireGenerationTab(
            key: _generationTabKey,
            fen: _controller.fen,
            isWhiteRepertoire: _controller.isRepertoireWhite,
            currentRepertoire: _controller.currentRepertoire,
            currentMoveSequence: _controller.currentMoveSequence,
            repertoireStartFen: _controller.startingFen ?? kStandardStartFen,
            generationController: _generationController,
            existingLineMoves: [
              for (final line in _controller.repertoireLines) line.moves,
            ],
            onLinesSaved: (lines) {
              _controller.appendNewLines([
                for (final l in lines)
                  (moves: l.moves, title: l.title, pgn: l.pgn),
              ]);
            },
          ),
        ),
      ),
    );
    _configRouteOpen = false;
    if (!mounted) return;
    if (_generationController.isGenerating) _openBottomPane(BottomPaneTab.jobs);
    _reclaimFocus();
  }

  /// Opens the audit config full-screen, the same way.
  Future<void> _openAuditConfigRoute() async {
    if (_configRouteOpen) return;
    _configRouteOpen = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BuildConfigScreen(
          repertoireName: _configRouteTitle,
          title: 'Audit for gaps',
          startSignal: _auditController,
          hasStarted: () => _auditController.isAuditing,
          child: AuditConfigPanel(
            openingTree: _controller.openingTree,
            isWhiteRepertoire: _controller.isRepertoireWhite,
            currentFen: _controller.fen,
            currentMoveSequence: _controller.currentMoveSequence,
            repertoireFilePath: _repertoireFilePath,
            auditService: _auditController.service,
            onConfigChanged: _auditController.onConfigChanged,
            onAuditingChanged: _onAuditingChanged,
            onResultReady: (result) {
              if (mounted) {
                _auditController.onResultReady(result, _repertoireFilePath);
              }
            },
            onLiveFinding: (finding) {
              if (mounted) _auditController.onLiveFinding(finding);
            },
            onProgress: (checked, total) {
              if (mounted) _auditController.onProgress(checked, total);
            },
          ),
        ),
      ),
    );
    _configRouteOpen = false;
    if (!mounted) return;
    _reclaimFocus();
  }

  void _onAuditingChanged(bool auditing) {
    if (!mounted) return;
    _auditController.onAuditingChanged(
      auditing,
      _jobManager,
      _controller.currentRepertoire?.name ?? 'Audit',
    );
    if (auditing) _openBottomPane(BottomPaneTab.findings);
  }

  void _discoverTrapsFromRepertoire() {
    final path = _repertoireFilePath;
    if (path == null) return;
    unawaited(_openGenerationDialog());
    _seedGenerationWhenReady(pgnPaths: [path]);
  }

  /// Seeds the DB-explorer source on the generation form once its route is on
  /// screen. The form lives in a pushed route now, so its state is not
  /// reachable in the same frame the push is requested — hence the retries,
  /// the same shape [RepertoireGenerationTabState] already uses internally to
  /// wait for its own form.
  void _seedGenerationWhenReady({
    required List<String> pgnPaths,
    bool autoStart = false,
    int triesLeft = 5,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tab = _generationTabKey.currentState;
      if (tab == null) {
        if (triesLeft <= 0) return;
        _seedGenerationWhenReady(
          pgnPaths: pgnPaths,
          autoStart: autoStart,
          triesLeft: triesLeft - 1,
        );
        return;
      }
      tab.seedDbExplorer(pgnPaths: pgnPaths, autoStart: autoStart);
    });
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

  String? get _repertoireFilePath => _controller.currentRepertoire?.filePath;

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

  void _reclaimFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.canRequestFocus && !isTextInputFocused()) {
        _focusNode.requestFocus();
      }
    });
  }

  // Outline column actions, implemented on the concrete state and called
  // from the layout mixin.
  Future<void> _openChapterPath(String path);
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

    _toolsTabController = TabController(length: 3, vsync: this);
    _sidePanelTabController = TabController(length: 3, vsync: this);
    _outline = RepertoireOutlineController(
      onActiveChapterMoved: _onActiveChapterMoved,
    );
    _planRunner = PlanRunner(generation: _generationController)
      ..onChapterChanged = _onPlannedChapterChanged
      ..addListener(_onPlanRunnerChanged);
    _layout.addListener(_onLayoutChanged);
    unawaited(_layout.load());
    _controller = RepertoireController();
    _controller.addListener(_onRepertoireChanged);
    _buildSession = BuildByPlayingController(repertoire: _controller);
    _buildSession.addListener(_onBuildSessionChanged);
    unawaited(BuildByPlayingSettings.instance.loadFromPrefs());
    _buildLauncher = BuildLauncher(
      repertoire: _controller,
      draft: _draftController,
      session: _buildSession,
      generation: _generationController,
      appState: () => _appState ?? context.read<AppState>(),
      showLinesSurface: _showLinesSurface,
    );
    _generationController.addListener(_onGenerationChanged);
    _auditController.addListener(_onAuditChanged);
    _coverageController.addListener(_onCoverageChanged);
    _draftController.addListener(_onDraftChanged);
    _trapSession.addListener(_onTrapsChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      _appState = appState;
      appState.addListener(_onAppStateChanged);

      if (appState.hasPending<OpenBuilder>()) {
        _onAppStateChanged();
      }
    });
  }

  void _onAppStateChanged() {
    final appState = _appState;
    if (appState == null) return;
    if (appState.currentMode != AppMode.repertoire) return;
    _reclaimFocus();

    final handoff = appState.takeHandoff<OpenBuilder>();
    if (handoff == null) return;

    // Load the requested repertoire if different from current
    final currentPath = _controller.currentRepertoire?.filePath;
    if (currentPath != handoff.repertoirePath) {
      unawaited(
        _controller.setRepertoire(
          RepertoireMetadata(
            filePath: handoff.repertoirePath,
            name: p.basenameWithoutExtension(handoff.repertoirePath),
            lastModified: DateTime.now(),
          ),
        ),
      );
    }
    if (handoff.lineId != null) {
      unawaited(_openLineAfterLoad(handoff.lineId!));
    }
    if (handoff.moveSequence != null) {
      unawaited(_openMovesAfterLoad(handoff.moveSequence!));
    }
    if (handoff.generationPgnPaths != null) {
      unawaited(_seedGenerationAfterLoad(handoff.generationPgnPaths!));
    }
  }

  /// Navigate the board to a SAN sequence once the repertoire is loaded
  /// ("Explore this position" hand-off from the trainer).
  Future<void> _openMovesAfterLoad(List<String> moves) async {
    await _controller.awaitLoaded();
    if (!mounted) return;
    _controller.loadMoveSequence(moves);
  }

  Future<void> _openLineAfterLoad(String lineId) async {
    await _controller.awaitLoaded();
    if (!mounted) return;
    final line = _controller.repertoireLines
        .where((l) => l.id == lineId)
        .firstOrNull;
    if (line != null) {
      _controller.loadPgnLine(line);
    }
  }

  Future<void> _seedGenerationAfterLoad(List<String> pgnPaths) async {
    unawaited(_openGenerationDialog());
    await _controller.awaitLoaded();
    if (!mounted) return;
    _seedGenerationWhenReady(pgnPaths: pgnPaths, autoStart: true);
  }

  void _onTrapsChanged() {
    if (mounted) setState(() {});
  }

  void _onLayoutChanged() {
    if (mounted) setState(() {});
  }

  /// [RepertoireController.structureVersion] the screen last rebuilt for.
  /// A notification that leaves it unchanged is a cursor move, which only
  /// the position zones need to hear about.
  int _structureSeen = -1;

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

      if (_controller.currentRepertoire != null && !_controller.isLoading) {
        final currentId = _controller.currentRepertoire!.filePath;
        if (currentId != _lastRepertoireId) {
          _auditController.onRepertoireSwitching(_lastRepertoireId);
          _lastRepertoireId = currentId;
          _boardFlipped = !_controller.isRepertoireWhite;
          // A build-by-playing session must not survive a repertoire swap.
          _buildSession.endSession();
          // Drop the old repertoire's trees now, then bring in whatever this
          // one saved — the last full build and every probe since.
          _generationController.clearTree();
          unawaited(_generationController.loadSavedTreeFor(currentId));
          _coverageController.clear();
          // A tour from the previous repertoire's traps makes no sense here.
          _trapSession.endTourForRepertoireSwitch();
          EngineSettings.instance.probabilityStartMoves = _controller.rootMoves;
          unawaited(_trapSession.loadFromFile(currentId));
          newRepertoireId = currentId;
        }

        if (_controller.needsColorSelection) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_showColorSelectionDialog());
          });
        }
      }
    });

    if (newRepertoireId != null) {
      unawaited(_auditController.tryRestore(newRepertoireId!));
      unawaited(_loadChapters());
    }
    _syncOutline();
  }

  // ── Outline (left column) ────────────────────────────────────────

  /// Keep the outline pointed at the open repertoire and fresh after saves.
  ///
  /// Called from every controller notification, so it returns immediately
  /// unless the chapter or its PGN text actually changed.
  void _syncOutline() {
    final current = _controller.currentRepertoire;
    if (current == null || _controller.isLoading) return;
    final chapterPath = current.filePath;
    final pgn = _controller.repertoirePgn;
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
      if (!mounted) return;
      final sameRoot = _outlineRoot != null && p.equals(_outlineRoot!, root);
      if (!sameRoot) {
        _outlineRoot = root;
        await _outline.open(
          rootPath: root,
          activeChapterPath: chapterPath,
          isWhite: _controller.isRepertoireWhite,
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
    return _chapterStore.folderOf(chapterPath);
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
      unawaited(_loadChapters());
      return;
    }
    final current = _controller.currentRepertoire;
    if (current != null && p.equals(current.filePath, newPath)) {
      // Same file, new contents (a line moved in or out): reload in place.
      // Silent, not the reload dialog — we already know what changed, and a
      // summary window over a move the user just made would be noise.
      unawaited(_controller.loadRepertoire());
      return;
    }
    unawaited(_openChapterPath(newPath));
    unawaited(_loadChapters());
  }

  /// Switch the board/editor to the chapter file at [path].
  @override
  Future<void> _openChapterPath(String path) async {
    final current = _controller.currentRepertoire;
    if (current != null && p.equals(current.filePath, path)) return;
    final known = _chapters.where((c) => p.equals(c.filePath, path));
    final meta = known.isNotEmpty
        ? known.first
        : RepertoireMetadata(
            filePath: path,
            name: p.basenameWithoutExtension(path),
            lastModified: DateTime.now(),
          );
    await _controller.setRepertoire(meta);
    _reclaimFocus();
  }

  /// A line picked in the outline: switch chapter if needed, then load it.
  @override
  Future<void> _openOutlineLine(String chapterPath, OutlineLine line) async {
    await _openChapterPath(chapterPath);
    if (!mounted) return;
    // setRepertoire loads asynchronously; wait for the lines to be there.
    await _controller.awaitLoaded();
    if (!mounted) return;
    final match = _controller.repertoireLines
        .where((l) => l.gameIndex == line.gameIndex)
        .firstOrNull;
    if (match != null) {
      _selectLine(match);
    } else {
      _controller.loadMoveSequence(line.moves);
    }
  }

  /// "Generate lines into this chapter": make it the active chapter, put the
  /// board on the chapter's root — the moves every line in it shares, or the
  /// start position for an empty chapter — and open the generation setup,
  /// which builds from the board. Generated lines land in the active
  /// chapter's file, so this is what "into this chapter" means.
  @override
  Future<void> _generateIntoChapter(String chapterPath) async {
    await _openChapterPath(chapterPath);
    if (!mounted) return;
    await _controller.awaitLoaded();
    if (!mounted) return;
    _controller.loadMoveSequence(
      _commonPrefix(_controller.repertoireLines.map((l) => l.moves)),
    );
    unawaited(_openGenerationDialog());
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
    await _openChapterPath(chapterPath);
    if (!mounted) return;
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
    unawaited(_loadChapters());
    final current = _controller.currentRepertoire;
    if (current != null && p.equals(current.filePath, chapterPath)) {
      unawaited(_controller.loadRepertoire());
    }
  }

  /// Full-width planning mode: answer the forks, get chapters, generate.
  @override
  Future<void> _openPlanner() async {
    if (_controller.currentRepertoire == null) return;
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
    final isWhite = _controller.isRepertoireWhite;
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
    final result = await Navigator.of(context).push<PlanBuildResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PlanBuildScreen(
          isWhite: isWhite,
          repertoireName: p.basename(root),
          outline: _outline.outline,
          initialMoves: List.of(_controller.currentMoveSequence),
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
    final name = _controller.currentRepertoire?.name ?? 'this repertoire';
    final isWhite = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Which color is this repertoire for?'),
        content: Text(
          '"$name" doesn\'t have a color set yet. '
          'This will be saved so you won\'t be asked again.',
        ),
        actions: [
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
    if (isWhite != null) {
      await _controller.setRepertoireColor(isWhite);
    }
  }

  @override
  void dispose() {
    if (_auditController.isAuditing) {
      _auditController.saveProgress(_repertoireFilePath);
    }
    _genRebuildThrottle?.cancel();
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
    _boardPreview.dispose();
    _draftController.removeListener(_onDraftChanged);
    _draftController.dispose();
    _buildSession.removeListener(_onBuildSessionChanged);
    _buildSession.dispose();
    _coverageController.removeListener(_onCoverageChanged);
    _coverageController.dispose();
    _auditController.removeListener(_onAuditChanged);
    _auditController.dispose();
    _generationController.removeListener(_onGenerationChanged);
    _generationController.dispose();
    _controller.removeListener(_onRepertoireChanged);
    _controller.dispose();

    _appState?.removeListener(_onAppStateChanged);
    _appState = null;

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.isLoading) {
      return Scaffold(
        appBar: RepertoireToolbar(
          title: const Text('Repertoire Builder'),
          onOpenSettings: () async {
            await openAppSettings(context);
            _reclaimFocus();
          },
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

    final loadError = _controller.loadError;
    if (loadError != null) {
      return Scaffold(
        appBar: RepertoireToolbar(
          title: const Text('Repertoire Builder'),
          showSelectRepertoireAction: true,
          onOpenSettings: () async {
            await openAppSettings(context);
            _reclaimFocus();
          },
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
                  onPressed: () => unawaited(_controller.loadRepertoire()),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_controller.currentRepertoire == null) {
      return Scaffold(
        appBar: RepertoireToolbar(
          title: const Text('Repertoire Builder'),
          showSelectRepertoireAction: true,
          onOpenSettings: () async {
            await openAppSettings(context);
            _reclaimFocus();
          },
          onSelectRepertoire: _showRepertoireSelection,
        ),
        body: RepertoireListBody(
          onSelected: (repertoire) async {
            await _controller.setRepertoire(repertoire);
            _reclaimFocus();
          },
        ),
      );
    }

    final repertoire = _controller.currentRepertoire!;
    return Scaffold(
      appBar: RepertoireToolbar(
        title: RepertoireBreadcrumbTitle(
          repertoireName: p.basename(
            StorageFactory.instance.parentPath(repertoire.filePath),
          ),
          chapterName: repertoire.name,
          chapters: _chapters,
          currentChapterPath: repertoire.filePath,
          enabled: !_generationController.isGenerating,
          onSwitchRepertoire: _showRepertoireSelection,
          onSelectChapter: _onChapterSelected,
          onAddChapter: _addChapterInline,
          onViewChapters: _showChapterList,
        ),
        isGenerating: _generationController.isGenerating,
        isGenerationPaused: _generationController.isPaused,
        isExpectimaxProbe: _generationController.isExpectimaxProbe,
        showTrainButton: true,
        showSelectRepertoireAction: true,
        generationLocked: _generationController.isGenerating,
        onOpenSettings: () async {
          await openAppSettings(context);
          _reclaimFocus();
        },
        onSelectRepertoire: _showRepertoireSelection,
        onTrainRepertoire: _trainRepertoire,
        onOpenGeneration: _openGenerationDialog,
        onPlanBuild: () => unawaited(_openPlanner()),
        onBuildByPlaying: () => _buildLauncher.startBuildByPlaying(context),
        onBuildFromGames: () => _buildLauncher.buildFromGames(context),
        onOpenAudit: _openAuditDialog,
        onImportPgn: _importPgn,
        trapNavigation: _buildTrapNavigation(),
        isWhiteRepertoire: _controller.isRepertoireWhite,
        onOpenRepertoireOptions: () => showRepertoireOptionsDialog(
          context: context,
          isWhiteRepertoire: _controller.isRepertoireWhite,
          sideChangeEnabled: !_generationController.isGenerating,
          onSideChanged: (isWhite) => _controller.setRepertoireColor(isWhite),
          boardSize: _layout.boardSize,
          onBoardSizeChanged: _layout.setBoardSize,
        ),
      ),
      body: GestureDetector(
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
                )
              else
                // Master-games download nudge / progress; renders nothing
                // once the database exists or the prompt was dismissed.
                MasterGamesPromptBanner(
                  onShowJobs: () => _openBottomPane(BottomPaneTab.jobs),
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
                onFindingsTap: () => _toggleBottomPane(BottomPaneTab.findings),
                onJobsTap: () => _toggleBottomPane(BottomPaneTab.jobs),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
