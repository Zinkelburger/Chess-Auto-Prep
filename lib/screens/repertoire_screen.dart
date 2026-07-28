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
import '../features/coverage/widgets/coverage_calculator_widget.dart';
import '../widgets/pgn_with_analysis_pane.dart';
import 'package:file_picker/file_picker.dart';
import '../services/storage/storage_factory.dart';
import '../widgets/pgn_import_dialog.dart';
import '../widgets/repertoire_generation_tab.dart';
import '../widgets/generation/generation_lock_overlay.dart';
import '../widgets/layout/board_zone.dart';
import '../widgets/layout/bottom_pane.dart';
import '../widgets/layout/repertoire_status_bar.dart';
import '../widgets/repertoire_list_body.dart';
import '../widgets/repertoire_lines_browser.dart';
import '../constants/ui_breakpoints.dart';
import '../features/repertoire/widgets/repertoire_options_dialog.dart';
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
import '../features/audit/widgets/audit_findings_panel.dart';
import '../features/audit/widgets/ephemeral_finding_bar.dart';
import '../features/traps/widgets/trap_navigation_buttons.dart';
import '../features/traps/widgets/trap_tour_bar.dart';
import '../features/traps/widgets/traps_tab_content.dart';
import '../widgets/engine/floating_board_preview.dart';
import '../features/repertoire/controllers/repertoire_layout_prefs.dart';
import '../features/repertoire/services/chapter_store.dart';
import '../features/repertoire/widgets/add_chapter_dialog.dart';
import '../features/repertoire/widgets/repertoire_lines_side_panel.dart';
import '../features/repertoire/widgets/repertoire_tree_pane.dart';
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
import '../models/explorer_response.dart';
import 'repertoire_chapters_screen.dart';
import 'repertoire_selection_screen.dart';
import '../features/repertoire/controllers/build_launcher.dart';
import '../features/repertoire/controllers/generation_notification_router.dart';
import '../features/repertoire/controllers/inline_config_router.dart';

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
  final GenerationSessionController _generationController =
      GenerationSessionController();
  final GlobalKey<RepertoireGenerationTabState> _generationTabKey =
      GlobalKey<RepertoireGenerationTabState>();
  final AuditSessionController _auditController = AuditSessionController();
  final GlobalKey<BottomPaneState> _bottomPaneKey =
      GlobalKey<BottomPaneState>();
  final GlobalKey<AuditFindingsPanelState> _findingsPanelKey =
      GlobalKey<AuditFindingsPanelState>();
  bool _isCompactLayout = false;

  /// Whether the Jobs tab is showing the inline generation or audit config,
  /// and which tab each entry point should bring forward.
  final InlineConfigRouter _inlineConfig = InlineConfigRouter();

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

  /// Wide layout only: Lines/Draft | Tree tabs inside the side panel — the
  /// PGN editor stays visible in the tools column at all times.
  late final TabController _sidePanelTabController;
  bool _showTrapsInLinesTab = false;

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
  final GlobalKey _bottomLinesPreviewStackKey = GlobalKey();

  bool _navigatingToFinding = false;

  void _updateCompactLayout(bool isCompact) {
    if (_isCompactLayout == isCompact) return;
    _isCompactLayout = isCompact;
    setState(() {});
  }

  /// Bring the Lines/Draft surface into view: the second tab when compact,
  /// the side panel's Lines tab (expanding the panel if collapsed) when wide.
  void _showLinesSurface() {
    if (_isCompactLayout) {
      _toolsTabController.animateTo(1);
    } else {
      _layout.setLinesPanelCollapsed(false);
      _sidePanelTabController.animateTo(0);
    }
  }

  void _openBottomPane(BottomPaneTab tab) {
    _bottomPaneKey.currentState?.open(tab);
  }

  void _toggleBottomPane(BottomPaneTab tab) {
    _bottomPaneKey.currentState?.toggle(tab);
  }

  void _closeBottomPane() {
    _bottomPaneKey.currentState?.close();
    _clearInlineConfigFlags();
  }

  void _clearInlineConfigFlags() {
    if (_inlineConfig.clear()) setState(() {});
  }

  void _openGenerationDialog() {
    setState(_inlineConfig.openGeneration);
    _openBottomPane(BottomPaneTab.jobs);
  }

  /// Bottom-pane tab for an [InlineConfigTarget].
  static BottomPaneTab _paneTabFor(InlineConfigTarget target) =>
      switch (target) {
        InlineConfigTarget.jobs => BottomPaneTab.jobs,
        InlineConfigTarget.findings => BottomPaneTab.findings,
      };

  void _discoverTrapsFromRepertoire() {
    final path = _repertoireFilePath;
    if (path == null) return;
    _openGenerationDialog();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _generationTabKey.currentState?.seedDbExplorer(pgnPaths: [path]);
    });
  }

  void _openAuditDialog({bool forceConfig = false}) {
    final target = _inlineConfig.openAudit(
      forceConfig: forceConfig,
      auditHasSomethingToShow:
          _auditController.isAuditing || _auditController.hasResults,
    );
    setState(() {});
    _openBottomPane(_paneTabFor(target));
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
    final pane = _bottomPaneKey.currentState;
    if (pane == null ||
        pane.isCollapsed ||
        pane.activeTab != BottomPaneTab.findings) {
      return false;
    }
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
}

class _RepertoireScreenState extends _RepertoireScreenStateBase
    with _RepertoireSessionHandlers, _RepertoireTabContent, _RepertoireLayout {
  @override
  void initState() {
    super.initState();

    _toolsTabController = TabController(length: 3, vsync: this);
    _sidePanelTabController = TabController(length: 2, vsync: this);
    _layout.addListener(_onLayoutChanged);
    _layout.load();
    _controller = RepertoireController();
    _controller.addListener(_onRepertoireChanged);
    _buildSession = BuildByPlayingController(repertoire: _controller);
    _buildSession.addListener(_onBuildSessionChanged);
    BuildByPlayingSettings.instance.loadFromPrefs();
    _buildLauncher = BuildLauncher(
      repertoire: _controller,
      draft: _draftController,
      session: _buildSession,
      generation: _generationController,
      appState: () => context.read<AppState>(),
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
      appState.addListener(_onAppStateChanged);

      if (appState.hasPending<OpenBuilder>()) {
        _onAppStateChanged();
      }
    });
  }

  void _onAppStateChanged() {
    final appState = context.read<AppState>();
    if (appState.currentMode != AppMode.repertoire) return;
    _reclaimFocus();

    final handoff = appState.takeHandoff<OpenBuilder>();
    if (handoff == null) return;

    // Load the requested repertoire if different from current
    final currentPath = _controller.currentRepertoire?.filePath;
    if (currentPath != handoff.repertoirePath) {
      _controller.setRepertoire(
        RepertoireMetadata(
          filePath: handoff.repertoirePath,
          name: p.basenameWithoutExtension(handoff.repertoirePath),
          lastModified: DateTime.now(),
        ),
      );
    }
    if (handoff.lineId != null) {
      _openLineAfterLoad(handoff.lineId!);
    }
    if (handoff.moveSequence != null) {
      _openMovesAfterLoad(handoff.moveSequence!);
    }
    if (handoff.generationPgnPaths != null) {
      _seedGenerationAfterLoad(handoff.generationPgnPaths!);
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
    _openGenerationDialog();
    await _controller.awaitLoaded();
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _generationTabKey.currentState?.seedDbExplorer(
        pgnPaths: pgnPaths,
        autoStart: true,
      );
    });
  }

  void _onTrapsChanged() {
    if (mounted) setState(() {});
  }

  void _onLayoutChanged() {
    if (mounted) setState(() {});
  }

  void _onRepertoireChanged() {
    if (!mounted) return;

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
          _generationController.clearTree();
          _coverageController.clear();
          // A tour from the previous repertoire's traps makes no sense here.
          _trapSession.endTourForRepertoireSwitch();
          EngineSettings.instance.probabilityStartMoves = _controller.rootMoves;
          _trapSession.loadFromFile(currentId);
          newRepertoireId = currentId;
        }

        if (_controller.needsColorSelection) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showColorSelectionDialog();
          });
        }
      }
    });

    if (newRepertoireId != null) {
      _auditController.tryRestore(newRepertoireId!);
      _loadChapters();
    }
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
    _trapSession.removeListener(_onTrapsChanged);
    _trapSession.dispose();
    _layout.removeListener(_onLayoutChanged);
    _layout.dispose();
    _toolsTabController.dispose();
    _sidePanelTabController.dispose();
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

    try {
      context.read<AppState>().removeListener(_onAppStateChanged);
    } catch (e) {
      log.w(
        'dispose listener cleanup failed',
        name: 'RepertoireScreen',
        error: e,
      );
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.isLoading) {
      return Scaffold(
        appBar: RepertoireToolbar(
          title: const Text('Repertoire Builder'),
          onOpenSettings: () async {
            await openRepertoireSettings(context);
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
            await openRepertoireSettings(context);
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
                  onPressed: _reloadRepertoire,
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
            await openRepertoireSettings(context);
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
        showTrainButton: true,
        showSelectRepertoireAction: true,
        generationLocked: _generationController.isGenerating,
        onOpenSettings: () async {
          await openRepertoireSettings(context);
          _reclaimFocus();
        },
        onSelectRepertoire: _showRepertoireSelection,
        onTrainRepertoire: _trainRepertoire,
        onOpenGeneration: _openGenerationDialog,
        onBuildByPlaying: () => _buildLauncher.startBuildByPlaying(context),
        onBuildFromGames: () => _buildLauncher.buildFromGames(context),
        onOpenAudit: _openAuditDialog,
        onImportPgnFile: _importPgnFromFile,
        onImportPgnPaste: _importPgnFromPaste,
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
              if (_generationController.isGenerating &&
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
                    if (_generationController.isGenerating &&
                        !_generationController.isPaused)
                      GenerationLockOverlay(
                        statusText: _generationController.progressStatus,
                        canPause: _generationController.canPause,
                        isCancelling: _generationController.isCancelling,
                        onPause: _generationController.pauseBuild,
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
