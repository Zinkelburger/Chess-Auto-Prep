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
import '../widgets/repertoire/repertoire_nav_controls.dart';
import '../widgets/repertoire/repertoire_tab_labels.dart';
import '../widgets/pgn/pgn_annotation_panel.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/engine/inline_expectimax_bar.dart';
import '../services/jobs/repertoire_job.dart';
import '../features/audit/models/audit_finding.dart';
import '../features/audit/services/audit_board_annotations.dart';
import '../features/audit/widgets/audit_findings_panel.dart';
import '../features/audit/widgets/ephemeral_finding_bar.dart';
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

part 'repertoire/repertoire_screen_layout.dart';
part 'repertoire/repertoire_screen_session.dart';
part 'repertoire/repertoire_screen_tabs.dart';
part 'repertoire/repertoire_screen_traps.dart';

class RepertoireScreen extends StatefulWidget {
  const RepertoireScreen({super.key});

  @override
  State<RepertoireScreen> createState() => _RepertoireScreenState();
}

// Wide-layout Lines side panel: persistence keys and sizing. Top-level so
// both the base state below and the layout part file can use them.
const _kLinesPanelCollapsed = 'repertoire.lines_panel_collapsed';
const _kLinesPanelWidth = 'repertoire.lines_panel_width';
const double _kLinesPanelMinWidth = 220.0;

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
  bool _showInlineGenConfig = false;
  bool _showInlineAuditConfig = false;

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
  bool _linesPanelCollapsed = false;

  /// Wide layout only: user-dragged Lines side panel width. Null until the
  /// user drags the divider; falls back to the proportional default.
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

  bool _navigatingToFinding = false;

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
      log.w(
        'Failed to load lines panel pref',
        name: 'RepertoireScreen',
        error: e,
      );
    }
  }

  Future<void> _saveLinesPanelPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kLinesPanelCollapsed, _linesPanelCollapsed);
    } catch (e) {
      log.w(
        'Failed to save lines panel pref',
        name: 'RepertoireScreen',
        error: e,
      );
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
      log.w(
        'Failed to save lines panel width',
        name: 'RepertoireScreen',
        error: e,
      );
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
    if (_showInlineGenConfig || _showInlineAuditConfig) {
      setState(() {
        _showInlineGenConfig = false;
        _showInlineAuditConfig = false;
      });
    }
  }

  void _openGenerationDialog() {
    setState(() {
      _showInlineGenConfig = true;
      _showInlineAuditConfig = false;
    });
    _openBottomPane(BottomPaneTab.jobs);
  }

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
    if (!forceConfig) {
      if (_auditController.isAuditing || _auditController.hasResults) {
        _openBottomPane(BottomPaneTab.findings);
        return;
      }
    }
    setState(() {
      _showInlineAuditConfig = true;
      _showInlineGenConfig = false;
    });
    _openBottomPane(BottomPaneTab.jobs);
  }

  String? get _repertoireFilePath => _controller.currentRepertoire?.filePath;

  void _reclaimFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.canRequestFocus && !isTextInputFocused()) {
        _focusNode.requestFocus();
      }
    });
  }
}

class _RepertoireScreenState extends _RepertoireScreenStateBase
    with
        _RepertoireTrapHandlers,
        _RepertoireSessionHandlers,
        _RepertoireTabContent,
        _RepertoireLayout {
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
        _controller.setRepertoire(
          RepertoireMetadata(
            filePath: path,
            name: p.basenameWithoutExtension(path),
            lastModified: DateTime.now(),
          ),
        );
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
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
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
}
