/// Repertoire screen - Full-screen repertoire view
/// Shows repertoire positions with board + PGN + context tabs layout.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dartchess/dartchess.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/repertoire_controller.dart';
import '../models/build_tree_node.dart';
import '../models/engine_settings.dart';
import '../models/repertoire_line.dart';
import '../services/repertoire_service.dart';
import '../utils/app_messages.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../services/coherence_service.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/features/coverage/services/coverage_service.dart';
import '../widgets/coverage_calculator_widget.dart';
import '../widgets/interactive_pgn_editor.dart';
import '../widgets/analysis_tab.dart';
import '../widgets/pgn_with_analysis_pane.dart';
import '../widgets/pgn_import_dialog.dart';
import '../widgets/repertoire_generation_tab.dart';
import '../widgets/layout/board_zone.dart';
import '../widgets/layout/edit_context_zone.dart';
import '../widgets/layout/analyze_main_zone.dart';
import '../widgets/layout/repertoire_mode.dart';
import '../widgets/layout/repertoire_status_bar.dart';
import '../widgets/layout/empty_state_placeholder.dart';
import '../constants/ui_breakpoints.dart';
import '../widgets/layout/repertoire_layout.dart'
    show kBoardZoneFlex, kContextZoneFlex, kMainZoneFlex;
import '../widgets/repertoire/repertoire_tab_bar.dart';
import '../widgets/repertoire/repertoire_toolbar.dart';
import '../widgets/navigation_trail.dart';
import '../theme/app_colors.dart';
import '../features/traps/widgets/trap_navigation_buttons.dart';
import '../features/traps/widgets/trap_walkthrough.dart';
import '../features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import '../services/generation/trap_extractor.dart';
import 'package:chess_auto_prep/core/navigation_stack.dart';
import 'repertoire_selection_screen.dart';

// -------------------------------------------------------------------
// REPERTOIRE SCREEN WIDGET
// -------------------------------------------------------------------

class RepertoireScreen extends StatefulWidget {
  const RepertoireScreen({super.key});

  @override
  State<RepertoireScreen> createState() => _RepertoireScreenState();
}

class _RepertoireScreenState extends State<RepertoireScreen>
    with TickerProviderStateMixin {
  late final RepertoireController _controller;
  late TabController _tabController;
  final PgnEditorController _pgnEditorController = PgnEditorController();
  final GlobalKey<RepertoireGenerationTabState> _generationTabKey =
      GlobalKey<RepertoireGenerationTabState>();
  bool _isGenerating = false;
  bool _isGenerationPaused = false;
  bool _generateModeActive = false;
  bool _isCompactLayout = false;
  final ValueNotifier<Set<EditContextView>> _editContextViews =
      ValueNotifier({EditContextView.browse});

  BuildTree? _generatedTree;
  TreeBuildConfig? _generatedTreeConfig;
  FenMap? _generatedTreeFenMap;
  int _generatedTreeResetCounter = 0;
  final BoardPreviewController _boardPreview = BoardPreviewController();
  final NavigationStack _navigationStack = NavigationStack();

  bool _boardFlipped = false;

  final CoherenceService _coherenceService = CoherenceService();

  List<TrapLineInfo> _traps = [];
  TrapIndexService? _trapIndex;
  bool _trapWalkthroughVisible = false;
  TrapLineInfo? _trapWalkthroughInitialTrap;
  int _trapWalkthroughSession = 0;

  CoverageResult? _coverageResult;
  bool _isCoverageRunning = false;
  double? _coverageProgress;
  String? _coverageProgressMessage;

  String? _lastRepertoireId;

  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _initTabController();

    // 1. Initialize the controller
    _controller = RepertoireController();

    // 2. Add a listener to rebuild the UI when state changes
    _controller.addListener(_onRepertoireChanged);

    // 3. Show repertoire selection on first load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.currentRepertoire == null) {
        _showRepertoireSelection();
      }
    });

    // 4. Listen for mode switches that pass a repertoire/line to load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      appState.addListener(_onAppStateChanged);
    });
  }

  static const int _compactTabCount = 2;

  void _initTabController({int initialIndex = 0}) {
    _tabController = TabController(
      length: _compactTabCount,
      vsync: this,
      initialIndex: initialIndex.clamp(0, _compactTabCount - 1),
    );
    _tabController.addListener(_onTabChanged);
  }

  void _updateCompactLayout(bool isCompact) {
    if (_isCompactLayout == isCompact) return;
    _isCompactLayout = isCompact;
    setState(() {});
  }

  void _onTabChanged() {
    final settled = _tabController.indexIsChanging ||
        _tabController.animation?.value == _tabController.index;
    if (!settled) return;
    setState(() {});
  }

  bool get _isPgnTabActive =>
      !_generateModeActive &&
      (!_isCompactLayout || _tabController.index == 0);

  void _goToBrowseTab() {
    if (_generateModeActive) _closeGenerateMode();
    _editContextViews.value = {
      ..._editContextViews.value,
      EditContextView.browse,
    };
    if (_isCompactLayout) {
      _tabController.animateTo(1);
    }
  }

  void _goToPgnTab() {
    if (_generateModeActive) _closeGenerateMode();
    if (_isCompactLayout) {
      _tabController.animateTo(0);
    }
  }

  void _goToLinesTab() {
    if (_generateModeActive) _closeGenerateMode();
    _editContextViews.value = {
      ..._editContextViews.value,
      EditContextView.lines,
    };
    if (_isCompactLayout) {
      _tabController.animateTo(1);
    }
  }

  void _openGenerateMode() {
    setState(() => _generateModeActive = true);
  }

  void _closeGenerateMode() {
    setState(() => _generateModeActive = false);
  }

  /// Maps navigation trail indices (0=Browse, 1=PGN, 2=Lines, 3=Generate).
  void _onNavigationJump(NavigationEntry entry) {
    switch (entry.tabIndex) {
      case 0:
        _goToBrowseTab();
      case 1:
        _goToPgnTab();
      case 2:
        _goToLinesTab();
      case 3:
        _openGenerateMode();
    }
    _controller.setPositionFromFen(entry.fen);
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
      final currentPath = _controller.currentRepertoire?['filePath'] as String?;
      if (currentPath != path) {
        _controller.setRepertoire({
          'filePath': path,
          'name': path.split('/').last.replaceAll('.pgn', '')
        });
      }
      // If a specific line was requested, navigate to it once loaded.
      // Use a listener instead of a single post-frame callback so we
      // don't miss the load if parsing takes more than one frame.
      if (lineId != null) {
        void waitForLine() {
          if (!mounted) {
            _controller.removeListener(waitForLine);
            return;
          }
          final line = _controller.repertoireLines
              .where((l) => l.id == lineId)
              .firstOrNull;
          if (line != null) {
            _controller.removeListener(waitForLine);
            _controller.loadPgnLine(line);
            _goToPgnTab();
          }
        }

        _controller.addListener(waitForLine);
        // Also check immediately in case data is already loaded.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) waitForLine();
        });
      }
    }
  }

  // 3. The listener that calls setState
  void _onRepertoireChanged() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        if (_controller.currentRepertoire != null && !_controller.isLoading) {
          final currentId =
              _controller.currentRepertoire!['filePath'] as String?;
          if (currentId != null && currentId != _lastRepertoireId) {
            _lastRepertoireId = currentId;
            _boardFlipped = !_controller.isRepertoireWhite;
            _generatedTree = null;
            _generatedTreeResetCounter++;
            _coverageResult = null;
            EngineSettings().probabilityStartMoves = _controller.rootMoves;
            _loadTraps(currentId);
          }

          if (_controller.needsColorSelection) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _showColorSelectionDialog();
            });
          }
        }
      });
    });
  }

  Future<void> _showColorSelectionDialog() async {
    final name = _controller.currentRepertoire?['name'] ?? 'this repertoire';
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
    _focusNode.dispose();
    _editContextViews.dispose();
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _boardPreview.dispose();
    _controller.removeListener(_onRepertoireChanged);
    _controller.dispose();

    try {
      context.read<AppState>().removeListener(_onAppStateChanged);
    } catch (_) { /* provider may already be disposed */ }

    super.dispose();
  }

  void _reclaimFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.canRequestFocus) {
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
      debugPrint('[RepertoireScreen] Undo failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Undo failed: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // Skip keyboard shortcuts when a text field has focus.
    final primaryFocus = FocusManager.instance.primaryFocus;
    final isTextInput = primaryFocus?.context?.widget is EditableText;

    // Ctrl+Shift+V - Paste FEN from clipboard (even in text fields)
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed &&
        HardwareKeyboard.instance.isShiftPressed) {
      _pastePositionFromClipboard();
      return KeyEventResult.handled;
    }

    // All remaining shortcuts are suppressed when typing.
    if (isTextInput) return KeyEventResult.ignored;

    // Ctrl+Z — undo last repertoire add (browse / suggestion accept)
    if (event.logicalKey == LogicalKeyboardKey.keyZ &&
        HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _performUndo();
      return KeyEventResult.handled;
    }

    // 'G' key — open generate mode
    if (event.logicalKey == LogicalKeyboardKey.keyG &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      _openGenerateMode();
      return KeyEventResult.handled;
    }

    // 'F' key - Flip the board
    if (event.logicalKey == LogicalKeyboardKey.keyF &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      setState(() {
        _boardFlipped = !_boardFlipped;
      });
      return KeyEventResult.handled;
    }

    // 'T' key — toggle trap walkthrough at a trap position
    if (event.logicalKey == LogicalKeyboardKey.keyT &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      final trapIndex = _trapIndex;
      if (trapIndex != null && trapIndex.trapAtFen(_controller.fen) != null) {
        if (_trapWalkthroughVisible) {
          _closeTrapWalkthrough();
        } else {
          _openTrapWalkthrough(
            startTrap: trapIndex.trapAtFen(_controller.fen),
          );
        }
        return KeyEventResult.handled;
      }
    }

    // Arrow keys — navigate regardless of tab
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        if (TrapNavigationButtons.goToPreviousTrap(
          trapIndex: _trapIndex,
          controller: _controller,
        )) {
          return KeyEventResult.handled;
        }
      } else if (_isPgnTabActive) {
        _pgnEditorController.goBack();
      } else {
        _controller.goBack();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        if (TrapNavigationButtons.goToNextTrap(
          trapIndex: _trapIndex,
          controller: _controller,
        )) {
          return KeyEventResult.handled;
        }
      } else if (_isPgnTabActive) {
        _pgnEditorController.goForward();
      } else {
        _controller.goForward();
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // Loading state
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

    // No repertoire selected
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

    // Has repertoire selected - show repertoire UI
    final repertoire = _controller.currentRepertoire!;
    return Scaffold(
      appBar: RepertoireToolbar(
        title: RepertoireToolbarTitle(
          repertoireName: repertoire['name'] as String?,
          gameCount: repertoire['gameCount'] as int?,
        ),
        isGenerating: _isGenerating,
        isGenerationPaused: _isGenerationPaused,
        showTrainButton: true,
        showSelectRepertoireAction: true,
        generationLocked: _isGenerating,
        onOpenSettings: () async {
          await openRepertoireSettings(context);
          _reclaimFocus();
        },
        onSelectRepertoire: _showRepertoireSelection,
        onTrainRepertoire: _trainRepertoire,
        onOpenGeneration: _openGenerateMode,
        trapNavigation: _buildTrapNavigation(),
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _reclaimFocus,
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
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
                      return Column(
                        children: [
                          Expanded(flex: 4, child: _buildBoardZone()),
                          const Divider(height: 1, thickness: 1),
                          Expanded(
                            flex: 6,
                            child: _buildCompactRightPane(),
                          ),
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: kBoardZoneFlex, child: _buildBoardZone()),
                        _verticalZoneDivider(),
                        Expanded(
                          flex: kMainZoneFlex + kContextZoneFlex,
                          child: _buildWideRightPane(),
                        ),
                      ],
                    );
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
              RepertoireStatusBar(
                tree: _generatedTree,
                trapCount: _traps.length,
                lineCount: _controller.repertoireLines.length,
                coveragePercent: _coverageResult?.coveragePercent,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBoardZone() {
    return BoardZone(
      boardPreview: _boardPreview,
      fen: _controller.fen,
      positionFromFen: _positionFromFen,
      boardFlipped: _boardFlipped,
      isGenerating: _isGenerating,
      isGenerationPaused: _isGenerationPaused,
      onMove: _handleMove,
      onPause: () => _generationTabKey.currentState?.togglePause(),
      onResume: () => _generationTabKey.currentState?.togglePause(),
      onCancel: () => _generationTabKey.currentState?.cancelGeneration(),
    );
  }

  Widget _buildWideRightPane() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: _generateModeActive,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: kMainZoneFlex, child: _buildPgnPane()),
              _verticalZoneDivider(),
              Expanded(flex: kContextZoneFlex, child: _buildEditContextZone()),
            ],
          ),
        ),
        Offstage(
          offstage: !_generateModeActive,
          child: _buildGeneratePane(),
        ),
      ],
    );
  }

  Widget _buildCompactRightPane() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: _generateModeActive,
          child: _buildCompactTabbedPane(),
        ),
        Offstage(
          offstage: !_generateModeActive,
          child: _buildGeneratePane(),
        ),
      ],
    );
  }

  Widget _buildPgnPane() {
    return Container(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          NavigationTrail(
            stack: _navigationStack,
            onJumpTo: _onNavigationJump,
          ),
          Expanded(child: _buildPgnTab()),
        ],
      ),
    );
  }

  Widget _buildCompactTabbedPane() {
    return RepertoireTabBar(
      tabController: _tabController,
      navigationStack: _navigationStack,
      onNavigationJump: _onNavigationJump,
      tabChildren: [
        _buildPgnTab(),
        _buildEditContextZone(),
      ],
    );
  }

  Widget _buildGeneratePane() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: theme.dividerColor),
            ),
            color: _isGenerating
                ? AppColors.warningSurface.withValues(alpha: 0.12)
                : null,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Generate Repertoire',
                        style: theme.textTheme.titleSmall,
                      ),
                      if (_isGenerating)
                        Text(
                          'Build continues in the background when closed',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close (G to reopen)',
                  onPressed: _closeGenerateMode,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: _buildGenerationTab()),
      ],
    );
  }

  Widget _verticalZoneDivider() {
    return Container(width: 1, color: Colors.grey[700]);
  }

  Widget _buildEditContextZone() {
    return EditContextZone(
      key: ValueKey(_generatedTreeResetCounter),
      initialView: EditContextView.browse,
      selectedViewsNotifier: _editContextViews,
      tabsLocked: _isGenerating && !_isGenerationPaused,
      browseContent: _buildAnalysisTab(),
      linesContent: _buildLinesContextTab(),
      controller: _controller,
      tree: _generatedTree,
      treeConfig: _generatedTreeConfig,
      fenMap: _generatedTreeFenMap,
      boardPreview: _boardPreview,
      isGenerating: _isGenerating,
      isGenerationPaused: _isGenerationPaused,
    );
  }

  Widget _buildLinesContextTab() {
    if (_controller.repertoireLines.isEmpty) {
      return const EmptyStatePlaceholder(
        icon: Icons.library_books,
        title: 'No lines found in repertoire',
        subtitle: 'Load a PGN repertoire file to see lines here',
      );
    }

    return AnalyzeMainZone.withLinesBrowser(
      lines: _controller.repertoireLines,
      currentMoveSequence: _controller.currentMoveSequence,
      onLineSelected: (line) {
        _controller.loadPgnLine(line);
        _goToPgnTab();
      },
      onLineRenamed: _renameLine,
      onCoveragePressed: _showCoverageCalculator,
      isCoverageRunning: _isCoverageRunning,
      coverageResult: _coverageResult,
      onNavigateToPosition: (moveSequence) {
        _controller.loadMoveSequence(moveSequence);
        _goToPgnTab();
      },
      coverageProgress: _coverageProgress,
      coverageProgressMessage: _coverageProgressMessage,
      tree: _generatedTree,
      fenMap: _generatedTreeFenMap,
      isWhiteRepertoire: _controller.isRepertoireWhite,
      traps: _traps,
      coherenceResult: _coherenceService.result,
      navigationStack: _navigationStack,
    );
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
        _trapIndex =
            _traps.isEmpty ? null : TrapIndexService(_traps);
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
      pgnEditorController: _pgnEditorController,
      editorKeySuffix: _controller.selectedPgnLine?.id ?? 'no_selection',
      initialPgn: _getInitialPgnForEditor() ?? '',
      repertoireName: _controller.currentRepertoire?['name'] as String?,
      repertoireColor: _controller.isRepertoireWhite ? 'White' : 'Black',
      moveHistory: _controller.moveHistory,
      currentMoveIndex: _controller.currentMoveIndex,
      startingFen: _controller.startingFen,
      onMoveStateChanged: (moveIndex, moves) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (!_controller.isInternalUpdate) {
            _controller.syncFromMoveIndex(moveIndex, moves);
          }
        });
      },
      onPositionChanged: (_) {},
      onPgnChanged: (_) {},
      isEditingExistingLine: _controller.selectedPgnLine != null,
      onLineEdited: (updatedPgn) {
        _controller.updateSelectedLineContent(updatedPgn);
      },
      onLineSaved: (moves, title, pgn) {
        _controller.appendNewLine(moves, title, pgn);
      },
      onImportPgn: _importPgn,
      onReload: _reloadRepertoire,
      tree: _generatedTree,
      treeConfig: _generatedTreeConfig,
      fenMap: _generatedTreeFenMap,
      boardPreview: _boardPreview,
      coherenceResult: _coherenceService.result,
      isAnalysisActive: _isPgnTabActive,
      isGenerating: _isGenerating,
      isGenerationPaused: _isGenerationPaused,
      embedAnalysisDock: false,
      trapIndex: _trapIndex,
    );
  }

  Widget _buildAnalysisTab() {
    return AnalysisTab(
      controller: _controller,
      tree: _generatedTree,
      treeConfig: _generatedTreeConfig,
      fenMap: _generatedTreeFenMap,
      boardPreview: _boardPreview,
      coherenceResult: _coherenceService.result,
      isGenerating: _isGenerating,
      isGenerationPaused: _isGenerationPaused,
      onLineSelected: _selectLine,
      traps: _traps,
      coverageResult: _coverageResult,
      navigationStack: _navigationStack,
    );
  }

  Widget _buildGenerationTab() {
    return RepertoireGenerationTab(
      key: _generationTabKey,
      fen: _controller.fen,
      isWhiteRepertoire: _controller.isRepertoireWhite,
      currentRepertoire: _controller.currentRepertoire,
      currentMoveSequence: _controller.currentMoveSequence,
      onGeneratingChanged: (generating) {
        if (!mounted) return;
        setState(() {
          _isGenerating = generating;
          if (generating) {
            _generateModeActive = true;
          } else {
            _isGenerationPaused = false;
            _generateModeActive = false;
          }
        });
        context.read<AppState>().setRepertoireGenerating(generating);
        if (!generating) {
          // Reload traps after generation completes
          final fp = _controller.currentRepertoire?['filePath'] as String?;
          if (fp != null) _loadTraps(fp);
        }
      },
      onPauseChanged: (paused) {
        if (!mounted) return;
        setState(() => _isGenerationPaused = paused);
      },
      onLineSaved: (moves, title, pgn) {
        _controller.appendNewLine(moves, title, pgn);
      },
      onTreeReset: () {
        if (!mounted) return;
        _coherenceService.invalidate();
        setState(() {
          _generatedTree = null;
          _generatedTreeConfig = null;
          _generatedTreeFenMap = null;
          _generatedTreeResetCounter++;
        });
      },
      onTreeBuilt: (tree) {
        if (!mounted) return;
        final fenMap = FenMap()..populate(tree.root);
        TreeBuildConfig? config;
        if (tree.configSnapshot.isNotEmpty) {
          try {
            config = TreeBuildConfig.fromJson(
              tree.configSnapshot,
              startFen: tree.root.fen,
            );
          } catch (e) {
            debugPrint('[RepertoireScreen] Tree operation failed: $e');
          }
        }
        setState(() {
          _generatedTree = tree;
          _generatedTreeFenMap = fenMap;
          _generatedTreeConfig = config;
        });
        _runCoherence();
      },
    );
  }

  void _selectLine(RepertoireLine line) {
    _controller.loadPgnLine(line);
    _goToPgnTab();
  }

  Future<void> _renameLine(RepertoireLine line, String newTitle) async {
    final filePath = _controller.currentRepertoire?['filePath'] as String?;
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

  // --- HELPER METHODS ---

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
      debugPrint('Clipboard read failed: $e');
      if (mounted) {
        showAppSnackBar(context, AppMessages.clipboardReadFailed,
            isError: true);
      }
    }
  }

  String? _getInitialPgnForEditor() {
    // If a specific PGN line is selected, return its full PGN
    if (_controller.selectedPgnLine != null) {
      return _controller.selectedPgnLine!.fullPgn;
    }
    // No line selected — let the editor build from moveHistory instead of
    // dumping the entire multi-game repertoire file into the parser.
    return null;
  }

  // --- METHODS (Now simple calls to the controller) ---

  Future<void> _showRepertoireSelection() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
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
    // Tell the controller to reload
    await _controller.loadRepertoire();
  }

  /// Handle moves from the chessboard - board has already made the move and gives us rich info
  void _handleMove(CompletedMove move) {
    if (!mounted) return;
    _controller.userPlayedMove(move.san);
  }

  Position _positionFromFen(String fen) {
    try {
      return Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      return _controller.position;
    }
  }

  Future<void> _showCoverageCalculator() async {
    final config = await showCoverageConfigDialog(context);
    if (config == null || !mounted) return;

    if (_controller.openingTree == null) {
      showAppSnackBar(context, 'No repertoire tree loaded');
      return;
    }

    setState(() {
      _isCoverageRunning = true;
      _coverageResult = null;
      _coverageProgress = 0.0;
      _coverageProgressMessage = 'Starting analysis...';
    });

    _goToLinesTab();

    final service = CoverageService(
      database: config.database,
      ratings: config.ratingsString,
      speeds: config.speedsString,
      useMaia: config.useMaia,
      maiaElo: config.maiaElo,
    );

    try {
      final result = await service.analyzeOpeningTree(
        _controller.openingTree!,
        targetPercent: config.targetPercent,
        isWhiteRepertoire: _controller.isRepertoireWhite,
        onProgress: (message, progress) {
          if (mounted) {
            setState(() {
              _coverageProgressMessage = message;
              _coverageProgress = progress;
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _coverageResult = result;
          _isCoverageRunning = false;
          _coverageProgress = null;
          _coverageProgressMessage = null;
        });
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
        setState(() {
          _isCoverageRunning = false;
          _coverageProgress = null;
          _coverageProgressMessage = null;
        });
        showAppSnackBar(context, 'Coverage analysis failed: $e');
      }
    }
  }

  void _runCoherence() {
    if (_controller.repertoireLines.length < 5) return;
    _coherenceService.compute(
      lines: _controller.repertoireLines,
      playAsWhite: _controller.isRepertoireWhite,
    );
    _coherenceService.addListener(_onCoherenceUpdated);
  }

  void _onCoherenceUpdated() {
    if (mounted) setState(() {});
    _coherenceService.removeListener(_onCoherenceUpdated);
  }

  void _trainRepertoire() {
    if (_controller.currentRepertoire == null) return;
    final filePath = _controller.currentRepertoire!['filePath'] as String?;
    if (filePath == null) return;

    context.read<AppState>().switchToTrainer(repertoirePath: filePath);
  }

  Future<void> _importPgn() async {
    final result = await showPgnImportDialog(
      context,
      title: 'Import PGN into Repertoire',
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

