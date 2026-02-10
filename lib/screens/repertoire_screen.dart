/// Repertoire screen - Full-screen repertoire view
/// Shows repertoire positions with two-panel layout: board and tabbed panel
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chess/chess.dart' as chess;

import '../core/repertoire_controller.dart';
import '../models/opening_tree.dart';
import '../models/repertoire_line.dart';
import '../services/repertoire_service.dart';
import '../widgets/chess_board_widget.dart';
import '../widgets/coverage_calculator_widget.dart';
import '../widgets/engine_analysis_widget.dart';
import '../widgets/interactive_pgn_editor.dart';
import '../widgets/opening_tree_widget.dart';
import '../widgets/repertoire_lines_browser.dart';
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
  // All state is now managed by the controller
  late final RepertoireController _controller;
  late final TabController _tabController;
  final PgnEditorController _pgnEditorController = PgnEditorController();
  
  // Board orientation - true = Black's perspective (board flipped)
  bool _boardFlipped = false;
  
  // Track which repertoire we last set the flip for (to reset on switch)
  String? _lastRepertoireId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging || _tabController.animation?.value == _tabController.index) {
        setState(() {});
      }
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
      // Update board orientation when a new repertoire finishes loading
      // We check !isLoading to ensure the color has been determined from the PGN
      if (_controller.currentRepertoire != null && !_controller.isLoading) {
        final currentId = _controller.currentRepertoire!['filePath'] as String?;
        if (currentId != null && currentId != _lastRepertoireId) {
          // New repertoire loaded - set orientation based on color
          _lastRepertoireId = currentId;
          _boardFlipped = !_controller.isRepertoireWhite; // Flip for Black repertoires
        }
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    // 4. Clean up the controller and listener
    _controller.removeListener(_onRepertoireChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Loading state
    if (_controller.isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Repertoire Builder')),
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
        appBar: AppBar(title: const Text('Repertoire Builder')),
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
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Repertoire Builder', style: TextStyle(fontSize: 16)),
            _buildRepertoireSubtitle(),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.library_books),
            tooltip: 'Select Repertoire',
            onPressed: _showRepertoireSelection,
          ),
        ],
      ),
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;

          // Ctrl+Shift+V - Paste FEN from clipboard
          if (event.logicalKey == LogicalKeyboardKey.keyV &&
              HardwareKeyboard.instance.isControlPressed &&
              HardwareKeyboard.instance.isShiftPressed) {
            _pastePositionFromClipboard();
            return KeyEventResult.handled;
          }

          // 'F' key - Flip the board (only if not typing in a text field)
          // Check if we're in the PGN tab where text fields exist
          if (event.logicalKey == LogicalKeyboardKey.keyF &&
              !HardwareKeyboard.instance.isControlPressed &&
              !HardwareKeyboard.instance.isShiftPressed &&
              !HardwareKeyboard.instance.isAltPressed) {
            // Don't flip if PGN tab is active (has text fields for comments)
            // User can still flip with the keyboard when not focused on a text field
            final primaryFocus = FocusManager.instance.primaryFocus;
            final isTextInput = primaryFocus?.context?.widget is EditableText;
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
            } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              _pgnEditorController.goForward();
              return KeyEventResult.handled;
            }
          }
          // Tree Tab (Index 0) or Lines Tab (Index 1) - Main controller handles navigation
          else if (_tabController.index == 0 || _tabController.index == 1) {
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              _controller.goBack();
              return KeyEventResult.handled;
            } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              _controller.goForward();
              return KeyEventResult.handled;
            }
          }
          // Engine Tab (Index 3) - Main controller handles navigation
          else if (_tabController.index == 3) {
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              _controller.goBack();
              return KeyEventResult.handled;
            } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              _controller.goForward();
              return KeyEventResult.handled;
            }
          }
          
          return KeyEventResult.ignored;
        },
        child: Row(
          children: [
            // Left panel - Chess board (60% of width)
            Expanded(
              flex: 6,
              child: Container(
                padding: const EdgeInsets.all(16.0),
                child: ChessBoardWidget(
                  // Force widget recreation when position changes to prevent race conditions
                  key: ValueKey(_controller.fen),
                  // Read game state from controller
                  game: _controller.game,
                  flipped: _boardFlipped,
                  onPieceSelected: (square) {
                    // Handle piece selection if needed
                  },
                  onMove: (CompletedMove move) {
                    // Handle moves in repertoire
                    _handleMove(move);
                  },
                ),
              ),
            ),

            // Divider
            const VerticalDivider(width: 1, thickness: 1),

            // Right panel - Tabbed content (40% of width)
            Expanded(
              flex: 4,
              child: Container(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  children: [
                    // Tab bar
                    TabBar(
                      controller: _tabController,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: const [
                        Tab(text: 'Tree', icon: Icon(Icons.account_tree, size: 16)),
                        Tab(text: 'Lines', icon: Icon(Icons.library_books, size: 16)),
                        Tab(text: 'PGN', icon: Icon(Icons.description, size: 16)),
                        Tab(text: 'Engine', icon: Icon(Icons.developer_board, size: 16)),
                        Tab(text: 'Actions', icon: Icon(Icons.settings, size: 16)),
                      ],
                    ),
                    // Tab views
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildOpeningTreeTab(),
                          _buildLinesTab(),
                          _buildPgnTab(),
                          _buildEngineTab(),
                          _buildActionsTab(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRepertoireSubtitle() {
    if (_controller.currentRepertoire == null) return const SizedBox.shrink();

    final name =
        _controller.currentRepertoire!['name'] as String? ?? 'Unknown';
    final gameCount =
        _controller.currentRepertoire!['gameCount'] as int? ?? 0;

    return Text(
      '$name • $gameCount game${gameCount == 1 ? '' : 's'}',
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
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
        // Switch to PGN tab (now at index 2)
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
              key: ValueKey('${_controller.selectedPgnLine?.id ?? 'no_selection'}_${_controller.startingFen ?? 'standard'}'),
              controller: _pgnEditorController,
              // Load selected line PGN or default to repertoire PGN
              initialPgn: _getInitialPgnForEditor(),
              // Pass current repertoire name and color
              currentRepertoireName: _controller.currentRepertoire?['name'] as String?,
              repertoireColor: _controller.currentRepertoire?['color'] as String?,
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
    // Calculate if the engine tab is currently active/visible
    final isEngineTabActive = _tabController.index == 3;

    return Container(
      padding: const EdgeInsets.all(8.0),
      child: UnifiedEnginePane(
        fen: _controller.fen,
        isActive: isEngineTabActive,
        isUserTurn: _controller.game.turn == (_controller.isRepertoireWhite ? chess.Color.WHITE : chess.Color.BLACK),
        currentMoveSequence: _controller.currentMoveSequence,
        isWhiteRepertoire: _controller.isRepertoireWhite,
        onEaseDetailsTap: () {
          // Switch to a detailed ease view if needed
          _showEaseDetails();
        },
        onMoveSelected: (uciMove) {
          // Convert UCI (e2e4) to SAN for consistency
          try {
            final from = uciMove.substring(0, 2);
            final to = uciMove.substring(2, 4);
            String? promotion;
            if (uciMove.length > 4) promotion = uciMove.substring(4);
            
            // We need to find the move in legal moves to get SAN
            final moves = _controller.game.moves({ 'verbose': true });
            // This is a list of maps. Find the matching one.
            final match = moves.firstWhere((m) => 
              m['from'] == from && 
              m['to'] == to && 
              (promotion == null || m['promotion'] == promotion),
              orElse: () => null
            );
            
            if (match != null) {
              _controller.userPlayedMove(match['san']);
            }
          } catch (e) {
            print('Error playing engine move: $e');
          }
        },
      ),
    );
  }
  
  void _showEaseDetails() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
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
                  color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Title and close
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.speed, color: Colors.orange),
                    const SizedBox(width: 8),
                    Text(
                      'Ease Analysis Details',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(),
              // Full ease widget
              Expanded(
                child: EngineAnalysisWidget(
                  fen: _controller.fen,
                  isActive: true,
                  isUserTurn: _controller.game.turn == (_controller.isRepertoireWhite ? chess.Color.WHITE : chess.Color.BLACK),
                  onMoveSelected: (uciMove) {
                    Navigator.of(context).pop();
                    try {
                      final from = uciMove.substring(0, 2);
                      final to = uciMove.substring(2, 4);
                      String? promotion;
                      if (uciMove.length > 4) promotion = uciMove.substring(4);
                      
                      final moves = _controller.game.moves({ 'verbose': true });
                      final match = moves.firstWhere((m) => 
                        m['from'] == from && 
                        m['to'] == to && 
                        (promotion == null || m['promotion'] == promotion),
                        orElse: () => null
                      );
                      
                      if (match != null) {
                        _controller.userPlayedMove(match['san']);
                      }
                    } catch (e) {
                      print('Error playing engine move: $e');
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ),
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
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.blue[800],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${_getMatchingLinesCount()} matching',
                        style: const TextStyle(fontSize: 10, color: Colors.white),
                      ),
                    ),
                  ],
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.open_in_full, size: 18),
                    tooltip: 'Open full browser',
                    onPressed: _showFullLinesBrowser,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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
    // Load the selected PGN line - this updates move history
    _controller.loadPgnLine(line);
    // Switch to PGN tab (index 2 after adding Lines tab)
    _tabController.animateTo(2);
  }

  Future<void> _renameLine(RepertoireLine line, String newTitle) async {
    final filePath = _controller.currentRepertoire?['filePath'] as String?;
    if (filePath == null) return;

    final service = RepertoireService();
    final success = await service.updateLineTitle(filePath, line.id, newTitle);

    if (success) {
      // Reload repertoire to pick up the change
      await _controller.loadRepertoire();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Renamed to "$newTitle"')),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to rename line')),
        );
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
                      color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
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
                    title: const Text('Coverage Calculator',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text('Analyze repertoire coverage with Lichess data'),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    onTap: _showCoverageCalculator,
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.expand_more, color: Colors.blue),
                    title: const Text('Expand Repertoire'),
                    subtitle: const Text('Add variations using Lichess database'),
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
                    leading: const Icon(Icons.sports_esports, color: Colors.orange),
                    title: const Text('Expand via Quiz'),
                    subtitle: const Text('Play against database to build repertoire'),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    onTap: _expandViaQuiz,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.upload_file, color: Colors.purple),
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Clipboard is empty'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      final fen = clipboardData.text!.trim();
      if (fen.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Clipboard is empty'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      final success = _controller.setPositionFromFen(fen);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success
                ? 'Position loaded from FEN'
                : 'Invalid FEN: $fen'),
            duration: const Duration(seconds: 2),
            backgroundColor: success ? Colors.green : Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to read clipboard: $e'),
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  String? _getInitialPgnForEditor() {
    // If a specific PGN line is selected, return its full PGN
    if (_controller.selectedPgnLine != null) {
      return _controller.selectedPgnLine!.fullPgn;
    }
    // Otherwise return the full repertoire PGN
    return _controller.repertoirePgn;
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
                  color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
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

  void _importPgn() {
    _showFeatureNotImplemented('Import PGN');
  }

  void _showFeatureNotImplemented(String featureName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Feature Not Implemented'),
        content: Text('$featureName feature will be implemented in the future.'),
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