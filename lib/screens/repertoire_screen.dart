/// Repertoire screen - Full-screen repertoire view
/// Shows repertoire positions with two-panel layout: board and tabbed panel
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
import '../services/analysis_service.dart';
import '../services/engine/stockfish_pool.dart';
import '../services/repertoire_service.dart';
import '../utils/app_messages.dart';
import '../utils/chess_utils.dart' show uciToSan;
import '../widgets/chess_board_widget.dart';
import '../widgets/coverage_calculator_widget.dart';
import '../features/eval_tree/controllers/eval_tree_controller.dart';
import '../features/eval_tree/widgets/eval_tree_tab.dart';
import '../widgets/app_mode_menu_button.dart';
import '../widgets/interactive_pgn_editor.dart';
import '../widgets/opening_tree_widget.dart';
import '../widgets/repertoire_lines_browser.dart';
import '../widgets/pgn_import_dialog.dart';
import '../widgets/repertoire_generation_tab.dart';
import '../widgets/unified_engine_pane.dart';
import 'repertoire_selection_screen.dart';
import 'repertoire_training_screen.dart';

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
  late final TabController _tabController;
  final PgnEditorController _pgnEditorController = PgnEditorController();
  final GlobalKey<RepertoireGenerationTabState> _generationTabKey =
      GlobalKey<RepertoireGenerationTabState>();
  bool _isGenerating = false;
  bool _isGenerationPaused = false;

  BuildTree? _generatedTree;
  int _generatedTreeResetCounter = 0;
  EvalTreeController? _evalTreeController;

  bool _boardFlipped = false;

  String? _lastRepertoireId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    _tabController.addListener(() {
      final settled = _tabController.indexIsChanging ||
          _tabController.animation?.value == _tabController.index;
      if (!settled) return;

      // Engine tab selected while generating -> pause generation first.
      if (_tabController.index == 1 &&
          _isGenerating &&
          !_isGenerationPaused) {
        _generationTabKey.currentState?.togglePause();
      }

      // Leaving engine tab -> hard-cancel analysis to avoid overlap.
      if (_tabController.index != 1) {
        AnalysisService().cancel();
      }

      setState(() {});
    });

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
  }

  // 3. The listener that calls setState
  void _onRepertoireChanged() {
    setState(() {
      if (_controller.currentRepertoire != null && !_controller.isLoading) {
        final currentId = _controller.currentRepertoire!['filePath'] as String?;
        if (currentId != null && currentId != _lastRepertoireId) {
          _lastRepertoireId = currentId;
          _boardFlipped = !_controller.isRepertoireWhite;
          _generatedTree = null;
          _generatedTreeResetCounter++;
          EngineSettings().probabilityStartMoves = _controller.rootMoves;
        }

        if (_controller.needsColorSelection) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showColorSelectionDialog();
          });
        }
      }
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
    _tabController.dispose();
    _controller.removeListener(_onRepertoireChanged);
    _controller.dispose();

    // Tear down pool workers — they persist for the repertoire session
    // and are only killed when leaving the repertoire builder.
    AnalysisService().dispose();
    StockfishPool().dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Loading state
    if (_controller.isLoading) {
      return Scaffold(
        appBar: _buildAppBar(
          title: const Text('Repertoire Builder'),
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
        appBar: _buildAppBar(
          title: const Text('Repertoire Builder'),
          showSelectRepertoireAction: true,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.library_books, size: 64, color: Colors.grey[400]),
              const SizedBox(height: 24),
              Text('No Repertoire Selected',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _showRepertoireSelection,
                icon: const Icon(Icons.library_books),
                label: const Text('Select Repertoire'),
              ),
            ],
          ),
        ),
      );
    }

    // Has repertoire selected - show repertoire UI
    return Scaffold(
      appBar: _buildAppBar(
        title: _buildRepertoireTitle(),
        showSelectRepertoireAction: true,
      ),
      body: Focus(
        autofocus: true,
        onKeyEvent: _isGenerating && !_isGenerationPaused
            ? null
            : (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;

                // Ctrl+Shift+V - Paste FEN from clipboard
                if (event.logicalKey == LogicalKeyboardKey.keyV &&
                    HardwareKeyboard.instance.isControlPressed &&
                    HardwareKeyboard.instance.isShiftPressed) {
                  _pastePositionFromClipboard();
                  return KeyEventResult.handled;
                }

                // 'F' key - Flip the board (only if not typing in a text field)
                if (event.logicalKey == LogicalKeyboardKey.keyF &&
                    !HardwareKeyboard.instance.isControlPressed &&
                    !HardwareKeyboard.instance.isShiftPressed &&
                    !HardwareKeyboard.instance.isAltPressed) {
                  final primaryFocus = FocusManager.instance.primaryFocus;
                  final isTextInput =
                      primaryFocus?.context?.widget is EditableText;
                  if (!isTextInput) {
                    setState(() {
                      _boardFlipped = !_boardFlipped;
                    });
                    return KeyEventResult.handled;
                  }
                }

                // PGN Tab (Index 2) - PGN Editor handles navigation
                if (_tabController.index == 2) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                    _pgnEditorController.goBack();
                    return KeyEventResult.handled;
                  } else if (event.logicalKey ==
                      LogicalKeyboardKey.arrowRight) {
                    _pgnEditorController.goForward();
                    return KeyEventResult.handled;
                  }
                }
                // Tree Tab (Index 0) or Lines Tab (Index 3)
                else if (_tabController.index == 0 ||
                    _tabController.index == 3) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                    _controller.goBack();
                    return KeyEventResult.handled;
                  } else if (event.logicalKey ==
                      LogicalKeyboardKey.arrowRight) {
                    _controller.goForward();
                    return KeyEventResult.handled;
                  }
                }
                // Engine Tab (Index 1)
                else if (_tabController.index == 1) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                    _controller.goBack();
                    return KeyEventResult.handled;
                  } else if (event.logicalKey ==
                      LogicalKeyboardKey.arrowRight) {
                    _controller.goForward();
                    return KeyEventResult.handled;
                  }
                }
                // Eval Tree Tab (Index 5)
                else if (_tabController.index == 5) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                    _evalTreeController?.goParent();
                    return KeyEventResult.handled;
                  } else if (event.logicalKey ==
                      LogicalKeyboardKey.arrowRight) {
                    _evalTreeController?.goPreferredChild();
                    return KeyEventResult.handled;
                  }
                }

                return KeyEventResult.ignored;
              },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxWidth < 1100;

            if (isCompact) {
              return Column(
                children: [
                  Expanded(flex: 4, child: _buildBoardPane()),
                  const Divider(height: 1, thickness: 1),
                  Expanded(flex: 5, child: _buildTabbedPane()),
                ],
              );
            }

            return Row(
              children: [
                Expanded(
                  flex: 6,
                  child: _buildBoardPane(),
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  flex: 4,
                  child: _buildTabbedPane(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildBoardPane() {
    return Stack(
      children: [
        Container(
          padding: const EdgeInsets.all(16.0),
          child: Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: ChessBoardWidget(
                key: ValueKey(_controller.fen),
                position: _controller.position,
                flipped: _boardFlipped,
                onPieceSelected: (square) {},
                onMove: (CompletedMove move) {
                  _handleMove(move);
                },
              ),
            ),
          ),
        ),
        if (_isGenerating)
          Positioned.fill(
            child: Container(
              color: Colors.black.withValues(alpha: 0.6),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 24,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _isGenerationPaused
                          ? Colors.amber[700]!
                          : Colors.orange[800]!,
                      width: 1.5,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!_isGenerationPaused)
                        const SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        )
                      else
                        Icon(
                          Icons.pause_circle_filled,
                          size: 36,
                          color: Colors.amber[400],
                        ),
                      const SizedBox(height: 14),
                      Text(
                        _isGenerationPaused
                            ? 'Generation Paused'
                            : 'Generating Repertoire...',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isGenerationPaused
                            ? 'Resume to continue building, or switch tabs to inspect the current position.'
                            : 'All other features are locked.\nPlease leave this running.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey[400],
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        alignment: WrapAlignment.center,
                        children: [
                          if (!_isGenerationPaused)
                            FilledButton.icon(
                              onPressed: () {
                                _generationTabKey.currentState?.togglePause();
                              },
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.amber[800],
                              ),
                              icon: const Icon(Icons.pause, color: Colors.white),
                              label: const Text(
                                'Pause',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (_isGenerationPaused) ...[
                            FilledButton.icon(
                              onPressed: () {
                                _generationTabKey.currentState?.togglePause();
                              },
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.green[700],
                              ),
                              icon: const Icon(
                                Icons.play_arrow,
                                color: Colors.white,
                              ),
                              label: const Text(
                                'Resume',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            FilledButton.icon(
                              onPressed: () {
                                _generationTabKey.currentState?.cancelGeneration();
                              },
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.red[700],
                              ),
                              icon: const Icon(Icons.stop, color: Colors.white),
                              label: const Text(
                                'Cancel',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTabbedPane() {
    return Container(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          IgnorePointer(
            ignoring: _isGenerating && !_isGenerationPaused,
            child: Opacity(
              opacity: _isGenerating && !_isGenerationPaused ? 0.35 : 1.0,
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: const [
                  Tab(text: 'Tree', icon: Icon(Icons.account_tree, size: 16)),
                  Tab(
                    text: 'Engine',
                    icon: Icon(Icons.developer_board, size: 16),
                  ),
                  Tab(text: 'PGN', icon: Icon(Icons.description, size: 16)),
                  Tab(
                    text: 'Lines',
                    icon: Icon(Icons.library_books, size: 16),
                  ),
                  Tab(
                    text: 'Generate',
                    icon: Icon(Icons.auto_awesome, size: 16),
                  ),
                  Tab(text: 'Eval Tree', icon: Icon(Icons.insights, size: 16)),
                  Tab(text: 'Actions', icon: Icon(Icons.settings, size: 16)),
                ],
              ),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              physics: _isGenerating && !_isGenerationPaused
                  ? const NeverScrollableScrollPhysics()
                  : null,
              children: [
                _buildOpeningTreeTab(),
                _KeepAliveTab(child: _buildEngineTab()),
                _buildPgnTab(),
                _buildLinesTab(),
                _KeepAliveTab(child: _buildGenerateTab()),
                _buildEvalTreeTab(),
                _buildActionsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar({
    required Widget title,
    bool showSelectRepertoireAction = false,
  }) {
    return AppBar(
      titleSpacing: 16,
      title: title,
      actions: [
        if (_isGenerating) _buildGenerationStatusChip(),
        const AppModeMenuButton(),
        if (showSelectRepertoireAction) _buildSelectRepertoireButton(),
      ],
    );
  }

  Widget _buildRepertoireTitle() {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Repertoire Builder',
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
        _buildRepertoireSubtitle(theme),
      ],
    );
  }

  Widget _buildGenerationStatusChip() {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: _isGenerationPaused ? Colors.amber[800] : Colors.orange[900],
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_isGenerationPaused)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              else
                const Icon(Icons.pause, size: 12, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                _isGenerationPaused ? 'Paused' : 'Building...',
                style: const TextStyle(fontSize: 11, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectRepertoireButton() {
    final compact = MediaQuery.sizeOf(context).width < 760;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: compact
            ? IconButton(
                tooltip: 'Select repertoire',
                onPressed: _isGenerating ? null : _showRepertoireSelection,
                icon: const Icon(Icons.library_books),
              )
            : TextButton.icon(
                onPressed: _isGenerating ? null : _showRepertoireSelection,
                icon: const Icon(Icons.library_books),
                label: const Text('Select Repertoire'),
              ),
      ),
    );
  }

  Widget _buildRepertoireSubtitle(ThemeData theme) {
    if (_controller.currentRepertoire == null) return const SizedBox.shrink();

    final name = _controller.currentRepertoire!['name'] as String? ?? 'Unknown';
    final gameCount = _controller.currentRepertoire!['gameCount'] as int? ?? 0;

    return Text(
      '$name • $gameCount game${gameCount == 1 ? '' : 's'}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall,
    );
  }

  Widget _buildLinesTab() {
    if (_controller.repertoireLines.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.library_books, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                'No lines found in repertoire',
                style: TextStyle(color: Colors.grey),
              ),
              SizedBox(height: 8),
              Text(
                'Load a PGN repertoire file to see lines here',
                style: TextStyle(color: Colors.grey, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return RepertoireLinesBrowser(
      lines: _controller.repertoireLines,
      currentMoveSequence: _controller.currentMoveSequence,
      isExpanded: true,
      onLineSelected: (line) {
        _controller.loadPgnLine(line);
        _tabController.animateTo(2);
      },
      onLineRenamed: _renameLine,
    );
  }

  Widget _buildPgnTab() {
    return Container(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          // Controls
          Row(
            children: [
              Expanded(
                child: Text(
                  'PGN Editor',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Reload',
                onPressed: _reloadRepertoire,
              ),
            ],
          ),
          const Divider(),

          // Interactive PGN editor
          Expanded(
            child: InteractivePgnEditor(
              // Force recreation when selected line or starting FEN changes
              key: ValueKey(
                  '${_controller.selectedPgnLine?.id ?? 'no_selection'}_${_controller.startingFen ?? 'standard'}'),
              controller: _pgnEditorController,
              // Load selected line PGN or default to repertoire PGN
              initialPgn: _getInitialPgnForEditor(),
              // Pass current repertoire name and color
              currentRepertoireName:
                  _controller.currentRepertoire?['name'] as String?,
              repertoireColor:
                  _controller.isRepertoireWhite ? 'White' : 'Black',
              moveHistory: _controller.moveHistory,
              currentMoveIndex: _controller.currentMoveIndex,
              // Pass starting FEN for custom positions (e.g., pasted via Ctrl+Shift+V)
              startingFen: _controller.startingFen,
              // New unified state callback
              onMoveStateChanged: (moveIndex, moves) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  if (!_controller.isInternalUpdate) {
                    _controller.syncFromMoveIndex(moveIndex, moves);
                  }
                });
              },
              onPositionChanged: (position) {
                // Keep for backward compatibility but defer to onMoveStateChanged
              },
              onPgnChanged: (pgn) {
                // Clear selected line when user edits
                if (_controller.selectedPgnLine != null) {
                  _controller.clearSelectedPgnLine();
                }
              },
              onLineSaved: (moves, title, pgn) {
                _controller.appendNewLine(moves, title, pgn);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEngineTab() {
    return Container(
      padding: const EdgeInsets.all(8.0),
      child: UnifiedEnginePane(
        fen: _controller.fen,
        isActive:
            _tabController.index == 1 && (!_isGenerating || _isGenerationPaused),
        isUserTurn: _controller.position.turn ==
            (_controller.isRepertoireWhite ? Side.white : Side.black),
        currentMoveSequence: _controller.currentMoveSequence,
        isWhiteRepertoire: _controller.isRepertoireWhite,
        onMoveSelected: (uciMove) {
          final san = uciToSan(_controller.fen, uciMove);
          if (san != uciMove) {
            _controller.userPlayedMove(san);
          }
        },
        onSetRoot: _controller.rootMoves.isEmpty
            ? () async {
                await _controller.setRootPosition();
                EngineSettings().probabilityStartMoves = _controller.rootMoves;
                if (mounted) setState(() {});
              }
            : null,
      ),
    );
  }

  Widget _buildGenerateTab() {
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
          if (!generating) _isGenerationPaused = false;
        });
        context.read<AppState>().setRepertoireGenerating(generating);
        if (generating) {
          _tabController.animateTo(4);
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
        setState(() {
          _generatedTree = null;
          _generatedTreeResetCounter++;
        });
      },
      onTreeBuilt: (tree) {
        if (!mounted) return;
        setState(() => _generatedTree = tree);
      },
    );
  }

  Widget _buildOpeningTreeTab() {
    if (_controller.openingTree == null) {
      return Container(
        padding: const EdgeInsets.all(8.0),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.account_tree, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                'No repertoire data available',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          // Opening tree explorer
          Expanded(
            flex: 3,
            child: OpeningTreeWidget(
              tree: _controller.openingTree!,
              showPgnSearch: false, // Disabled - using new browser below
              repertoireLines: _controller.repertoireLines,
              currentMoveSequence: _controller.currentMoveSequence,
              onMoveSelected: (move) {
                // Handle tree move selection
                _controller.userSelectedTreeMove(move);
              },
              onGoBack: () => _controller.goBack(),
              onGoForward: () => _controller.goForward(),
              onPositionSelected: (fen) {
                // Deprecated: Use onMoveSelected instead
              },
              onLineSelected: (line) {
                _selectLine(line);
              },
            ),
          ),

          // Lines browser section
          if (_controller.repertoireLines.isNotEmpty) ...[
            const Divider(height: 1),

            // Quick access header with expand button
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              child: Row(
                children: [
                  Icon(Icons.library_books, size: 16, color: Colors.grey[400]),
                  const SizedBox(width: 8),
                  Text(
                    'Lines (${_controller.repertoireLines.length})',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[300],
                    ),
                  ),
                  if (_controller.currentMoveSequence.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.blue[800],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${_getMatchingLinesCount()} matching',
                        style:
                            const TextStyle(fontSize: 10, color: Colors.white),
                      ),
                    ),
                  ],
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.open_in_full, size: 18),
                    tooltip: 'Open full browser',
                    onPressed: _showFullLinesBrowser,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                ],
              ),
            ),

            // Inline compact browser
            Expanded(
              flex: 2,
              child: RepertoireLinesBrowser(
                lines: _controller.repertoireLines,
                currentMoveSequence: _controller.currentMoveSequence,
                onLineSelected: _selectLine,
                onLineRenamed: _renameLine,
              ),
            ),
          ],
        ],
      ),
    );
  }

  int _getMatchingLinesCount() {
    final currentMoves = _controller.currentMoveSequence;
    if (currentMoves.isEmpty) return _controller.repertoireLines.length;

    return _controller.repertoireLines.where((line) {
      if (currentMoves.length > line.moves.length) return false;
      for (int i = 0; i < currentMoves.length; i++) {
        if (line.moves[i] != currentMoves[i]) return false;
      }
      return true;
    }).length;
  }

  void _selectLine(RepertoireLine line) {
    _controller.loadPgnLine(line);
    _tabController.animateTo(2);
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

  void _showFullLinesBrowser() {
    showDialog(
      context: context,
      builder: (context) => RepertoireLinesBrowserDialog(
        lines: _controller.repertoireLines,
        currentMoveSequence: _controller.currentMoveSequence,
        onLineSelected: _selectLine,
        onLineRenamed: _renameLine,
      ),
    );
  }

  Widget _buildEvalTreeTab() {
    return EvalTreeTab(
      currentRepertoire: _controller.currentRepertoire,
      isWhiteRepertoire: _controller.isRepertoireWhite,
      generatedTree: _generatedTree,
      treeResetCounter: _generatedTreeResetCounter,
      onPositionSelected: (selection) {
        final synced = _controller.setPositionFromMoveHistory(
          fen: selection.fen,
          moves: selection.fullMovePathSan,
          startingFen: selection.startingFen,
        );
        if (!synced) {
          _controller.setPositionFromFen(selection.fen);
        }
      },
      onControllerReady: (controller) {
        _evalTreeController = controller;
      },
    );
  }

  Widget _buildActionsTab() {
    return Container(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          Text(
            'Actions',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Divider(),

          // Action buttons
          Expanded(
            child: ListView(
              children: [
                // Coverage Calculator - Featured action
                Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.3),
                    ),
                  ),
                  child: ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.analytics_outlined,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                    title: const Text(
                      'Coverage Calculator',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                        'Analyze repertoire coverage with Lichess data'),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    onTap: _showCoverageCalculator,
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.expand_more, color: Colors.blue),
                    title: const Text('Expand Repertoire'),
                    subtitle:
                        const Text('Add variations using Lichess database'),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    onTap: _expandRepertoire,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.quiz, color: Colors.green),
                    title: const Text('Train Repertoire'),
                    subtitle: const Text('Practice with spaced repetition'),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    onTap: _trainRepertoire,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading:
                        const Icon(Icons.sports_esports, color: Colors.orange),
                    title: const Text('Expand via Quiz'),
                    subtitle:
                        const Text('Play against database to build repertoire'),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    onTap: _expandViaQuiz,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading:
                        const Icon(Icons.upload_file, color: Colors.purple),
                    title: const Text('Import PGN'),
                    subtitle: const Text('Add games to current repertoire'),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    onTap: _importPgn,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
      // Tell the controller to set the new repertoire
      await _controller.setRepertoire(result);
    }
  }

  Future<void> _reloadRepertoire() async {
    // Tell the controller to reload
    await _controller.loadRepertoire();
  }

  /// Handle moves from the chessboard - board has already made the move and gives us rich info
  void _handleMove(CompletedMove move) {
    if (!mounted) return;

    // Use the unified state approach:
    // 1. Tell controller about the move (updates move history, position, tree)
    _controller.userPlayedMove(move.san);
  }

  void _showCoverageCalculator() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .outline
                      .withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Close button row
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              // Coverage Calculator Widget - root is auto-detected
              Expanded(
                child: CoverageCalculatorWidget(
                  openingTree: _controller.openingTree,
                  isWhiteRepertoire: _controller.isRepertoireWhite,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _expandRepertoire() {
    _showFeatureNotImplemented('Expand Repertoire');
  }

  void _trainRepertoire() {
    if (_controller.currentRepertoire == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RepertoireTrainingScreen(
          repertoire: _controller.currentRepertoire!,
        ),
      ),
    );
  }

  void _expandViaQuiz() {
    _showFeatureNotImplemented('Expand via Quiz');
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
      'Imported $added game${added == 1 ? '' : 's'} into repertoire.',
    );
  }

  void _showFeatureNotImplemented(String featureName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Feature Not Implemented'),
        content:
            Text('$featureName feature will be implemented in the future.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

/// Wraps a child widget so [TabBarView] keeps it alive when off-screen.
class _KeepAliveTab extends StatefulWidget {
  final Widget child;
  const _KeepAliveTab({required this.child});

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    return widget.child;
  }
}
