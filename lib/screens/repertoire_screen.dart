/// Repertoire screen - Full-screen repertoire view
/// Shows repertoire positions with board + PGN + context tabs layout.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dartchess/dartchess.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

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
import '../widgets/coverage_calculator_widget.dart';
import '../widgets/pgn_with_analysis_pane.dart';
import 'package:file_picker/file_picker.dart';
import '../services/storage/storage_factory.dart';
import '../widgets/pgn_import_dialog.dart';
import '../widgets/repertoire_generation_tab.dart';
import '../widgets/layout/board_zone.dart';
import '../widgets/layout/bottom_pane.dart';
import '../widgets/layout/repertoire_status_bar.dart';
import '../widgets/layout/empty_state_placeholder.dart';
import '../widgets/layout/jobs_panel.dart';
import '../widgets/repertoire_lines_browser.dart';
import '../constants/ui_breakpoints.dart';
import '../widgets/repertoire/repertoire_toolbar.dart';
import '../utils/keyboard_shortcut_utils.dart';
import '../widgets/repertoire/repertoire_shortcuts.dart';
import '../widgets/engine/inline_engine_bar.dart';
import '../widgets/engine/inline_expectimax_bar.dart';
import '../services/jobs/repertoire_job.dart';
import '../features/audit/models/audit_finding.dart';
import '../features/audit/widgets/audit_config_panel.dart';
import '../features/audit/widgets/audit_findings_panel.dart';
import '../features/traps/widgets/trap_navigation_buttons.dart';
import '../features/traps/widgets/trap_walkthrough.dart';
import '../features/traps/widgets/traps_browser.dart';
import '../widgets/engine/floating_board_preview.dart';
import '../features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import '../services/generation/trap_extractor.dart';
import '../services/games_library/games_library_service.dart';
import '../services/games_repertoire/games_draft.dart';
import '../theme/app_colors.dart';
import '../services/unified_analysis_builder.dart';
import '../widgets/games_repertoire/games_source_form.dart';
import '../widgets/games_repertoire/draft_review_pane.dart';
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
  bool _trapWalkthroughVisible = false;
  TrapLineInfo? _trapWalkthroughInitialTrap;
  int _trapWalkthroughSession = 0;

  final CoverageController _coverageController = CoverageController();

  late final TabController _toolsTabController;
  bool _showTrapsInLinesTab = false;

  // ── Build-from-games draft session (inline in the Lines/Draft tab) ──
  GamesDraft? _activeDraft;
  bool _activeDraftIsWhite = true;
  String _activeDraftLabel = '';
  bool _buildingDraft = false;
  String _draftProgress = '';
  final GamesLibraryService _gamesLibrary = GamesLibraryService();

  bool get _isDraftActive => _activeDraft != null || _buildingDraft;

  String? _lastRepertoireId;

  final FocusNode _focusNode = FocusNode();
  final GlobalKey _linesPreviewStackKey = GlobalKey();
  final GlobalKey _bottomLinesPreviewStackKey = GlobalKey();

  @override
  void initState() {
    super.initState();

    _toolsTabController = TabController(length: 2, vsync: this);
    _controller = RepertoireController();
    _controller.addListener(_onRepertoireChanged);
    _generationController.addListener(_onGenerationChanged);
    _auditController.addListener(_onAuditChanged);
    _coverageController.addListener(_onCoverageChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      appState.addListener(_onAppStateChanged);

      if (appState.pendingRepertoirePath != null) {
        _onAppStateChanged();
      } else if (_controller.currentRepertoire == null) {
        _showRepertoireSelection();
      }
    });
  }

  void _updateCompactLayout(bool isCompact) {
    if (_isCompactLayout == isCompact) return;
    _isCompactLayout = isCompact;
    setState(() {});
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
      _generationTabKey.currentState?.seedDbExplorer(
        pgnPaths: [path],
      );
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
          _lastRepertoireId = currentId;
          _boardFlipped = !_controller.isRepertoireWhite;
          _generationController.clearTree();
          _coverageController.clear();
          EngineSettings().probabilityStartMoves = _controller.rootMoves;
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
    _focusNode.dispose();
    _boardPreview.dispose();
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

  Future<void> _performUndo() async {
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
        body: EmptyStatePlaceholder(
          icon: Icons.library_books,
          title: 'No Repertoire Selected',
          actionLabel: 'Select Repertoire',
          actionIcon: Icons.library_books,
          onAction: _showRepertoireSelection,
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
          onOpenGeneration: _openGenerationDialog,
          onOpenAudit: _openAuditDialog,
          onImportPgnFile: _importPgnFromFile,
          onToggleExpectimax: InlineExpectimaxBar.toggle,
          onToggleLinesTab: () {
            _toolsTabController.animateTo(
              _toolsTabController.index == 1 ? 0 : 1,
            );
          },
          onCollapseBottomPane: () {
            final pane = _bottomPaneKey.currentState;
            if (pane != null && !pane.isCollapsed) {
              _closeBottomPane();
              return true;
            }
            return false;
          },
          onFlip: () => setState(() => _boardFlipped = !_boardFlipped),
          onToggleTrapWalkthrough: () {
            final trapIndex = _trapIndex;
            if (trapIndex == null ||
                trapIndex.trapAtFen(_controller.fen) == null) {
              return false;
            }
            if (_trapWalkthroughVisible) {
              _closeTrapWalkthrough();
            } else {
              _openTrapWalkthrough(
                startTrap: trapIndex.trapAtFen(_controller.fen),
              );
            }
            return true;
          },
          onToggleEngine: InlineEngineBar.toggleEngine,
          onGoBack: _controller.goBack,
          onGoForward: _controller.goForward,
          onGoToPreviousTrap: () => TrapNavigationButtons.goToPreviousTrap(
            trapIndex: _trapIndex,
            controller: _controller,
          ),
          onGoToNextTrap: () => TrapNavigationButtons.goToNextTrap(
            trapIndex: _trapIndex,
            controller: _controller,
          ),
          onNextFinding: () {
            final pane = _bottomPaneKey.currentState;
            if (pane == null ||
                pane.isCollapsed ||
                pane.activeTab != BottomPaneTab.findings) {
              return false;
            }
            return _findingsPanelKey.currentState?.selectNext() ?? false;
          },
          onPrevFinding: () {
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
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isCompact = constraints.maxWidth < kCompactBreakpoint;
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
              ),
              if (_trapWalkthroughVisible && _trapIndex != null)
                TrapWalkthrough(
                  key: ValueKey(_trapWalkthroughSession),
                  trapIndex: _trapIndex!,
                  controller: _controller,
                  boardPreview: _boardPreview,
                  initialTrap: _trapWalkthroughInitialTrap,
                  onClose: _closeTrapWalkthrough,
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildBoardZone(),
        _verticalZoneDivider(),
        Expanded(child: _buildToolsColumn()),
      ],
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
            fen: _ephemeralFen ?? _controller.fen,
            positionFromFen: _positionFromFen,
            boardFlipped: _boardFlipped,
            isGenerating: _generationController.isGenerating,
            isGenerationPaused: _generationController.isPaused,
            onMove: _handleMove,
            onPause: _generationController.pauseBuild,
            onResume: _generationController.resumeBuild,
            onCancel: _generationController.cancelBuild,
            annotations: _buildBoardAnnotations(),
          ),
        ),
        if (_ephemeralFinding != null) _buildEphemeralBar(),
      ],
    );
  }

  Widget _buildEphemeralBar() {
    final finding = _ephemeralFinding!;
    final move = finding.missingMove ?? '?';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.blue.withAlpha(30),
        border: Border(top: BorderSide(color: Colors.blue.withAlpha(80))),
      ),
      child: Row(
        children: [
          const Icon(Icons.visibility_off_outlined,
              size: 14, color: Colors.blue),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Missing: $move (preview)',
              style: const TextStyle(fontSize: 12, color: Colors.blue),
            ),
          ),
          TextButton.icon(
            onPressed: _createNewLineFromEphemeral,
            icon: const Icon(Icons.open_in_new, size: 14),
            label: const Text('Go to position', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              foregroundColor: Colors.blue,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, size: 14, color: Colors.grey),
            onPressed: () {
              setState(() {
                _ephemeralFinding = null;
                _ephemeralFen = null;
              });
            },
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
        ],
      ),
    );
  }

  /// Build board annotations from audit findings at the current position.
  ///
  /// Uses the dartchess library to resolve SAN moves to origin/dest squares
  /// for drawing arrows. Limited to 6 annotations to avoid visual clutter.
  List<BoardAnnotation> _buildBoardAnnotations() {
    final result = _auditController.result;
    if (result == null) return const [];

    final currentFen = _controller.fen;
    final fenPrefix = currentFen.split(' ').take(4).join(' ');

    final relevant = result.findings.where((f) {
      if (f.dismissed) return false;
      final fFenPrefix = f.fen.split(' ').take(4).join(' ');
      return fFenPrefix == fenPrefix;
    }).toList();

    if (relevant.isEmpty) return const [];

    final annotations = <BoardAnnotation>[];
    const maxAnnotations = 6;

    Position? pos;
    try {
      pos = Chess.fromSetup(Setup.parseFen(currentFen));
    } catch (e) {
      log.d('Invalid FEN for audit annotations: $e', name: 'RepertoireScreen');
      return const [];
    }

    for (final f in relevant) {
      if (annotations.length >= maxAnnotations) break;

      final (brush, san) = switch (f.type) {
        AuditFindingType.mistake => (AnnotationBrush.red, f.ourMove),
        AuditFindingType.inaccuracy => (AnnotationBrush.yellow, f.ourMove),
        AuditFindingType.missingResponse => (
            AnnotationBrush.blue,
            f.missingMove
          ),
        _ => (AnnotationBrush.green, null as String?),
      };

      if (san == null) continue;

      final squares = _sanToSquares(pos, san);
      if (squares != null) {
        annotations.add(BoardAnnotation(
          orig: squares.$1,
          dest: squares.$2,
          brush: brush,
        ));
      }
    }

    return annotations;
  }

  /// Resolve a SAN move to (from, to) square names using dartchess.
  (String, String)? _sanToSquares(Position pos, String san) {
    try {
      final move = pos.parseSan(san);
      if (move is NormalMove) {
        return (_squareName(move.from), _squareName(move.to));
      }
    } catch (e) {
      log.d('Failed to parse SAN "$san": $e', name: 'RepertoireScreen');
    }
    return null;
  }

  String _squareName(int sq) {
    final file = String.fromCharCode(97 + (sq % 8));
    final rank = (sq ~/ 8) + 1;
    return '$file$rank';
  }

  /// Unified right pane: tabs + nav. Engine bars live inside PGN tab only.
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
            ],
          ),
        ),
        _buildNavControls(),
      ],
    );
  }

  /// Second tools tab: normally the Lines list, but it becomes the Draft
  /// review surface while a build-from-games session is active.
  Widget _buildSecondTabContent() {
    if (_buildingDraft) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_draftProgress, textAlign: TextAlign.center),
            ),
          ],
        ),
      );
    }
    final draft = _activeDraft;
    if (draft != null) {
      return DraftReviewPane(
        draft: draft,
        isWhite: _activeDraftIsWhite,
        controller: _controller,
        sourceLabel: _activeDraftLabel,
        onClose: _closeDraft,
        onSelectLine: (sans) => _controller.loadMoveSequence(sans),
      );
    }
    return _buildLinesTabContent();
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
                  fen: _controller.fen,
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
        const Tab(
          height: 30,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.article_outlined, size: 14),
              SizedBox(width: 4),
              Text('PGN', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        Tab(
          height: 30,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _isDraftActive ? Icons.download_done : Icons.list_alt,
                size: 14,
                color: _isDraftActive ? AppColors.warning : null,
              ),
              const SizedBox(width: 4),
              Text(
                _isDraftActive
                    ? 'Draft'
                    : 'Lines${_traps.isNotEmpty ? ' & Traps' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  color: _isDraftActive ? AppColors.warning : null,
                  fontWeight: _isDraftActive ? FontWeight.w600 : null,
                ),
              ),
            ],
          ),
        ),
      ],
      labelPadding: const EdgeInsets.symmetric(horizontal: 12),
      indicatorSize: TabBarIndicatorSize.label,
      dividerHeight: 1,
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
            onPressed: _controller.goBack,
            tooltip: 'Back (←)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            onPressed: _controller.goForward,
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
    if (_showInlineGenConfig && !_generationController.isGenerating) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, size: 16),
                const SizedBox(width: 6),
                const Text('Generate Repertoire',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _showInlineGenConfig = false),
                  tooltip: 'Close',
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: RepertoireGenerationTab(
              key: _generationTabKey,
              fen: _controller.fen,
              isWhiteRepertoire: _controller.isRepertoireWhite,
              currentRepertoire: _controller.currentRepertoire,
              currentMoveSequence: _controller.currentMoveSequence,
              generationController: _generationController,
              onLineSaved: (moves, title, pgn) {
                _controller.appendNewLine(moves, title, pgn);
              },
            ),
          ),
        ],
      );
    }

    if (_showInlineAuditConfig && !_auditController.isAuditing) {
      final ac = _auditController;
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(
              children: [
                const Icon(Icons.policy_outlined, size: 16),
                const SizedBox(width: 6),
                const Text('Audit Repertoire',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () =>
                      setState(() => _showInlineAuditConfig = false),
                  tooltip: 'Close',
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: AuditConfigPanel(
              openingTree: _controller.openingTree,
              isWhiteRepertoire: _controller.isRepertoireWhite,
              currentFen: _controller.fen,
              currentMoveSequence: _controller.currentMoveSequence,
              repertoireFilePath: _repertoireFilePath,
              auditService: ac.service,
              onConfigChanged: ac.onConfigChanged,
              onAuditingChanged: (auditing) {
                if (!mounted) return;
                ac.onAuditingChanged(
                  auditing,
                  _jobManager,
                  _controller.currentRepertoire?.name ?? 'Audit',
                );
                if (auditing) {
                  setState(() => _showInlineAuditConfig = false);
                  _openBottomPane(BottomPaneTab.findings);
                }
              },
              onResultReady: (result) {
                if (!mounted) return;
                ac.onResultReady(result, _repertoireFilePath);
              },
              onLiveFinding: (finding) {
                if (!mounted) return;
                ac.onLiveFinding(finding);
              },
              onProgress: (checked, total) {
                if (!mounted) return;
                ac.onProgress(checked, total);
              },
            ),
          ),
        ],
      );
    }

    if (_generationController.isGenerating && _showInlineGenConfig) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _showInlineGenConfig = false);
      });
    }

    final gc = _generationController;
    return ListenableBuilder(
      listenable: Listenable.merge([_jobManager, gc, _auditController]),
      builder: (context, _) => JobsPanel(
        jobManager: _jobManager,
        generationController: gc,
        auditController: _auditController,
        onOpenGenerationDialog: _openGenerationDialog,
        onOpenAuditDialog: () => _openAuditDialog(forceConfig: true),
        onPauseAudit: _auditController.pause,
        onResumeAudit: _auditController.resume,
        onCancelAudit: () => _auditController.cancel(_repertoireFilePath),
        onPauseGeneration: gc.pauseBuild,
        onResumeGeneration: gc.resumeBuild,
        onCancelGeneration: gc.cancelBuild,
        onFinishNowGeneration: gc.finishNow,
      ),
    );
  }

  Widget _buildFindingsContent() {
    final ac = _auditController;
    return AuditFindingsPanel(
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

    if (finding.type == AuditFindingType.missingResponse &&
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

  void _openTrapWalkthrough({TrapLineInfo? startTrap}) {
    if (_trapIndex == null || _traps.isEmpty) return;
    setState(() {
      _trapWalkthroughVisible = true;
      _trapWalkthroughInitialTrap = startTrap;
      _trapWalkthroughSession++;
    });
  }

  void _closeTrapWalkthrough() {
    if (!_trapWalkthroughVisible) return;
    setState(() {
      _trapWalkthroughVisible = false;
      _trapWalkthroughInitialTrap = null;
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
      onViewInLines: () => _toolsTabController.animateTo(1),
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
    if (_traps.isEmpty) {
      final hasRepertoire = _repertoireFilePath != null;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 48, color: Colors.grey[700]),
              const SizedBox(height: 16),
              Text(
                'No traps detected yet',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[400],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                hasRepertoire
                    ? 'Discover traps in your existing repertoire, or '
                        'generate a new repertoire to find them.'
                    : 'Generate a repertoire to discover positions where '
                        'opponents are likely to make mistakes.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
              const SizedBox(height: 20),
              if (hasRepertoire) ...[
                FilledButton.icon(
                  onPressed: _discoverTrapsFromRepertoire,
                  icon: const Icon(Icons.search, size: 16),
                  label: const Text('Discover Traps'),
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: _openGenerationDialog,
                  icon: const Icon(Icons.auto_awesome, size: 14),
                  label: const Text('Generate Full Repertoire'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.grey[400],
                  ),
                ),
              ] else
                FilledButton.icon(
                  onPressed: _openGenerationDialog,
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('Generate Repertoire'),
                ),
            ],
          ),
        ),
      );
    }
    return TrapsBrowser(
      traps: _traps,
      currentMoveSequence: _controller.currentMoveSequence,
      boardPreview: _boardPreview,
      metrics: _trapIndex?.metrics,
      onTrapSelected: (trap) {
        _controller.loadMoveSequence(trap.movesSan);
      },
      onStartTour: _openTrapWalkthrough,
    );
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
      if (justFinished && _toolsTabController.index != 1) {
        _toolsTabController.animateTo(1);
      }
    }

    setState(() {});
  }

  void _onAuditChanged() {
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
    final config = await showGamesSourceForm(
      context,
      initialIsWhite: _controller.isRepertoireWhite,
    );
    if (config == null || !mounted) return;

    // Switch to the Lines/Draft tab and show progress inline.
    _toolsTabController.animateTo(1);
    setState(() {
      _activeDraft = null;
      _buildingDraft = true;
      _activeDraftIsWhite = config.isWhite;
      _activeDraftLabel = config.username;
      _draftProgress = 'Starting…';
    });

    try {
      final records = await _gamesLibrary.getGames(
        platform: config.platform,
        username: config.username,
        selection: config.selection,
        onProgress: (m) {
          if (mounted) setState(() => _draftProgress = m);
        },
      );
      if (records.isEmpty) {
        if (mounted) {
          setState(() => _buildingDraft = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('No games found for "${config.username}".')));
        }
        return;
      }

      if (mounted) {
        setState(() => _draftProgress =
            'Building tree from ${records.length} games…');
      }
      final (_, tree) = await UnifiedAnalysisBuilder.buildInIsolate(
        pgnList: records.map((r) => r.pgn).toList(),
        username: config.username,
        isWhite: config.isWhite,
        strictPlayerMatching: false,
      );
      if (!mounted) return;
      setState(() {
        _activeDraft = GamesDraft.against(
          tree: tree,
          isWhite: config.isWhite,
          repertoire: _controller.tree,
        );
        _buildingDraft = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _buildingDraft = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not build draft: $e')));
    }
  }

  void _closeDraft() {
    if (!mounted) return;
    setState(() {
      _activeDraft = null;
      _buildingDraft = false;
    });
  }

  void _selectLine(RepertoireLine line) {
    _controller.loadPgnLine(line);
    _toolsTabController.animateTo(0);
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
    final config = await showCoverageConfigDialog(context);
    if (config == null || !mounted) return;

    final tree = _controller.openingTree;
    if (tree == null) {
      showAppSnackBar(context, 'No repertoire tree loaded');
      return;
    }

    try {
      final result = await _coverageController.calculate(
        config: config,
        tree: tree,
        isWhiteRepertoire: _controller.isRepertoireWhite,
      );
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
