/// Repertoire screen - Full-screen repertoire view
/// Shows repertoire positions with two-panel layout: board and tabbed panel
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chess/chess.dart' as chess;
import 'package:dartchess_webok/dartchess_webok.dart';
import 'dart:io' as io;

import '../widgets/chess_board_widget.dart';
import '../widgets/interactive_pgn_editor.dart';
import '../widgets/opening_tree_widget.dart';
import '../widgets/engine_analysis_widget.dart';
import '../models/opening_tree.dart';
import '../models/repertoire_line.dart';
import '../services/opening_tree_builder.dart';
import '../services/repertoire_service.dart';
import 'repertoire_selection_screen.dart';
import 'repertoire_training_screen.dart';

// -------------------------------------------------------------------
// 1. REPERTOIRE CONTROLLER
// -------------------------------------------------------------------
/// Manages the state and business logic for the repertoire screen.
/// This uses ChangeNotifier to notify the UI of updates.
///
/// KEY ARCHITECTURE: This controller is the SINGLE SOURCE OF TRUTH.
/// - _moveHistory is the canonical state (list of SAN moves)
/// - Board, PGN editor, and Opening Tree all derive their state from this
/// - When any component changes position, it calls controller methods which
///   update _moveHistory and notify all listeners
class RepertoireController with ChangeNotifier {
  Map<String, dynamic>? _currentRepertoire;
  Map<String, dynamic>? get currentRepertoire => _currentRepertoire;

  String? _repertoirePgn;
  String? get repertoirePgn => _repertoirePgn;

  OpeningTree? _openingTree;
  OpeningTree? get openingTree => _openingTree;

  List<RepertoireLine> _repertoireLines = [];
  List<RepertoireLine> get repertoireLines => _repertoireLines;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  // ============================================================
  // SOURCE OF TRUTH: Move history and derived position
  // ============================================================

  /// The canonical move history - THIS is the source of truth
  List<String> _moveHistory = [];
  List<String> get moveHistory => List.unmodifiable(_moveHistory);

  /// Current move index (-1 = starting position, 0 = after first move, etc.)
  int _currentMoveIndex = -1;
  int get currentMoveIndex => _currentMoveIndex;

  /// Derived position from move history
  chess.Chess _game = chess.Chess();
  chess.Chess get game => _game;
  String get fen => _game.fen;

  /// Convert Chess to Position for dartchess compatibility
  Position get position => Chess.fromSetup(Setup.parseFen(_game.fen));

  /// Get current move sequence (moves up to current index)
  List<String> get currentMoveSequence {
    if (_currentMoveIndex < 0) return [];
    return _moveHistory.sublist(0, _currentMoveIndex + 1);
  }

  // Flag to prevent update loops between board and PGN editor
  bool _isInternalUpdate = false;
  bool get isInternalUpdate => _isInternalUpdate;

  // ============================================================
  // UNIFIED STATE MANAGEMENT METHODS
  // ============================================================

  /// Called when user makes a move on the board or clicks an explorer move
  /// This is THE method to use for any new move
  void userPlayedMove(String sanMove) {
    // Validate move against current position using a test game
    final testGame = chess.Chess.fromFEN(_game.fen);
    final isValid = testGame.move(sanMove);
    if (!isValid) {
      print('Invalid move: $sanMove for position ${_game.fen}');
      return;
    }

    // If we're not at the end of the line, check if this creates a variation
    if (_currentMoveIndex < _moveHistory.length - 1) {
      final existingNextMove = _moveHistory[_currentMoveIndex + 1];
      if (existingNextMove == sanMove) {
        // Same move - just advance
        _currentMoveIndex++;
        _rebuildPosition();
        _syncOpeningTree();
        notifyListeners();
        return;
      }
      // Different move - truncate and add new move (or create variation in future)
      _moveHistory = _moveHistory.sublist(0, _currentMoveIndex + 1);
    }

    // Add the move
    _moveHistory.add(sanMove);
    _currentMoveIndex++;

    // Rebuild position and sync tree
    _rebuildPosition();
    _syncOpeningTree();
    notifyListeners();
  }

  /// Called when user selects a move in the opening tree
  /// This handles branching from the current tree position
  void userSelectedTreeMove(String sanMove) {
    if (_openingTree == null) return;

    // Determine where we are branching from based on tree depth
    // If tree is "out of book", this allows us to recover/branch from the last known book position
    final branchIndex = _openingTree!.currentDepth;

    // Truncate history to the branch point if necessary
    if (branchIndex < _moveHistory.length) {
      _moveHistory = _moveHistory.sublist(0, branchIndex);
    }

    // Add the new move
    _moveHistory.add(sanMove);
    _currentMoveIndex = _moveHistory.length - 1;

    // Rebuild and sync
    _rebuildPosition();
    _syncOpeningTree();
    notifyListeners();
  }

  /// Jump to a specific move index in the history
  /// -1 = starting position, 0 = after first move, etc.
  void jumpToMoveIndex(int index) {
    if (index < -1 || index >= _moveHistory.length) return;
    if (index == _currentMoveIndex) return;

    _currentMoveIndex = index;
    _rebuildPosition();
    _syncOpeningTree();
    notifyListeners();
  }

  /// Go back one move
  void goBack() {
    if (_currentMoveIndex >= 0) {
      jumpToMoveIndex(_currentMoveIndex - 1);
    }
  }

  /// Go forward one move
  void goForward() {
    if (_currentMoveIndex < _moveHistory.length - 1) {
      jumpToMoveIndex(_currentMoveIndex + 1);
    }
  }

  /// Go to start
  void goToStart() {
    jumpToMoveIndex(-1);
  }

  /// Go to end
  void goToEnd() {
    jumpToMoveIndex(_moveHistory.length - 1);
  }

  /// Load a specific line of moves (replaces current history)
  void loadMoveHistory(List<String> moves) {
    _moveHistory = List.from(moves);
    _currentMoveIndex = moves.isEmpty ? -1 : moves.length - 1;
    _rebuildPosition();
    _syncOpeningTree();
    notifyListeners();
  }

  /// Clear the current line
  void clearMoveHistory() {
    _moveHistory.clear();
    _currentMoveIndex = -1;
    _game = chess.Chess();
    _syncOpeningTree();
    notifyListeners();
  }

  /// Rebuild the chess position from move history up to current index
  void _rebuildPosition() {
    _game = chess.Chess();
    for (int i = 0; i <= _currentMoveIndex && i < _moveHistory.length; i++) {
      final result = _game.move(_moveHistory[i]);
      if (!result) {
        break;
      }
    }
  }

  /// Sync the opening tree to match current move history
  void _syncOpeningTree() {
    if (_openingTree != null) {
      _openingTree!.syncToMoveHistory(currentMoveSequence);
    }
  }

  // --- Public Methods ---

  /// Sets a new repertoire and triggers loading.
  Future<void> setRepertoire(Map<String, dynamic> repertoire) async {
    _currentRepertoire = repertoire;
    notifyListeners(); // Notify UI that repertoire has changed
    await loadRepertoire(); // Start loading
  }

  /// (Re)loads the PGN content for the current repertoire.
  Future<void> loadRepertoire() async {
    if (_currentRepertoire == null) return;
    _setLoading(true);

    try {
      final filePath = _currentRepertoire!['filePath'] as String;
      final file = io.File(filePath);

      if (await file.exists()) {
        _repertoirePgn = await file.readAsString();

        // Reset all state when loading a new repertoire
        _game = chess.Chess();
        _moveHistory.clear();
        _currentMoveIndex = -1;

        // Build opening tree from the repertoire PGN
        await _buildOpeningTree();

        // Parse repertoire lines for PGN browser
        await _parseRepertoireLines();
      } else {
        _repertoirePgn = null;
        _openingTree = null;
        _repertoireLines = [];
        _game = chess.Chess();
        _moveHistory.clear();
        _currentMoveIndex = -1;
      }
    } catch (e) {
      print('Failed to load repertoire: $e');
      _repertoirePgn = null;
      _openingTree = null;
      _repertoireLines = [];
      _game = chess.Chess();
      _moveHistory.clear();
      _currentMoveIndex = -1;
    } finally {
      _setLoading(false);
    }
  }

  /// Parses repertoire lines for PGN browser
  Future<void> _parseRepertoireLines() async {
    if (_repertoirePgn == null || _repertoirePgn!.isEmpty) {
      _repertoireLines = [];
      return;
    }

    try {
      final service = RepertoireService();
      _repertoireLines = service.parseRepertoirePgn(_repertoirePgn!);
      print('✅ Parsed ${_repertoireLines.length} repertoire lines for PGN browser');
    } catch (e) {
      print('❌ Failed to parse repertoire lines: $e');
      _repertoireLines = [];
    }
  }

  /// Builds an opening tree from the current repertoire PGN
  Future<void> _buildOpeningTree() async {
    if (_repertoirePgn == null || _repertoirePgn!.isEmpty) {
      _openingTree = OpeningTree();
      return;
    }

    try {
      // Parse repertoire color from comments
      String? repertoireColor;
      final lines = _repertoirePgn!.split('\n');

      for (final line in lines) {
        final trimmedLine = line.trim();
        if (trimmedLine.startsWith('// Color:')) {
          repertoireColor = trimmedLine.substring(9).trim(); // Remove "// Color:" prefix
          break;
        }
      }

      // Default to White if no color specified
      final isWhiteRepertoire = repertoireColor != 'Black';

      // Parse PGN content properly - each game starts with headers and ends with moves
      final processedGames = <String>[];

      String? currentEvent;
      String? currentDate;
      String? currentWhite;
      String? currentBlack;
      String? currentResult;
      final moveLines = <String>[];

      for (final line in lines) {
        final trimmedLine = line.trim();

        // Skip comment lines
        if (trimmedLine.startsWith('//')) {
          continue;
        }

        // Parse headers
        if (trimmedLine.startsWith('[Event ')) {
          // New game starting - save previous if it has moves
          if (currentEvent != null && moveLines.isNotEmpty) {
            final game = _buildGame(currentEvent, currentDate, currentWhite, currentBlack, currentResult, moveLines);
            if (game != null) {
              processedGames.add(game);
            }
          }

          // Start new game
          currentEvent = _extractHeaderValue(trimmedLine);
          currentDate = null;
          currentWhite = null;
          currentBlack = null;
          currentResult = null;
          moveLines.clear();
        } else if (trimmedLine.startsWith('[Date ')) {
          currentDate = _extractHeaderValue(trimmedLine);
        } else if (trimmedLine.startsWith('[White ')) {
          currentWhite = _extractHeaderValue(trimmedLine);
        } else if (trimmedLine.startsWith('[Black ')) {
          currentBlack = _extractHeaderValue(trimmedLine);
        } else if (trimmedLine.startsWith('[Result ')) {
          currentResult = _extractHeaderValue(trimmedLine);
        } else if (trimmedLine.isNotEmpty) {
          // This is a move line
          moveLines.add(trimmedLine);
        }
      }

      // Don't forget the last game
      if (currentEvent != null && moveLines.isNotEmpty) {
        final game = _buildGame(currentEvent, currentDate, currentWhite, currentBlack, currentResult, moveLines);
        if (game != null) {
          processedGames.add(game);
        }
      }

      // Debug: Track processing
      if (processedGames.isEmpty) {
        print('WARNING: No games processed for tree building');
      } else {
        print('Successfully processed ${processedGames.length} games for tree building');
      }

      if (processedGames.isEmpty) {
        _openingTree = OpeningTree();
        return;
      }

      // Build tree from the correct perspective based on repertoire color
      _openingTree = await OpeningTreeBuilder.buildTree(
        pgnList: processedGames,
        username: '', // Builder auto-detects repertoire player names
        userIsWhite: isWhiteRepertoire,
        maxDepth: 50,
        strictPlayerMatching: false, // Allow all games regardless of player names
      );

      print('✅ Built opening tree with ${_openingTree?.totalGames} total games');
    } catch (e) {
      print('❌ Failed to build opening tree: $e');
      _openingTree = OpeningTree(); // Empty tree as fallback
    }
  }


  /// Syncs the game state from an external source (like the PGN editor).
  /// This now uses move history matching to stay in sync.
  void syncGameFromFen(String fen) {
    // Prevent loops and redundant updates
    if (_game.fen == fen || _isInternalUpdate) {
      return;
    }

    // Don't use FEN-based sync anymore - let the PGN editor report its move index
    // This method is kept for backward compatibility but now does nothing
    // The proper sync happens via syncFromMoveIndex
  }

  /// Sync to a specific move index from the PGN editor
  void syncFromMoveIndex(int moveIndex, List<String> moves) {
    // Prevent loops
    if (_isInternalUpdate) return;

    // Update our move history to match the editor's
    _moveHistory = List.from(moves);
    _currentMoveIndex = moveIndex;
    _rebuildPosition();
    _syncOpeningTree();
    notifyListeners();
  }

  /// Handles position changes from the opening tree
  /// When user clicks a move in the tree, we load that move sequence
  void onTreePositionChanged(String fen) {
    if (_openingTree == null) return;

    // Get the move path from the tree's current node
    final moves = _openingTree!.currentNode.getMovePath();

    // Load this move sequence as our history
    _isInternalUpdate = true;
    _moveHistory = List.from(moves);
    _currentMoveIndex = moves.isEmpty ? -1 : moves.length - 1;
    _rebuildPosition();
    _isInternalUpdate = false;

    notifyListeners();
  }

  /// Loads a specific PGN line for editing
  void loadPgnLine(RepertoireLine line) {
    _selectedPgnLine = line;

    // Also load the line's moves into our move history
    _moveHistory = List.from(line.moves);
    _currentMoveIndex = line.moves.isEmpty ? -1 : line.moves.length - 1;
    _rebuildPosition();
    _syncOpeningTree();

    notifyListeners();
  }

  RepertoireLine? _selectedPgnLine;
  RepertoireLine? get selectedPgnLine => _selectedPgnLine;

  void clearSelectedPgnLine() {
    _selectedPgnLine = null;
    notifyListeners();
  }

  // --- Private Helpers ---

  /// Extract header value from PGN header line like '[White "Player Name"]'
  String? _extractHeaderValue(String line) {
    final start = line.indexOf('"') + 1;
    final end = line.lastIndexOf('"');
    if (start > 0 && end > start) {
      return line.substring(start, end);
    }
    return null;
  }

  /// Build a complete PGN game from parsed components
  String? _buildGame(String? event, String? date, String? white, String? black, String? result, List<String> moveLines) {
    if (moveLines.isEmpty) return null;

    final headers = <String>[];
    headers.add('[Event "${event ?? "Training Line"}"]');
    headers.add('[Date "${date ?? DateTime.now().toIso8601String().split('T')[0]}"]');
    headers.add('[White "${white ?? "Training"}"]');
    headers.add('[Black "${black ?? "Me"}"]');
    headers.add('[Result "${result ?? "1-0"}"]'); // Use original result or default to training win

    final moves = moveLines.join(' ');
    return [...headers, '', moves].join('\n');
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }
}

// -------------------------------------------------------------------
// 2. REPERTOIRE SCREEN WIDGET
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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
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
      // Just call setState. The controller holds the new data.
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
        appBar: AppBar(title: const Text('Repertoire')),
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
        appBar: AppBar(title: const Text('Repertoire')),
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
            const Text('Repertoire', style: TextStyle(fontSize: 16)),
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

          // PGN Tab (Index 1) - PGN Editor handles navigation
          if (_tabController.index == 1) {
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              _pgnEditorController.goBack();
              return KeyEventResult.handled;
            } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              _pgnEditorController.goForward();
              return KeyEventResult.handled;
            }
          }
          // Tree Tab (Index 0) - Main controller handles navigation
          else if (_tabController.index == 0) {
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
                  flipped: false,
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
                      tabs: const [
                        Tab(text: 'Tree', icon: Icon(Icons.account_tree, size: 16)),
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
              // Force recreation when selected line changes
              key: ValueKey(_controller.selectedPgnLine?.id ?? 'no_selection'),
              controller: _pgnEditorController,
              // Load selected line PGN or default to repertoire PGN
              initialPgn: _getInitialPgnForEditor(),
              // Pass current repertoire name and color
              currentRepertoireName: _controller.currentRepertoire?['name'] as String?,
              repertoireColor: _controller.currentRepertoire?['color'] as String?,
              moveHistory: _controller.moveHistory,
              currentMoveIndex: _controller.currentMoveIndex,
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
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEngineTab() {
    // Calculate if the engine tab is currently active/visible
    final isEngineTabActive = _tabController.index == 2;

    return Container(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          Text(
            'Engine Analysis',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Divider(),
          Expanded(
            child: EngineAnalysisWidget(
              fen: _controller.fen,
              isActive: isEngineTabActive,
            ),
          ),
        ],
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
      child: OpeningTreeWidget(
        tree: _controller.openingTree!,
        showPgnSearch: _controller.repertoireLines.isNotEmpty,
        repertoireLines: _controller.repertoireLines,
        currentMoveSequence: _controller.currentMoveSequence,
        onMoveSelected: (move) {
           // Handle tree move selection
           _controller.userSelectedTreeMove(move);
        },
        onPositionSelected: (fen) {
          // Deprecated: Use onMoveSelected instead
          // Keeping this empty or minimal as onMoveSelected handles the logic now
        },
        onLineSelected: (line) {
          // Load the selected PGN line - this updates move history
          _controller.loadPgnLine(line);

          // Switch to PGN tab
          _tabController.animateTo(1);
        },
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