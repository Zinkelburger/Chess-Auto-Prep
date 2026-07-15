/// Repertoire screen - Full-screen repertoire view
/// Shows repertoire positions with board + PGN + context tabs layout.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dartchess/dartchess.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_state.dart';
import '../core/repertoire_controller.dart';
import '../core/generation_session_controller.dart';
import '../core/audit_session_controller.dart';
import '../core/coverage_controller.dart';
import '../models/engine_settings.dart';
import '../models/repertoire_line.dart';
import '../models/repertoire_metadata.dart';
import '../services/repertoire_service.dart';
import '../utils/app_messages.dart';
import '../utils/log.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/opening_tree_widget.dart';
import '../widgets/coverage_calculator_widget.dart';
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
import '../constants/chess_constants.dart';
import '../constants/ui_breakpoints.dart';
import '../widgets/repertoire/repertoire_toolbar.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../widgets/repertoire/repertoire_shortcuts.dart';
import '../widgets/pgn/pgn_annotation_panel.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/engine/inline_expectimax_bar.dart';
import '../services/jobs/repertoire_job.dart';
import '../features/audit/models/audit_finding.dart';
import '../features/audit/services/audit_board_annotations.dart';
import '../features/audit/widgets/audit_findings_panel.dart';
import '../features/audit/widgets/ephemeral_finding_bar.dart';
import '../core/hole_hunt_session_controller.dart';
import '../features/holes/widgets/holes_report_panel.dart';
import '../features/traps/widgets/trap_navigation_buttons.dart';
import '../features/traps/widgets/trap_tour_bar.dart';
import '../features/traps/widgets/traps_tab_content.dart';
import '../widgets/engine/floating_board_preview.dart';
import '../features/traps/services/trap_index_service.dart';
import '../features/traps/services/trap_line_builder.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import '../services/generation/trap_extractor.dart';
import '../services/build_by_playing/build_by_playing_config.dart';
import '../services/build_by_playing/build_by_playing_controller.dart';
import '../services/games_library/games_library_service.dart';
import '../services/games_repertoire/games_draft_controller.dart';
import '../theme/app_colors.dart';
import '../widgets/build_by_playing/build_by_playing_form.dart';
import '../widgets/build_by_playing/build_session_board_bar.dart';
import '../widgets/build_by_playing/build_session_pane.dart';
import '../widgets/games_repertoire/games_source_form.dart';
import '../widgets/games_repertoire/draft_review_pane.dart';
import '../widgets/layout/jobs_tab_content.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';
import 'repertoire_selection_screen.dart';

class RepertoireScreen extends StatefulWidget {
  const RepertoireScreen({super.key});

  @override
  State<RepertoireScreen> createState() => _RepertoireScreenState();
}

class _RepertoireScreenState extends State<RepertoireScreen>
    with TickerProviderStateMixin {
  late final RepertoireController _controller;
  final GenerationSessionController _generationController =
      GenerationSessionController();
  final GlobalKey<RepertoireGenerationTabState> _generationTabKey =
      GlobalKey<RepertoireGenerationTabState>();
  final AuditSessionController _auditController = AuditSessionController();
  final HoleHuntSessionController _holeHuntController =
      HoleHuntSessionController();
  final GlobalKey<BottomPaneState> _bottomPaneKey =
      GlobalKey<BottomPaneState>();
  final GlobalKey<AuditFindingsPanelState> _findingsPanelKey =
      GlobalKey<AuditFindingsPanelState>();
  bool _isCompactLayout = false;
  bool _showInlineGenConfig = false;
  bool _showInlineAuditConfig = false;
  bool _showInlineHoleHuntConfig = false;

  /// Findings tab: show the hole-hunt report instead of the audit findings.
  bool _findingsShowHoles = false;

  final JobManager _jobManager = JobManager.instance;

  final BoardPreviewController _boardPreview = BoardPreviewController();
  final NavigationStack _navigationStack = NavigationStack();

  bool _boardFlipped = false;
  bool _wasGenerating = false;

  /// Currently previewed missing-move finding (ephemeral board state).
  AuditFinding? _ephemeralFinding;

  /// FEN with the missing move played (ephemeral, not saved to tree).
  String? _ephemeralFen;

  List<TrapLineInfo> _traps = [];
  TrapIndexService? _trapIndex;
  bool _trapTourVisible = false;
  TrapLineInfo? _trapTourInitialTrap;
  final GlobalKey<TrapTourBarState> _trapTourKey =
      GlobalKey<TrapTourBarState>();

  final CoverageController _coverageController = CoverageController();

  late final TabController _toolsTabController;

  /// Wide layout only: Lines/Draft | Tree tabs inside the side panel — the
  /// PGN editor stays visible in the tools column at all times.
  late final TabController _sidePanelTabController;
  bool _showTrapsInLinesTab = false;

  /// Wide layout only: whether the Lines side panel is collapsed to a strip.
  static const _kLinesPanelCollapsed = 'repertoire.lines_panel_collapsed';
  bool _linesPanelCollapsed = false;

  /// Wide layout only: user-dragged Lines side panel width. Null until the
  /// user drags the divider; falls back to the proportional default.
  static const _kLinesPanelWidth = 'repertoire.lines_panel_width';
  static const double _kLinesPanelMinWidth = 220.0;
  double? _linesPanelWidth;

  // ── Build-from-games draft session (inline in the Lines/Draft tab) ──
  final GamesDraftController _draftController = GamesDraftController();

  bool get _isDraftActive => _draftController.isActive;

  // ── Build-by-playing session (takes over the Lines/Draft tab) ──
  late final BuildByPlayingController _buildSession;
  bool _wasBuildSessionActive = false;

  bool get _isBuildSessionActive => _buildSession.isActive;

  String? _lastRepertoireId;

  final FocusNode _focusNode = FocusNode();
  final GlobalKey _linesPreviewStackKey = GlobalKey();
  final GlobalKey _bottomLinesPreviewStackKey = GlobalKey();

  @override
  void initState() {
    super.initState();

    _toolsTabController = TabController(length: 3, vsync: this);
    _sidePanelTabController = TabController(length: 2, vsync: this);
    _loadLinesPanelPref();
    _controller = RepertoireController();
    _controller.addListener(_onRepertoireChanged);
    _buildSession = BuildByPlayingController(repertoire: _controller);
    _buildSession.addListener(_onBuildSessionChanged);
    BuildByPlayingSettings.instance.loadFromPrefs();
    _generationController.addListener(_onGenerationChanged);
    _auditController.addListener(_onAuditChanged);
    _holeHuntController.addListener(_onHoleHuntChanged);
    _coverageController.addListener(_onCoverageChanged);
    _draftController.addListener(_onDraftChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      appState.addListener(_onAppStateChanged);

      if (appState.pendingRepertoirePath != null) {
        _onAppStateChanged();
      }
    });
  }

  void _updateCompactLayout(bool isCompact) {
    if (_isCompactLayout == isCompact) return;
    _isCompactLayout = isCompact;
    setState(() {});
  }

  Future<void> _loadLinesPanelPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _linesPanelCollapsed = prefs.getBool(_kLinesPanelCollapsed) ?? false;
        _linesPanelWidth = prefs.getDouble(_kLinesPanelWidth);
      });
    } catch (e) {
      log.w('Failed to load lines panel pref', name: 'RepertoireScreen', error: e);
    }
  }

  Future<void> _saveLinesPanelPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kLinesPanelCollapsed, _linesPanelCollapsed);
    } catch (e) {
      log.w('Failed to save lines panel pref', name: 'RepertoireScreen', error: e);
    }
  }

  void _setLinesPanelCollapsed(bool collapsed) {
    if (_linesPanelCollapsed == collapsed) return;
    setState(() => _linesPanelCollapsed = collapsed);
    _saveLinesPanelPref();
  }

  Future<void> _saveLinesPanelWidth() async {
    final width = _linesPanelWidth;
    if (width == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kLinesPanelWidth, width);
    } catch (e) {
      log.w('Failed to save lines panel width',
          name: 'RepertoireScreen', error: e);
    }
  }

  /// Bring the Lines/Draft surface into view: the second tab when compact,
  /// the side panel's Lines tab (expanding the panel if collapsed) when wide.
  void _showLinesSurface() {
    if (_isCompactLayout) {
      _toolsTabController.animateTo(1);
    } else {
      _setLinesPanelCollapsed(false);
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
    if (_showInlineGenConfig ||
        _showInlineAuditConfig ||
        _showInlineHoleHuntConfig) {
      setState(() {
        _showInlineGenConfig = false;
        _showInlineAuditConfig = false;
        _showInlineHoleHuntConfig = false;
      });
    }
  }

  void _openGenerationDialog() {
    setState(() {
      _showInlineGenConfig = true;
      _showInlineAuditConfig = false;
      _showInlineHoleHuntConfig = false;
    });
    _openBottomPane(BottomPaneTab.jobs);
  }

  void _discoverTrapsFromRepertoire() {
    final path = _repertoireFilePath;
    if (path == null) return;
    _openGenerationDialog();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _generationTabKey.currentState?.seedDbExplorer(
        pgnPaths: [path],
      );
    });
  }

  void _openAuditDialog({bool forceConfig = false}) {
    if (!forceConfig) {
      if (_auditController.isAuditing || _auditController.hasResults) {
        setState(() => _findingsShowHoles = false);
        _openBottomPane(BottomPaneTab.findings);
        return;
      }
    }
    setState(() {
      _showInlineAuditConfig = true;
      _showInlineGenConfig = false;
      _showInlineHoleHuntConfig = false;
    });
    _openBottomPane(BottomPaneTab.jobs);
  }

  void _openHoleHuntDialog({bool forceConfig = false}) {
    if (!forceConfig) {
      if (_holeHuntController.isHunting || _holeHuntController.hasResults) {
        setState(() => _findingsShowHoles = true);
        _openBottomPane(BottomPaneTab.findings);
        return;
      }
    }
    setState(() {
      _showInlineHoleHuntConfig = true;
      _showInlineGenConfig = false;
      _showInlineAuditConfig = false;
    });
    _openBottomPane(BottomPaneTab.jobs);
  }

  String? get _repertoireFilePath => _controller.currentRepertoire?.filePath;

  void _onAppStateChanged() {
    final appState = context.read<AppState>();
    if (appState.currentMode == AppMode.repertoire) {
      _reclaimFocus();
    }
    if (appState.currentMode == AppMode.repertoire &&
        appState.pendingRepertoirePath != null) {
      final path = appState.pendingRepertoirePath!;
      final lineId = appState.pendingLineId;
      appState.pendingRepertoirePath = null;
      appState.pendingLineId = null;

      // Load the requested repertoire if different from current
      final currentPath = _controller.currentRepertoire?.filePath;
      if (currentPath != path) {
        _controller.setRepertoire(RepertoireMetadata(
          filePath: path,
          name: p.basenameWithoutExtension(path),
          lastModified: DateTime.now(),
        ));
      }
      if (lineId != null) {
        _openLineAfterLoad(lineId);
      }

      final pendingPgnPaths = appState.pendingGenerationPgnPaths;
      if (pendingPgnPaths != null) {
        appState.pendingGenerationPgnPaths = null;
        _seedGenerationAfterLoad(pendingPgnPaths);
      }
    }
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

  bool _navigatingToFinding = false;

  void _onRepertoireChanged() {
    if (!mounted) return;

    String? newRepertoireId;
    setState(() {
      // Clear ephemeral state when the user navigates normally (not via finding).
      if (!_navigatingToFinding && _ephemeralFinding != null) {
        _ephemeralFinding = null;
        _ephemeralFen = null;
      }

      if (_controller.currentRepertoire != null && !_controller.isLoading) {
        final currentId = _controller.currentRepertoire!.filePath;
        if (currentId != _lastRepertoireId) {
          _auditController.onRepertoireSwitching(_lastRepertoireId);
          _holeHuntController.onRepertoireSwitching(_lastRepertoireId);
          _lastRepertoireId = currentId;
          _boardFlipped = !_controller.isRepertoireWhite;
          // A build-by-playing session must not survive a repertoire swap.
          _buildSession.endSession();
          _generationController.clearTree();
          _coverageController.clear();
          // A tour from the previous repertoire's traps makes no sense here.
          _trapTourVisible = false;
          _trapTourInitialTrap = null;
          EngineSettings.instance.probabilityStartMoves = _controller.rootMoves;
          _loadTraps(currentId);
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
      _holeHuntController.tryRestore(newRepertoireId!);
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
            icon: const Icon(Icons.circle, color: Colors.black),
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
    if (_holeHuntController.isHunting) {
      _holeHuntController.cancel(_repertoireFilePath);
    }
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
    _holeHuntController.removeListener(_onHoleHuntChanged);
    _holeHuntController.dispose();
    _generationController.removeListener(_onGenerationChanged);
    _generationController.dispose();
    _controller.removeListener(_onRepertoireChanged);
    _controller.dispose();

    try {
      context.read<AppState>().removeListener(_onAppStateChanged);
    } catch (e) {
      log.w('dispose listener cleanup failed', name: 'RepertoireScreen', error: e);
    }

    super.dispose();
  }

  void _reclaimFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.canRequestFocus && !isTextInputFocused()) {
        _focusNode.requestFocus();
      }
    });
  }

  /// While a build-by-playing session is active, ←/→ navigate the scratchpad
  /// (no-ops outside exploration) instead of the repertoire cursor — moving
  /// the cursor away from a decision point would pause the session.
  void _sessionAwareGoBack() {
    if (_isBuildSessionActive) {
      _buildSession.scratchGoBack();
      return;
    }
    _controller.goBack();
  }

  void _sessionAwareGoForward() {
    if (_isBuildSessionActive) {
      _buildSession.scratchGoForward();
      return;
    }
    _controller.goForward();
  }

  Future<void> _performUndo() async {
    if (_isBuildSessionActive) {
      final undone = await _buildSession.undoLastCommit();
      if (undone && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Undid last committed move'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    if (!_controller.writer.canUndo) return;
    try {
      final undone = await _controller.writer.undo();
      if (!mounted || !undone) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Undid last repertoire add'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      log.w('Undo failed', name: 'RepertoireScreen', error: e);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Undo failed: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
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
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text(
                  loadError,
                  textAlign: TextAlign.center,
                ),
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
        title: RepertoireToolbarTitle(
          repertoireName: repertoire.name,
          gameCount: repertoire.gameCount,
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
        onBuildByPlaying: _startBuildByPlaying,
        onBuildFromGames: _buildFromGames,
        onOpenAudit: _openAuditDialog,
        onOpenFindHoles: _openHoleHuntDialog,
        onImportPgnFile: _importPgnFromFile,
        onImportPgnPaste: _importPgnFromPaste,
        trapNavigation: _buildTrapNavigation(),
        isWhiteRepertoire: _controller.isRepertoireWhite,
        onSwitchColor: () async {
          await _controller.setRepertoireColor(!_controller.isRepertoireWhite);
        },
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _reclaimFocus,
        child: RepertoireShortcuts(
          focusNode: _focusNode,
          onPasteFenFromClipboard: _pastePositionFromClipboard,
          onUndo: _performUndo,
          onToggleExpectimax: InlineExpectimaxBar.toggle,
          onToggleLinesTab: () {
            if (_isCompactLayout) {
              _toolsTabController.animateTo(
                _toolsTabController.index == 1 ? 0 : 1,
              );
            } else {
              _setLinesPanelCollapsed(!_linesPanelCollapsed);
            }
          },
          onCollapseBottomPane: () {
            if (_buildSession.phase == BuildByPlayingPhase.exploring) {
              _buildSession.backToDecisionPoint();
              return true;
            }
            if (_trapTourVisible) {
              _closeTrapTour();
              return true;
            }
            final pane = _bottomPaneKey.currentState;
            if (pane != null && !pane.isCollapsed) {
              _closeBottomPane();
              return true;
            }
            return false;
          },
          onFlip: () => setState(() => _boardFlipped = !_boardFlipped),
          onToggleTrapTour: () {
            final trapIndex = _trapIndex;
            if (trapIndex == null || _traps.isEmpty) return false;
            if (_trapTourVisible) {
              _closeTrapTour();
            } else {
              // Start at the trap under the cursor when there is one.
              _openTrapTour(startTrap: trapIndex.trapAtFen(_controller.fen));
            }
            return true;
          },
          onToggleEngine: InlineEngineBar.toggleEngine,
          onFocusComment: PgnAnnotationPanel.focusActive,
          onGoBack: _sessionAwareGoBack,
          onGoForward: _sessionAwareGoForward,
          onGoToPreviousTrap: () => TrapNavigationButtons.goToPreviousTrap(
            trapIndex: _trapIndex,
            controller: _controller,
          ),
          onGoToNextTrap: () => TrapNavigationButtons.goToNextTrap(
            trapIndex: _trapIndex,
            controller: _controller,
          ),
          onNextFinding: () {
            // While the trap tour is open, N/P belong to the tour.
            if (_trapTourVisible) {
              _trapTourKey.currentState?.next();
              return true;
            }
            final pane = _bottomPaneKey.currentState;
            if (pane == null ||
                pane.isCollapsed ||
                pane.activeTab != BottomPaneTab.findings) {
              return false;
            }
            return _findingsPanelKey.currentState?.selectNext() ?? false;
          },
          onPrevFinding: () {
            if (_trapTourVisible) {
              _trapTourKey.currentState?.previous();
              return true;
            }
            final pane = _bottomPaneKey.currentState;
            if (pane == null ||
                pane.isCollapsed ||
                pane.activeTab != BottomPaneTab.findings) {
              return false;
            }
            return _findingsPanelKey.currentState?.selectPrevious() ?? false;
          },
          onDismissFinding: () {
            final pane = _bottomPaneKey.currentState;
            if (pane == null ||
                pane.isCollapsed ||
                pane.activeTab != BottomPaneTab.findings) {
              return false;
            }
            return _findingsPanelKey.currentState?.dismissSelected() ?? false;
          },
          child: Column(
            children: [
              // Paused builds free the tab and the engine; a slim banner
              // keeps resume/cancel in reach.
              if (_generationController.isGenerating &&
                  _generationController.isPaused)
                GenerationPausedBanner(
                  onResume: _generationController.resumeBuild,
                  onCancel: _generationController.cancelBuild,
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
                        onCancel: _generationController.cancelBuild,
                      ),
                  ],
                ),
              ),
              if (_trapTourVisible && _trapIndex != null)
                TrapTourBar(
                  key: _trapTourKey,
                  trapIndex: _trapIndex!,
                  initialTrap: _trapTourInitialTrap,
                  onClose: _closeTrapTour,
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

  Widget _buildWideLayout() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final defaultWidth =
            (constraints.maxWidth * 0.24).clamp(260.0, 400.0).toDouble();
        final maxWidth = (constraints.maxWidth * 0.45)
            .clamp(_kLinesPanelMinWidth, constraints.maxWidth)
            .toDouble();
        final panelWidth = (_linesPanelWidth ?? defaultWidth)
            .clamp(_kLinesPanelMinWidth, maxWidth)
            .toDouble();
        // The board zone needs a bounded width: the bars under the board
        // (build-session, ephemeral finding) hold Rows with Expanded
        // children, which cannot lay out under the Row's unbounded width.
        // maxHeight matches the width the square board resolves to anyway
        // (board side + padding), so the no-bar geometry is unchanged.
        final boardZoneWidth =
            constraints.maxHeight.clamp(0.0, constraints.maxWidth * 0.5);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: boardZoneWidth, child: _buildBoardZone()),
            _verticalZoneDivider(),
            Expanded(child: _buildWideToolsColumn()),
            if (_linesPanelCollapsed)
              _verticalZoneDivider()
            else
              _buildLinesPanelDragHandle(maxWidth),
            _buildLinesSidePanel(panelWidth),
          ],
        );
      },
    );
  }

  /// Divider between the PGN tools column and the Lines side panel; drag it
  /// to resize the panel.
  Widget _buildLinesPanelDragHandle(double maxWidth) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          // Panel spans from the handle to the right edge of the screen body.
          final localX = box.globalToLocal(details.globalPosition).dx;
          final newWidth = (box.size.width - localX)
              .clamp(_kLinesPanelMinWidth, maxWidth)
              .toDouble();
          setState(() => _linesPanelWidth = newWidth);
        },
        onHorizontalDragEnd: (_) => _saveLinesPanelWidth(),
        child: SizedBox(
          width: 7,
          child: Center(child: Container(width: 1, color: Colors.grey[700])),
        ),
      ),
    );
  }

  Widget _buildCompactLayout() {
    return Column(
      children: [
        Expanded(
          flex: 4,
          child: _buildBoardZone(),
        ),
        const Divider(height: 1, thickness: 1),
        Expanded(
          flex: 5,
          child: _buildToolsColumn(),
        ),
      ],
    );
  }

  Widget _buildBoardZone() {
    return Column(
      children: [
        Expanded(
          child: BoardZone(
            boardPreview: _boardPreview,
            fen: _isBuildSessionActive
                ? _buildSession.boardFen
                : (_ephemeralFen ?? _controller.fen),
            positionFromFen: _positionFromFen,
            boardFlipped: _boardFlipped,
            onMove: _handleMove,
            annotations: buildAuditBoardAnnotations(
              result: _auditController.result,
              currentFen: _controller.fen,
            ),
          ),
        ),
        if (_isBuildSessionActive)
          BuildSessionBoardBar(session: _buildSession),
        if (_ephemeralFinding != null)
          EphemeralFindingBar(
            finding: _ephemeralFinding!,
            onGoToPosition: _createNewLineFromEphemeral,
            onDismiss: () {
              setState(() {
                _ephemeralFinding = null;
                _ephemeralFen = null;
              });
            },
          ),
      ],
    );
  }

  /// Compact-layout tools pane: PGN | Lines/Draft | Tree tabs + nav.
  /// Engine bars live inside PGN tab only.
  Widget _buildToolsColumn() {
    return Column(
      children: [
        _buildToolsTabBar(),
        Expanded(
          child: TabBarView(
            controller: _toolsTabController,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _buildPgnTabWithEngines(),
              _buildSecondTabContent(),
              _buildTreeTabContent(),
            ],
          ),
        ),
        _buildNavControls(),
      ],
    );
  }

  /// Wide-layout tools column: the PGN editor, always visible — the
  /// Lines/Draft and Tree surfaces live in the side panel to the right.
  Widget _buildWideToolsColumn() {
    return Column(
      children: [
        Expanded(child: _buildPgnTabWithEngines()),
        _buildNavControls(),
      ],
    );
  }

  /// Wide-layout side panel hosting the Lines/Draft and Tree surfaces so they
  /// stay clickable while the PGN editor is visible. Collapses to a thin
  /// strip.
  Widget _buildLinesSidePanel(double width) {
    final theme = Theme.of(context);
    if (_linesPanelCollapsed) {
      return InkWell(
        onTap: () => _setLinesPanelCollapsed(false),
        child: SizedBox(
          width: 28,
          child: Column(
            children: [
              const SizedBox(height: 8),
              Tooltip(
                message: 'Show lines (L)',
                child: Icon(Icons.keyboard_double_arrow_left,
                    size: 16, color: theme.hintColor),
              ),
              const SizedBox(height: 12),
              RotatedBox(
                quarterTurns: 1,
                child: Text(
                  _isBuildSessionActive
                      ? 'Session'
                      : _isDraftActive
                          ? 'Draft'
                          : 'Lines (${_controller.repertoireLines.length})',
                  style: TextStyle(
                    fontSize: 11,
                    color: _isBuildSessionActive
                        ? theme.colorScheme.primary
                        : _isDraftActive
                            ? AppColors.warning
                            : theme.hintColor,
                    fontWeight: _isBuildSessionActive || _isDraftActive
                        ? FontWeight.w600
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      width: width,
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.keyboard_double_arrow_right, size: 16),
                onPressed: () => _setLinesPanelCollapsed(true),
                tooltip: 'Hide lines (L)',
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
              Expanded(
                child: TabBar(
                  controller: _sidePanelTabController,
                  // Scrollable so narrow panel widths shrink the bar instead
                  // of overflowing the tab labels.
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [_buildLinesTabLabel(), _buildTreeTabLabel()],
                  labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                  indicatorSize: TabBarIndicatorSize.label,
                  dividerHeight: 0,
                ),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              controller: _sidePanelTabController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildSecondTabContent(),
                _buildTreeTabContent(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Second tools tab: normally the Lines list, but it becomes the Draft
  /// review surface while a build-from-games session is active.
  Widget _buildSecondTabContent() {
    if (_isBuildSessionActive) {
      return BuildSessionPane(
        session: _buildSession,
        boardPreview: _boardPreview,
        onOpenSettings: _openBuildSessionSettings,
      );
    }
    if (_draftController.isBuilding) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_draftController.progress,
                  textAlign: TextAlign.center),
            ),
          ],
        ),
      );
    }
    final draft = _draftController.draft;
    if (draft != null) {
      return DraftReviewPane(
        draft: draft,
        isWhite: _draftController.isWhite,
        controller: _controller,
        sourceLabel: _draftController.sourceLabel,
        onClose: _draftController.close,
        onSelectLine: (sans) => _controller.loadMoveSequence(sans),
      );
    }
    return _buildLinesTabContent();
  }

  Widget _buildTreeTabContent() {
    final tree = _controller.openingTree;
    if (tree == null) {
      return const Center(
        child: Text(
          'No opening tree available.\nLoad a repertoire to build the tree.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return OpeningTreeWidget(
      tree: tree,
      repertoireLines: _controller.repertoireLines,
      currentMoveSequence: _controller.currentMoveSequence,
      onMoveSelected: _controller.userSelectedTreeMove,
      onGoBack: _controller.goBack,
      onGoForward: _controller.goForward,
    );
  }

  Widget _buildPgnTabWithEngines() {
    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: InlineEngineBar(
                  // Follow the scratchpad while a session explores.
                  fen: _isBuildSessionActive
                      ? _buildSession.boardFen
                      : _controller.fen,
                  isActive: true,
                ),
              ),
              VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Theme.of(context).dividerColor),
              Expanded(
                child: InlineExpectimaxBar(
                  controller: _controller,
                  tree: _generationController.generatedTree,
                  treeConfig: _generationController.generatedTreeConfig,
                  fenMap: _generationController.generatedTreeFenMap,
                  boardPreview: _boardPreview,
                  coherenceResult:
                      _generationController.coherenceService.result,
                  isGenerating: _generationController.isGenerating,
                  isGenerationPaused: _generationController.isPaused,
                  // Follow the scratchpad while a session explores.
                  fenOverride:
                      _isBuildSessionActive ? _buildSession.boardFen : null,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4.0),
            child: _buildPgnTab(),
          ),
        ),
      ],
    );
  }

  Widget _buildToolsTabBar() {
    return TabBar(
      controller: _toolsTabController,
      tabs: [
        _buildPgnTabLabel(),
        _buildLinesTabLabel(),
        _buildTreeTabLabel(),
      ],
      labelPadding: const EdgeInsets.symmetric(horizontal: 12),
      indicatorSize: TabBarIndicatorSize.label,
      dividerHeight: 1,
    );
  }

  Widget _buildPgnTabLabel() {
    return const Tab(
      height: 30,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.article_outlined, size: 14),
          SizedBox(width: 4),
          Text('PGN', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildLinesTabLabel() {
    final highlight = _isBuildSessionActive
        ? Theme.of(context).colorScheme.primary
        : _isDraftActive
            ? AppColors.warning
            : null;
    return Tab(
      height: 30,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _isBuildSessionActive
                ? Icons.sports_esports
                : _isDraftActive
                    ? Icons.download_done
                    : Icons.list_alt,
            size: 14,
            color: highlight,
          ),
          const SizedBox(width: 4),
          Text(
            _isBuildSessionActive
                ? 'Session'
                : _isDraftActive
                    ? 'Draft'
                    : 'Lines${_traps.isNotEmpty ? ' & Traps' : ''}',
            style: TextStyle(
              fontSize: 12,
              color: highlight,
              fontWeight: highlight != null ? FontWeight.w600 : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTreeTabLabel() {
    return const Tab(
      height: 30,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_tree_outlined, size: 14),
          SizedBox(width: 4),
          Text('Tree', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildNavControls() {
    return Container(
      height: 28,
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous, size: 16),
            onPressed: () => _controller.loadMoveSequence([]),
            tooltip: 'Go to start',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
            onPressed: _sessionAwareGoBack,
            tooltip: 'Back (←)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            onPressed: _sessionAwareGoForward,
            tooltip: 'Forward (→)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: _generateFromHere,
            icon: const Icon(Icons.add, size: 16),
            tooltip: 'Generate line from here',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.flip, size: 14),
            onPressed: () => setState(() => _boardFlipped = !_boardFlipped),
            tooltip: 'Flip board (F)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }

  Widget _buildJobsContent() {
    // The inline generation config auto-hides once a generation starts.
    if (_generationController.isGenerating && _showInlineGenConfig) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _showInlineGenConfig = false);
      });
    }

    return JobsTabContent(
      showInlineGenConfig: _showInlineGenConfig,
      showInlineAuditConfig: _showInlineAuditConfig,
      showInlineHoleHuntConfig: _showInlineHoleHuntConfig,
      controller: _controller,
      generationController: _generationController,
      auditController: _auditController,
      holeHuntController: _holeHuntController,
      jobManager: _jobManager,
      generationTabKey: _generationTabKey,
      onCloseInlineGenConfig: () =>
          setState(() => _showInlineGenConfig = false),
      onCloseInlineAuditConfig: () =>
          setState(() => _showInlineAuditConfig = false),
      onCloseInlineHoleHuntConfig: () =>
          setState(() => _showInlineHoleHuntConfig = false),
      onOpenGenerationDialog: _openGenerationDialog,
      onOpenAuditConfig: () => _openAuditDialog(forceConfig: true),
      onOpenCoverageDialog: _showCoverageCalculator,
      onOpenHoleHuntConfig: () => _openHoleHuntDialog(forceConfig: true),
      onAuditingChanged: (auditing) {
        if (!mounted) return;
        _auditController.onAuditingChanged(
          auditing,
          _jobManager,
          _controller.currentRepertoire?.name ?? 'Audit',
        );
        if (auditing) {
          setState(() => _showInlineAuditConfig = false);
          _openBottomPane(BottomPaneTab.findings);
        }
      },
      onAuditResultReady: (result) {
        if (!mounted) return;
        _auditController.onResultReady(result, _repertoireFilePath);
      },
      onAuditLiveFinding: (finding) {
        if (!mounted) return;
        _auditController.onLiveFinding(finding);
      },
      onAuditProgress: (checked, total) {
        if (!mounted) return;
        _auditController.onProgress(checked, total);
      },
      onHoleHuntingChanged: (hunting) {
        if (!mounted) return;
        _holeHuntController.onHuntingChanged(
          hunting,
          _jobManager,
          '${_controller.currentRepertoire?.name ?? 'Repertoire'} holes',
        );
        if (hunting) {
          setState(() {
            _showInlineHoleHuntConfig = false;
            _findingsShowHoles = true;
          });
          _openBottomPane(BottomPaneTab.findings);
        }
      },
      onHoleHuntResultReady: (result) {
        if (!mounted) return;
        _holeHuntController.onResultReady(result, _repertoireFilePath);
      },
      onHoleHuntLiveFinding: (finding) {
        if (!mounted) return;
        _holeHuntController.onLiveFinding(finding);
      },
      onHoleHuntProgress: (progress) {
        if (!mounted) return;
        _holeHuntController.onProgress(progress);
      },
    );
  }

  Widget _buildFindingsContent() {
    final ac = _auditController;
    final hc = _holeHuntController;

    final auditPanel = AuditFindingsPanel(
      key: _findingsPanelKey,
      result: ac.result,
      liveFindings: ac.liveFindings,
      isAuditing: ac.isAuditing,
      auditNodesChecked: ac.nodesChecked,
      auditTotalNodes: ac.totalNodes,
      onFindingSelected: _onFindingSelected,
      onResultChanged: (updatedResult) {
        ac.onResultChanged(updatedResult, _repertoireFilePath);
      },
      onRerunAudit: () => _openAuditDialog(forceConfig: true),
      interruptedSnapshot: ac.interruptedSnapshot,
      onResumeAudit:
          ac.interruptedSnapshot != null ? _resumeInterruptedAudit : null,
      onStartFreshAudit:
          ac.interruptedSnapshot != null ? _startFreshAudit : null,
      onStartAudit: () => _openAuditDialog(forceConfig: true),
    );

    // Only offer the Audit/Holes switch once a hunt exists — the tab is
    // unchanged for audit-only workflows.
    if (!hc.hasResults && !hc.isHunting) return auditPanel;

    final holesPanel = HolesReportPanel(
      result: hc.result,
      liveFindings: hc.liveFindings,
      isHunting: hc.isHunting,
      progress: hc.progress,
      trapPassSkipped: hc.trapPassSkipped,
      onFindingSelected: _onFindingSelected,
      onResultChanged: (updatedResult) {
        hc.onResultChanged(updatedResult, _repertoireFilePath);
      },
      onStartHunt: () => _openHoleHuntDialog(forceConfig: true),
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                value: false,
                label: Text('Audit (${ac.activeFindingCount})',
                    style: const TextStyle(fontSize: 11)),
              ),
              ButtonSegment(
                value: true,
                label: Text('Holes (${hc.activeFindingCount})',
                    style: const TextStyle(fontSize: 11)),
              ),
            ],
            selected: {_findingsShowHoles},
            onSelectionChanged: (s) =>
                setState(() => _findingsShowHoles = s.first),
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _findingsShowHoles ? holesPanel : auditPanel),
      ],
    );
  }

  void _resumeInterruptedAudit() {
    final snap = _auditController.interruptedSnapshot;
    if (snap == null) return;
    final tree = _controller.openingTree;
    if (tree == null) return;
    _openBottomPane(BottomPaneTab.findings);
    _auditController.launchResume(
      snapshot: snap,
      tree: tree,
      isWhiteRepertoire: _controller.isRepertoireWhite,
      jobManager: _jobManager,
      repertoireLabel: _controller.currentRepertoire?.name,
      repertoireFilePath: _repertoireFilePath,
    );
  }

  void _startFreshAudit() {
    _auditController.startFresh();
    _openAuditDialog(forceConfig: true);
  }

  void _onFindingSelected(AuditFinding finding) {
    _navigatingToFinding = true;
    _controller.navigateToLineMove(finding.movePath);
    _navigatingToFinding = false;

    if ((finding.type == AuditFindingType.missingResponse ||
            finding.type == AuditFindingType.uncoveredStrongMove) &&
        finding.missingMove != null) {
      try {
        final parentFen = _controller.fen;
        final pos = Chess.fromSetup(Setup.parseFen(parentFen));
        final move = pos.parseSan(finding.missingMove!);
        if (move != null) {
          final after = pos.play(move);
          setState(() {
            _ephemeralFinding = finding;
            _ephemeralFen = after.fen;
          });
          return;
        }
      } catch (e) {
        log.d(
          'Failed to preview missing move "${finding.missingMove}": $e',
          name: 'RepertoireScreen',
        );
      }
    }

    if (_ephemeralFinding != null) {
      setState(() {
        _ephemeralFinding = null;
        _ephemeralFen = null;
      });
    }
  }

  void _createNewLineFromEphemeral() {
    final finding = _ephemeralFinding;
    if (finding == null || finding.missingMove == null) return;

    final lineMoves = [...finding.movePath, finding.missingMove!];

    setState(() {
      _ephemeralFinding = null;
      _ephemeralFen = null;
    });

    _controller.navigateToLineMove(lineMoves);
  }

  Widget _buildLinesContent() {
    return RepertoireLinesBrowser(
      lines: _controller.repertoireLines,
      currentMoveSequence: _controller.currentMoveSequence,
      isWhiteRepertoire: _controller.isRepertoireWhite,
      coverageResult: _coverageController.result,
      isCoverageRunning: _coverageController.isRunning,
      coverageProgress: _coverageController.progress,
      coverageProgressMessage: _coverageController.progressMessage,
      tree: _generationController.generatedTree,
      fenMap: _generationController.generatedTreeFenMap,
      traps: _traps,
      coherenceResult: _generationController.coherenceService.result,
      navigationStack: _navigationStack,
      boardPreview: _boardPreview,
      onLineSelected: _selectLine,
      onLineRenamed: _renameLine,
      onLineDeleted: _deleteLine,
      onCoveragePressed: _showCoverageCalculator,
      onNavigateToPosition: (moves) {
        _controller.loadMoveSequence(moves);
      },
    );
  }

  Widget _buildBottomPane() {
    return ListenableBuilder(
      listenable: _jobManager,
      builder: (context, _) => BottomPane(
        key: _bottomPaneKey,
        findingsContent: _buildFindingsContent(),
        jobsContent: _buildJobsContent(),
        linesContent: Stack(
          key: _bottomLinesPreviewStackKey,
          children: [
            _buildLinesContent(),
            FloatingBoardPreview(
              stackKey: _bottomLinesPreviewStackKey,
              controller: _boardPreview,
              flipped: _boardFlipped,
            ),
          ],
        ),
        findingsBadge: _auditController.activeFindingCount,
        jobsBadge: _jobManager.activeJobs.length,
        linesBadge: _controller.repertoireLines.length,
        onClose: _clearInlineConfigFlags,
      ),
    );
  }

  Widget _verticalZoneDivider() {
    return Container(width: 1, color: Colors.grey[700]);
  }

  void _openTrapTour({TrapLineInfo? startTrap}) {
    if (_trapIndex == null || _traps.isEmpty) return;
    setState(() {
      _trapTourVisible = true;
      _trapTourInitialTrap = startTrap;
    });
  }

  void _closeTrapTour() {
    if (!_trapTourVisible) return;
    setState(() {
      _trapTourVisible = false;
      _trapTourInitialTrap = null;
    });
  }

  Future<void> _loadTraps(String filePath) async {
    final traps = await TrapExtractor.loadFromFile(filePath);
    if (mounted) {
      setState(() {
        _traps = traps ?? [];
        _trapIndex = _traps.isEmpty ? null : TrapIndexService(_traps);
      });
    }
  }

  Widget? _buildTrapNavigation() {
    final trapIndex = _trapIndex;
    if (trapIndex == null) return null;
    return TrapNavigationButtons(
      trapIndex: trapIndex,
      controller: _controller,
      onStartTour: _openTrapTour,
      tourActive: _trapTourVisible,
    );
  }

  Widget _buildPgnTab() {
    return PgnWithAnalysisPane(
      controller: _controller,
      tree: _controller.tree,
      currentPath: _controller.path,
      onJump: (path) => _controller.jump(path),
      onCommentChanged: (path, comment) =>
          _controller.setCommentAtPath(path, comment),
      onDelete: (path) => _controller.deleteAtPath(path),
      onPromote: (path) => _controller.promoteVariation(path),
      onMakeMainLine: (path) => _controller.makeMainLine(path),
      repertoireName: _controller.currentRepertoire?.name,
      repertoireColor: _controller.isRepertoireWhite ? 'White' : 'Black',
      isEditingExistingLine: _controller.selectedPgnLine != null,
      onLineEdited: (updatedPgn) {
        _controller.updateSelectedLineContent(updatedPgn);
      },
      onImportPgnFile: _importPgnFromFile,
      onImportPgnPaste: _importPgnFromPaste,
      onViewInLines: _showLinesSurface,
      onReload: _reloadRepertoire,
      generatedTree: _generationController.generatedTree,
      treeConfig: _generationController.generatedTreeConfig,
      fenMap: _generationController.generatedTreeFenMap,
      boardPreview: _boardPreview,
      coherenceResult: _generationController.coherenceService.result,
      isAnalysisActive: true,
      isGenerating: _generationController.isGenerating,
      isGenerationPaused: _generationController.isPaused,
      embedAnalysisDock: false,
      trapIndex: _trapIndex,
      ephemeralTitle: _controller.annotatedLineLabel,
    );
  }

  Widget _buildLinesTabContent() {
    return Stack(
      key: _linesPreviewStackKey,
      children: [
        Column(
          children: [
            if (_traps.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<bool>(
                        segments: [
                          ButtonSegment<bool>(
                            value: false,
                            label: Text(
                              'Lines (${_controller.repertoireLines.length})',
                              style: const TextStyle(fontSize: 11),
                            ),
                            icon: const Icon(Icons.list, size: 14),
                          ),
                          ButtonSegment<bool>(
                            value: true,
                            label: Text(
                              'Traps (${_traps.length})',
                              style: const TextStyle(fontSize: 11),
                            ),
                            icon: Icon(Icons.warning_amber_rounded,
                                size: 14,
                                color:
                                    _showTrapsInLinesTab ? null : Colors.grey),
                          ),
                        ],
                        selected: {_showTrapsInLinesTab},
                        onSelectionChanged: (v) =>
                            setState(() => _showTrapsInLinesTab = v.first),
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _showTrapsInLinesTab && _traps.isNotEmpty
                  ? _buildTrapsContent()
                  : _buildLinesContent(),
            ),
          ],
        ),
        FloatingBoardPreview(
          stackKey: _linesPreviewStackKey,
          controller: _boardPreview,
          flipped: _boardFlipped,
        ),
      ],
    );
  }

  Widget _buildTrapsContent() {
    return TrapsTabContent(
      traps: _traps,
      trapIndex: _trapIndex,
      currentMoveSequence: _controller.currentMoveSequence,
      repertoireLineMoves:
          _controller.repertoireLines.map((l) => l.moves).toList(),
      boardPreview: _boardPreview,
      hasRepertoire: _repertoireFilePath != null,
      onTrapSelected: _showTrapLine,
      onTrapMoveSelected: (trap, ply) => _showTrapLine(trap, ply: ply),
      onStartTour: _openTrapTour,
      onDiscoverTraps: _discoverTrapsFromRepertoire,
      onOpenGeneration: _openGenerationDialog,
    );
  }

  /// Load a trap as an annotated, explorable line: the path to the trap as
  /// mainline, opponent replies (with play rates and our punish) as
  /// continuations, cursor at the trap position — or at [ply] when given.
  /// Always lands in the PGN tab so the line is clickable right away.
  void _showTrapLine(TrapLineInfo trap, {int? ply}) {
    final built = TrapLineBuilder.build(trap);
    if (built == null) {
      // Stale/corrupt trap file: fall back to the bare sequence.
      _controller.loadMoveSequence(trap.movesSan);
      _toolsTabController.animateTo(0);
      return;
    }
    _controller.loadAnnotatedTree(
      built.tree,
      cursor: built.cursor,
      label: _trapTitle(trap),
    );
    if (ply != null) _controller.jumpToMoveIndex(ply);
    _toolsTabController.animateTo(0);
  }

  /// "Trap #N · Opening" — N is the trap's rank in tour order (trick
  /// surplus), so the browser, tour bar, and PGN title all agree.
  String _trapTitle(TrapLineInfo trap) {
    final idx = TrapTourBar.indexOfTrap(TrapTourBar.sortedTraps(_traps), trap);
    final number = idx >= 0 ? 'Trap #${idx + 1}' : 'Trap';
    final opening = trap.openingName;
    return opening != null ? '$number · $opening' : number;
  }

  void _onGenerationChanged() {
    if (!mounted) return;
    final ctrl = _generationController;

    if (ctrl.isGenerating && ctrl.currentJob == null) {
      ctrl.currentJob = _jobManager.createJob(
        type: JobType.generation,
        label: _controller.currentRepertoire?.name ?? 'Generation',
        subtreeFen: _controller.fen,
      );
      ctrl.currentJob!.updateStatus(JobStatus.running);
      _openBottomPane(BottomPaneTab.jobs);
    }

    context.read<AppState>().setRepertoireGenerating(ctrl.isGenerating);

    if (ctrl.generatedTree != null) {
      _runCoherence();
    }

    final justFinished = !ctrl.isGenerating && _wasGenerating;
    _wasGenerating = ctrl.isGenerating;

    if (justFinished && ctrl.lastError != null) {
      showAppSnackBar(context, ctrl.lastError!, isError: true);
    }

    if (!ctrl.isGenerating) {
      // Prefer the in-memory bundle's trap index (consistent with the tree we
      // just built); fall back to disk for previously-saved repertoires.
      final bundle = ctrl.current;
      if (bundle != null) {
        _traps = bundle.traps.allTraps;
        _trapIndex = _traps.isEmpty ? null : bundle.traps;
      } else {
        final fp = _controller.currentRepertoire?.filePath;
        if (fp != null) _loadTraps(fp);
      }
      if (justFinished) {
        _showLinesSurface();
      }
    }

    setState(() {});
  }

  void _onAuditChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onHoleHuntChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onCoverageChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _generateFromHere() {
    _openGenerationDialog();
  }

  Future<void> _buildFromGames() async {
    final appState = context.read<AppState>();
    // Real games always start from the initial position, so the from-current
    // option only makes sense for standard-start repertoires.
    final standardStart = _controller.startingFen == null;
    final config = await showGamesSourceForm(
      context,
      initialIsWhite: _controller.isRepertoireWhite,
      initialChesscomUsername: appState.chesscomUsername,
      initialLichessUsername: appState.lichessUsername,
      atRoot: !standardStart || _controller.currentMoveSequence.isEmpty,
      rootFen: kStandardStartFen,
      currentFen: standardStart ? _controller.fen : null,
      currentMoveSans:
          standardStart ? _controller.currentMoveSequence : const [],
    );
    if (config == null || !mounted) return;

    // Remember the username app-wide so tactics / weakness finder reuse it.
    if (config.platform == GamesPlatform.chesscom) {
      appState.setChesscomUsername(config.username);
    } else {
      appState.setLichessUsername(config.username);
    }

    // Bring the Lines/Draft surface into view and show progress inline.
    _showLinesSurface();
    final error = await _draftController.build(
      config: config,
      repertoire: _controller.tree,
    );
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error),
      ));
    }
  }

  void _onBuildSessionChanged() {
    if (!mounted) return;
    setState(() {});
    if (_buildSession.isActive && !_wasBuildSessionActive) {
      _showLinesSurface();
    }
    _wasBuildSessionActive = _buildSession.isActive;
  }

  Future<void> _startBuildByPlaying() async {
    if (_controller.currentRepertoire == null) return;
    if (_isBuildSessionActive) {
      _showLinesSurface();
      return;
    }
    final config = await showBuildByPlayingForm(
      context,
      initial: BuildByPlayingSettings.instance.config,
      atRoot: _controller.isAtRootPosition,
      rootFen: _controller.rootFen,
      rootMoveSans: _controller.rootMoveSans,
      currentFen: _controller.fen,
      currentMoveSans: _controller.currentMoveSequence,
      boardFlipped: !_controller.isRepertoireWhite,
    );
    if (config == null || !mounted) return;
    BuildByPlayingSettings.instance.applyFrom(config);
    _showLinesSurface();
    await _buildSession.start(
      config,
      generatedTree: _generationController.generatedTree,
      fenMap: _generationController.generatedTreeFenMap,
    );
  }

  /// Mid-session knob changes from the session pane's gear icon.
  Future<void> _openBuildSessionSettings() async {
    final config = await showBuildByPlayingForm(
      context,
      initial: _buildSession.config,
      atRoot: true, // start-from choice is meaningless mid-session
    );
    if (config == null || !mounted) return;
    BuildByPlayingSettings.instance.applyFrom(config);
    _buildSession.updateConfig(config);
  }

  void _onDraftChanged() {
    if (!mounted) return;
    // A draft opening from any entry point should always be visible.
    if (_draftController.isActive) _showLinesSurface();
    setState(() {});
  }

  void _selectLine(RepertoireLine line) {
    _controller.loadPgnLine(line);
    // Bring the PGN editor into view; in the wide layout it is always
    // visible and the lines panel stays put so the user can keep clicking
    // between lines.
    if (_isCompactLayout) {
      _toolsTabController.animateTo(0);
    }
  }

  Future<void> _renameLine(RepertoireLine line, String newTitle) async {
    final filePath = _controller.currentRepertoire?.filePath;
    if (filePath == null) return;

    final service = RepertoireService();
    final success = await service.updateLineTitle(filePath, line.id, newTitle);

    if (success) {
      await _controller.loadRepertoire();
    } else {
      if (mounted) {
        showAppSnackBar(context, AppMessages.renameLineFailed, isError: true);
      }
    }
  }

  Future<void> _deleteLine(RepertoireLine line) async {
    final success = await _controller.deleteLine(line);
    if (!success && mounted) {
      showAppSnackBar(context, 'Failed to delete line', isError: true);
    }
  }

  /// Paste a FEN position from clipboard (Ctrl+Shift+V)
  Future<void> _pastePositionFromClipboard() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData == null || clipboardData.text == null) {
        if (mounted) {
          showAppSnackBar(context, AppMessages.clipboardEmpty);
        }
        return;
      }

      final fen = clipboardData.text!.trim();
      if (fen.isEmpty) {
        if (mounted) {
          showAppSnackBar(context, AppMessages.clipboardEmpty);
        }
        return;
      }

      final success = _controller.setPositionFromFen(fen);
      if (!success && mounted) {
        showAppSnackBar(context, AppMessages.invalidFen);
      }
    } catch (e) {
      log.w('Clipboard read failed', name: 'RepertoireScreen', error: e);
      if (mounted) {
        showAppSnackBar(context, AppMessages.clipboardReadFailed,
            isError: true);
      }
    }
  }

  Future<void> _showRepertoireSelection() async {
    final result = await Navigator.of(context).push<RepertoireMetadata>(
      MaterialPageRoute(
        builder: (context) => const RepertoireSelectionScreen(),
      ),
    );

    if (result != null && mounted) {
      await _controller.setRepertoire(result);
    }
    _reclaimFocus();
  }

  Future<void> _reloadRepertoire() async {
    await _controller.loadRepertoire();
  }

  /// Handle moves from the chessboard - board has already made the move and gives us rich info
  void _handleMove(CompletedMove move) {
    if (!mounted) return;
    if (_isBuildSessionActive) {
      // Session moves are scratchpad exploration (or ignored while the
      // opponent thinks) — never direct repertoire-tree edits.
      _buildSession.handleBoardMove(move.san);
      return;
    }
    _controller.playMove(move.san);
  }

  Position _positionFromFen(String fen) {
    try {
      return Chess.fromSetup(Setup.parseFen(fen));
    } catch (e) {
      log.d('Invalid FEN "$fen": $e', name: 'RepertoireScreen');
      return _controller.position;
    }
  }

  Future<void> _showCoverageCalculator() async {
    if (_coverageController.isRunning) {
      _openBottomPane(BottomPaneTab.jobs);
      return;
    }

    final config = await showCoverageConfigDialog(context);
    if (config == null || !mounted) return;

    final tree = _controller.openingTree;
    if (tree == null) {
      showAppSnackBar(context, 'No repertoire tree loaded');
      return;
    }

    // Coverage runs as a first-class job so the run is visible in the
    // Jobs pane alongside generation and audit.
    final job = _jobManager.createJob(
      type: JobType.coverage,
      label: '${_controller.currentRepertoire?.name ?? 'Repertoire'} coverage',
    );
    job.updateStatus(JobStatus.running);
    _openBottomPane(BottomPaneTab.jobs);

    try {
      final result = await _coverageController.calculate(
        config: config,
        tree: tree,
        isWhiteRepertoire: _controller.isRepertoireWhite,
        onProgress: (message, progress) {
          job.updateProgress(JobProgress(
            fraction: progress ?? 0,
            message: message,
          ));
        },
      );
      if (result != null) {
        job.updateProgress(JobProgress(
          fraction: 1,
          message:
              '${result.coveragePercent.toStringAsFixed(1)}% covered, '
              '${result.tooShallowLeaves.length} shallow, '
              '${result.tooDeepLeaves.length} deep, '
              '${result.unaccountedMoves.length} unaccounted',
        ));
      }
      job.updateStatus(JobStatus.completed);
      if (result != null && mounted) {
        showAppSnackBar(
          context,
          'Coverage: ${result.coveragePercent.toStringAsFixed(1)}% covered, '
          '${result.tooShallowLeaves.length} shallow, '
          '${result.tooDeepLeaves.length} deep, '
          '${result.unaccountedMoves.length} unaccounted moves',
        );
      }
    } catch (e) {
      job.fail('$e');
      if (mounted) {
        showAppSnackBar(context, 'Coverage analysis failed: $e');
      }
    }
  }

  void _runCoherence() {
    if (_controller.repertoireLines.length < 5) return;
    final cs = _generationController.coherenceService;
    cs.compute(
      lines: _controller.repertoireLines,
      playAsWhite: _controller.isRepertoireWhite,
    );
    // Remove first: _runCoherence fires on every generation notify, and
    // duplicate registrations would stack up between coherence updates.
    cs.removeListener(_onCoherenceUpdated);
    cs.addListener(_onCoherenceUpdated);
  }

  void _onCoherenceUpdated() {
    if (mounted) setState(() {});
    _generationController.coherenceService.removeListener(_onCoherenceUpdated);
  }

  void _trainRepertoire() {
    if (_controller.currentRepertoire == null) return;
    context.read<AppState>().switchToTrainer(
          repertoirePath: _controller.currentRepertoire!.filePath,
        );
  }

  Future<void> _importPgnFromFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pgn', 'txt'],
        withData: false,
        withReadStream: false,
      );
      if (result == null || result.files.isEmpty || !mounted) return;

      final path = result.files.single.path;
      if (path == null) return;

      final content = await StorageFactory.instance.readFile(path);
      if (content == null || !mounted) return;

      final added = await _controller.importPgnContent(content);
      if (!mounted) return;

      showAppSnackBar(
        context,
        'Added $added line${added == 1 ? '' : 's'} to repertoire.',
      );
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Could not read file: $e', isError: true);
      }
    }
  }

  Future<void> _importPgnFromPaste() async {
    final result = await showPgnImportDialog(
      context,
      title: 'Paste PGN',
      confirmLabel: 'Add to Repertoire',
    );
    if (result == null || !mounted) return;

    final added = await _controller.importPgnContent(result.pgnContent);
    if (!mounted) return;

    showAppSnackBar(
      context,
      'Added $added line${added == 1 ? '' : 's'} to repertoire.',
    );
  }
}
