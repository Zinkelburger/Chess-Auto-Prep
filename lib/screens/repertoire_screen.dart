/// Repertoire screen - Full-screen repertoire view
/// Shows repertoire positions with two-panel layout: board and tabbed panel
library;

import 'package:flutter/material.dart';
import 'package:chess/chess.dart' as chess;
import 'dart:io';

import '../widgets/chess_board_widget.dart';
import '../widgets/interactive_pgn_editor.dart';
import 'repertoire_selection_screen.dart';
import 'repertoire_training_screen.dart';

// -------------------------------------------------------------------
// 1. REPERTOIRE CONTROLLER
// -------------------------------------------------------------------
/// Manages the state and business logic for the repertoire screen.
/// This uses ChangeNotifier to notify the UI of updates.
class RepertoireController with ChangeNotifier {
  Map<String, dynamic>? _currentRepertoire;
  Map<String, dynamic>? get currentRepertoire => _currentRepertoire;

  String? _repertoirePgn;
  String? get repertoirePgn => _repertoirePgn;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  chess.Chess _game = chess.Chess();
  chess.Chess get game => _game;
  String get fen => _game.fen;

  // Flag to prevent update loops between board and PGN editor
  bool _isInternalUpdate = false;
  bool get isInternalUpdate => _isInternalUpdate;

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
      final file = File(filePath);

      if (await file.exists()) {
        _repertoirePgn = await file.readAsString();
        _game = chess.Chess(); // Reset to starting position
      } else {
        _repertoirePgn = null;
        _game = chess.Chess();
      }
    } catch (e) {
      print('Failed to load repertoire: $e');
      _repertoirePgn = null;
      _game = chess.Chess();
    } finally {
      _setLoading(false);
    }
  }


  /// Syncs the game state from an external source (like the PGN editor).
  void syncGameFromFen(String fen) {

    // Prevent loops and redundant updates
    if (_game.fen == fen || _isInternalUpdate) {
      return;
    }

    try {
      _game = chess.Chess.fromFEN(fen);
      notifyListeners();
    } catch (e) {
      print('Error syncing board position: $e');
    }
  }

  // --- Private Helpers ---

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  /// Parses a UCI move string into a Map for the chess.dart library
  Map<String, String> _parseUciToMoveMap(String moveUci) {
    final fromSquare = moveUci.substring(0, 2);
    final toSquare = moveUci.substring(2, 4);
    final moveMap = {
      'from': fromSquare,
      'to': toSquare,
    };
    if (moveUci.length > 4) {
      moveMap['promotion'] = moveUci.substring(4, 5);
    }
    return moveMap;
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
    _tabController = TabController(length: 3, vsync: this);

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
      body: Row(
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
                      Tab(text: 'PGN', icon: Icon(Icons.description, size: 16)),
                      Tab(text: 'Tree', icon: Icon(Icons.account_tree, size: 16)),
                      Tab(text: 'Actions', icon: Icon(Icons.settings, size: 16)),
                    ],
                  ),
                  // Tab views
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _buildPgnTab(),
                        _buildOpeningTreeTab(),
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
              controller: _pgnEditorController,
              // Read initial PGN from controller
              initialPgn: _controller.repertoirePgn,
              onPositionChanged: (position) {
                // Update board position when PGN editor changes position
                // This IS called during build, so it MUST be deferred.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;

                  // Only sync if this is NOT an internal update from the controller
                  // This prevents feedback loops when moves come from the board
                  if (!_controller.isInternalUpdate) {
                    _controller.syncGameFromFen(position.fen);
                  }
                });
              },
              onPgnChanged: (pgn) {
                // We might want to save this to the controller
                // _controller.updatePgn(pgn);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOpeningTreeTab() {
    return Container(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          Text(
            'Opening Tree',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Divider(),
          const Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.account_tree, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'Opening Tree View',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Coming soon...',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ],
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
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Repertoire reloaded')),
      );
    }
  }

  /// Handle moves from the chessboard - board has already made the move and gives us rich info
  void _handleMove(CompletedMove move) {
    if (!mounted) return;

    print('Repertoire: Received move ${move.uci} -> ${move.san}');
    print('Repertoire: Controller FEN before sync: ${_controller.fen}');

    // Board has already made the move and calculated the SAN
    // Just add it to the PGN editor
    _pgnEditorController.addMove(move.san);
    print('Repertoire: Added move to PGN: ${move.san}');

    // The PGN editor will call onPositionChanged to sync the controller
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

  void _showError(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
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