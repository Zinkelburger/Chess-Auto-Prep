import 'package:flutter/material.dart';
import 'package:dartchess_webok/dartchess_webok.dart';
import 'package:chess/chess.dart' as chess;
import 'package:flutter/gestures.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';

/// A node in the analysis tree. Each node represents a move.
/// Children[0] is the main continuation, children[1+] are variations.
class AnalysisNode {
  final String san;
  final String fenAfter;
  final List<AnalysisNode> children;
  final int id; // Unique ID for this node
  
  static int _nextId = 0;
  
  AnalysisNode({
    required this.san,
    required this.fenAfter,
  }) : children = [], id = _nextId++;
  
  /// Find a child with the given SAN, or null if not found
  AnalysisNode? findChild(String san) {
    for (final child in children) {
      if (child.san == san) return child;
    }
    return null;
  }
  
  /// Add a child node. If a node with the same SAN exists, return it instead.
  /// Returns the node (existing or new) and whether it's the main line (index 0).
  (AnalysisNode node, bool isMainLine) addChild(String san, String fenAfter) {
    // Check if this move already exists
    final existing = findChild(san);
    if (existing != null) {
      return (existing, children.indexOf(existing) == 0);
    }
    
    // Create new node
    final newNode = AnalysisNode(san: san, fenAfter: fenAfter);
    children.add(newNode);
    return (newNode, children.length == 1);
  }
}

class PgnViewerController {
  _PgnViewerWidgetState? _state;

  void _attach(_PgnViewerWidgetState state) {
    _state = state;
  }

  void _detach() {
    _state = null;
  }

  void goBack() {
    _state?._goBack();
  }

  void goForward() {
    _state?._goForward();
  }
  
  /// Add an ephemeral move (not saved to the original PGN)
  void addEphemeralMove(String san) {
    _state?._addAnalysisMove(san);
  }
  
  /// Get the FEN of the PGN viewer's current position.
  /// Returns null if the controller is not attached to a PGN viewer.
  String? get currentFen => _state?._currentPosition.fen;
  
  /// Clear all ephemeral moves and optionally re-sync to a game position.
  void clearEphemeralMoves() {
    _state?._clearAnalysis();
  }

  /// Jump the PGN viewer to a specific move number + color.
  void jumpToMove(int moveNumber, bool isWhiteToPlay) {
    final state = _state;
    if (state == null) return;
    state._clearAnalysis();
    state._jumpToMove(moveNumber, isWhiteToPlay);
  }
}

class PgnViewerWidget extends StatefulWidget {
  final String? gameId;
  final String? pgnText;
  final int? moveNumber;
  final bool? isWhiteToPlay;
  final Function(chess.Chess)? onPositionChanged;
  final PgnViewerController? controller;

  /// When set, the viewer will jump to the first position in the main line
  /// whose FEN matches [initialFen] (normalised to 4 fields) on load.
  final String? initialFen;

  /// Whether to show the "go to start" / "go to end" navigation buttons.
  /// Defaults to true. Set to false in contexts (like tactics) where jumping
  /// to the very start or end of the game is not useful.
  final bool showStartEndButtons;

  const PgnViewerWidget({
    super.key,
    this.gameId,
    this.pgnText,
    this.moveNumber,
    this.isWhiteToPlay,
    this.onPositionChanged,
    this.controller,
    this.initialFen,
    this.showStartEndButtons = true,
  });

  @override
  State<PgnViewerWidget> createState() => _PgnViewerWidgetState();
}

class _PgnViewerWidgetState extends State<PgnViewerWidget> 
    with AutomaticKeepAliveClientMixin {
  PgnGame? _game;
  List<PgnNodeData> _moveHistory = [];
  int _mainLineIndex = 0; // Current position in the original game's main line
  chess.Chess _currentPosition = chess.Chess();
  String _gameInfo = '';
  bool _isLoading = true;
  String? _error;
  
  // Analysis tree (sub-variations support)
  int _analysisBranchPoint = -1; // Where in main line the analysis branches (-1 = no analysis)
  List<AnalysisNode> _analysisRoots = []; // Root moves of analysis (alternatives at branch point)
  List<AnalysisNode> _analysisPath = []; // Current path through analysis tree
  
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _loadGame();
  }

  @override
  void dispose() {
    widget.controller?._detach();
    super.dispose();
  }

  @override
  void didUpdateWidget(PgnViewerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.gameId != oldWidget.gameId || widget.pgnText != oldWidget.pgnText) {
      _loadGame();
    } else if (widget.moveNumber != oldWidget.moveNumber ||
               widget.isWhiteToPlay != oldWidget.isWhiteToPlay) {
      // Same game but different tactic position — re-jump without reloading PGN.
      _clearAnalysis();
      if (widget.moveNumber != null && widget.isWhiteToPlay != null) {
        _jumpToMove(widget.moveNumber!, widget.isWhiteToPlay!);
      }
    }
  }

  Future<void> _loadGame() async {
    if (widget.pgnText == null && widget.gameId == null) {
      setState(() {
        _error = 'No game ID or PGN text provided';
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      String pgnText;

      if (widget.pgnText != null) {
        pgnText = widget.pgnText!;
      } else {
        pgnText = await _findGamePgn(widget.gameId!);
        if (pgnText.isEmpty) {
          setState(() {
            _error = 'Game not found in PGN files';
            _isLoading = false;
          });
          return;
        }
      }

      final game = PgnGame.parsePgn(pgnText);
      final moveHistory = game.moves.mainline().toList();

      setState(() {
        _game = game;
        _moveHistory = moveHistory;
        _mainLineIndex = 0;
        _currentPosition = chess.Chess();
        _gameInfo = _buildGameInfo(game);
        _isLoading = false;
        // Clear analysis when loading new game
        _clearAnalysis();
      });

      if (widget.moveNumber != null && widget.isWhiteToPlay != null) {
        _jumpToMove(widget.moveNumber!, widget.isWhiteToPlay!);
      } else if (widget.initialFen != null) {
        _jumpToFen(widget.initialFen!);
      }
    } catch (e) {
      setState(() {
        _error = 'Error loading PGN: $e';
        _isLoading = false;
      });
    }
  }

  Future<String> _findGamePgn(String gameId) async {
    try {
      final content = await StorageFactory.instance.readImportedPgns();
      if (content == null || content.isEmpty) {
        return '';
      }

      final games = _splitPgnIntoGames(content);

      for (final gameText in games) {
        if (gameText.contains('[GameId "$gameId"]')) {
          return gameText;
        }
      }
    } catch (e) {
      print('Error finding game PGN: $e');
    }

    return '';
  }

  List<String> _splitPgnIntoGames(String content) {
    final games = <String>[];
    final lines = content.split('\n');

    String currentGame = '';
    bool inGame = false;

    for (final line in lines) {
      if (line.startsWith('[Event')) {
        if (inGame && currentGame.isNotEmpty) {
          games.add(currentGame);
        }
        currentGame = '$line\n';
        inGame = true;
      } else if (inGame) {
        currentGame += '$line\n';
      }
    }

    if (inGame && currentGame.isNotEmpty) {
      games.add(currentGame);
    }

    return games;
  }

  String _buildGameInfo(PgnGame game) {
    final white = game.headers['White'] ?? '?';
    final black = game.headers['Black'] ?? '?';
    final event = game.headers['Event'] ?? '';
    final date = game.headers['Date'] ?? '';
    final result = game.headers['Result'] ?? '';

    return '$white vs $black\n$event • $date • $result';
  }

  void _jumpToMove(int moveNumber, bool isWhiteToPlay) {
    if (_moveHistory.isEmpty) return;

    int targetPly = (moveNumber - 1) * 2;
    if (!isWhiteToPlay) targetPly += 1;

    targetPly = targetPly.clamp(0, _moveHistory.length);

    _goToMainLineMove(targetPly);
  }

  /// Walk the main line and jump to the first position whose normalised FEN
  /// matches [targetFen].
  void _jumpToFen(String targetFen) {
    if (_moveHistory.isEmpty) return;

    final normalised = _normaliseFen(targetFen);
    final game = chess.Chess();

    for (int i = 0; i < _moveHistory.length; i++) {
      game.move(_moveHistory[i].san);
      if (_normaliseFen(game.fen) == normalised) {
        _goToMainLineMove(i + 1);
        return;
      }
    }
  }

  /// Strip half-move clock and full-move number for FEN comparison.
  static String _normaliseFen(String fen) {
    final parts = fen.split(' ');
    return parts.length >= 4 ? parts.take(4).join(' ') : fen;
  }

  /// Navigate to a position in the main line
  void _goToMainLineMove(int moveIndex) {
    if (moveIndex < 0 || moveIndex > _moveHistory.length) return;

    // Use chess.dart to handle position
    final newGame = chess.Chess();
    
    for (int i = 0; i < moveIndex; i++) {
      // Replay moves
      // We assume SANs are valid because they come from valid PGN parse
      newGame.move(_moveHistory[i].san);
    }

    setState(() {
      _mainLineIndex = moveIndex;
      _currentPosition = newGame;
      _analysisPath = []; // Exit analysis, but keep it visible
    });

    widget.onPositionChanged?.call(newGame);
  }

  /// Navigate to a specific node in the analysis tree
  void _goToAnalysisNode(AnalysisNode targetNode) {
    // Find path to this node
    final path = _findPathToNode(targetNode);
    if (path == null) return;
    
    // Rebuild position
    final newGame = chess.Chess();
    
    // First, go to branch point in main line
    for (int i = 0; i < _analysisBranchPoint; i++) {
      newGame.move(_moveHistory[i].san);
    }
    
    // Then apply analysis moves
    for (final node in path) {
      newGame.move(node.san);
    }
    
    setState(() {
      _mainLineIndex = _analysisBranchPoint;
      _currentPosition = newGame;
      _analysisPath = path;
    });
    
    widget.onPositionChanged?.call(newGame);
  }
  
  /// Find path from roots to a target node
  List<AnalysisNode>? _findPathToNode(AnalysisNode target) {
    for (final root in _analysisRoots) {
      final path = _findPathRecursive(root, target, []);
      if (path != null) return path;
    }
    return null;
  }
  
  List<AnalysisNode>? _findPathRecursive(AnalysisNode current, AnalysisNode target, List<AnalysisNode> pathSoFar) {
    final newPath = [...pathSoFar, current];
    if (current.id == target.id) return newPath;
    
    for (final child in current.children) {
      final result = _findPathRecursive(child, target, newPath);
      if (result != null) return result;
    }
    return null;
  }

  void _goToStart() {
    setState(() {
      _analysisRoots = [];
      _analysisBranchPoint = -1;
      _analysisPath = [];
    });
    _goToMainLineMove(0);
  }

  void _goBack() {
    if (_analysisPath.isNotEmpty) {
      // In analysis - go back within analysis
      if (_analysisPath.length > 1) {
        // Go to parent node
        final parentPath = _analysisPath.sublist(0, _analysisPath.length - 1);
        _goToAnalysisNode(parentPath.last);
      } else {
        // At root of analysis, go back to branch point in main line
        _goToMainLineMove(_analysisBranchPoint);
      }
    } else if (_mainLineIndex > 0) {
      // In main line
      _goToMainLineMove(_mainLineIndex - 1);
    }
  }

  void _goForward() {
    if (_analysisPath.isNotEmpty) {
      // In analysis - go to first child if exists
      final current = _analysisPath.last;
      if (current.children.isNotEmpty) {
        _goToAnalysisNode(current.children.first);
      }
    } else if (_analysisRoots.isNotEmpty && _mainLineIndex == _analysisBranchPoint) {
      // At branch point, enter analysis
      _goToAnalysisNode(_analysisRoots.first);
    } else if (_mainLineIndex < _moveHistory.length) {
      // In main line
      _goToMainLineMove(_mainLineIndex + 1);
    }
  }

  void _goToEnd() {
    if (_analysisRoots.isNotEmpty) {
      // Go to end of analysis main line
      AnalysisNode current = _analysisRoots.first;
      while (current.children.isNotEmpty) {
        current = current.children.first;
      }
      _goToAnalysisNode(current);
    } else {
      _goToMainLineMove(_moveHistory.length);
    }
  }

  void _onMainLineMoveClicked(int moveIndex) {
    _goToMainLineMove(moveIndex + 1);
  }
  
  bool get _canGoBack {
    return _analysisPath.isNotEmpty || _mainLineIndex > 0;
  }
  
  bool get _canGoForward {
    if (_analysisPath.isNotEmpty && _analysisPath.last.children.isNotEmpty) {
      return true;
    }
    if (_analysisPath.isEmpty && _analysisRoots.isNotEmpty && _mainLineIndex == _analysisBranchPoint) {
      return true;
    }
    if (_analysisPath.isEmpty && _mainLineIndex < _moveHistory.length) {
      return true;
    }
    return false;
  }
  
  /// Add a move to the analysis tree
  void _addAnalysisMove(String san) {
    // Validate move logic is handled by parent/engine, assume valid here
    // But we need to update state
    
    // Clone current game to check move validity and get FEN
    final tempGame = chess.Chess.fromFEN(_currentPosition.fen);
    final success = tempGame.move(san);
    if (!success) return;
    
    final fenAfter = tempGame.fen;
    
    setState(() {
      if (_analysisPath.isEmpty) {
        // Starting new analysis or adding to root level
        if (_analysisBranchPoint == -1 || _mainLineIndex != _analysisBranchPoint) {
          // New branch point
          _analysisBranchPoint = _mainLineIndex;
          _analysisRoots = [];
        }
        
        // Check if this move already exists at root
        AnalysisNode? existingRoot;
        for (final root in _analysisRoots) {
          if (root.san == san) {
            existingRoot = root;
            break;
          }
        }
        
        if (existingRoot != null) {
          _analysisPath = [existingRoot];
        } else {
          final newNode = AnalysisNode(san: san, fenAfter: fenAfter);
          _analysisRoots.add(newNode);
          _analysisPath = [newNode];
        }
      } else {
        // Adding to current analysis position
        final current = _analysisPath.last;
        final (node, _) = current.addChild(san, fenAfter);
        _analysisPath = [..._analysisPath, node];
      }
      
      _currentPosition = tempGame;
    });
    
    widget.onPositionChanged?.call(tempGame);
  }
  
  void _clearAnalysis() {
    setState(() {
      _analysisRoots = [];
      _analysisBranchPoint = -1;
      _analysisPath = [];
    });
  }

  String _filterComment(String comment) {
    comment = comment.replaceAll(RegExp(r'\[%eval [^\]]+\]'), '');
    comment = comment.replaceAll(RegExp(r'\[%clk [^\]]+\]'), '');
    comment = comment.replaceAll(RegExp(r'\([+-]?\d+\.?\d*\s*[→-]\s*[+-]?\d+\.?\d*\)'), '');
    comment = comment.replaceAll(RegExp(r'(Inaccuracy|Mistake|Blunder|Good move|Excellent move|Best move)\.[^.]*\.'), '');
    comment = comment.replaceAll(RegExp(r'[A-Za-z0-9+#-]+\s+was best\.?'), '');
    comment = comment.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (comment.isEmpty || comment == '.,;!?') {
      return '';
    }

    return comment;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading game...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _error!,
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (_game == null) {
      return const Center(
        child: Text('No game loaded'),
      );
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          child: Text(
            _gameInfo,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: _buildPgnDisplay(),
          ),
        ),

        Container(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (widget.showStartEndButtons)
                IconButton(
                  onPressed: _canGoBack ? _goToStart : null,
                  icon: const Icon(Icons.skip_previous),
                  tooltip: 'Start',
                ),
              IconButton(
                onPressed: _canGoBack ? _goBack : null,
                icon: const Icon(Icons.chevron_left),
                tooltip: 'Back',
              ),
              IconButton(
                onPressed: _canGoForward ? _goForward : null,
                icon: const Icon(Icons.chevron_right),
                tooltip: 'Forward',
              ),
              if (widget.showStartEndButtons)
                IconButton(
                  onPressed: _canGoForward ? _goToEnd : null,
                  icon: const Icon(Icons.skip_next),
                  tooltip: 'End',
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPgnDisplay() {
    if (_moveHistory.isEmpty && _analysisRoots.isEmpty) return const SizedBox();

    final spans = <InlineSpan>[];
    var moveNumber = 1;
    var isWhiteTurn = true;

    // Handle analysis branching from before the first move (start position)
    if (_analysisRoots.isNotEmpty && _analysisBranchPoint == 0) {
      spans.addAll(_buildAnalysisSpans());
    }

    for (int i = 0; i < _moveHistory.length; i++) {
      final moveData = _moveHistory[i];
      final san = moveData.san;

      if (isWhiteTurn) {
        spans.add(TextSpan(
          text: '$moveNumber. ',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[600]),
        ));
      }

      // Highlight current move
      final isCurrentMove = i == _mainLineIndex - 1 && _analysisPath.isEmpty;
      final isBranchPoint = i == _analysisBranchPoint - 1 && _analysisRoots.isNotEmpty;
      
      spans.add(
        TextSpan(
          text: san,
          style: TextStyle(
            color: isCurrentMove ? Colors.white : (isBranchPoint ? Colors.blue[200] : Colors.blue[300]),
            fontWeight: (isCurrentMove || isBranchPoint) ? FontWeight.bold : FontWeight.normal,
            backgroundColor: isCurrentMove ? Colors.blue[700] : null,
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () => _onMainLineMoveClicked(i),
        ),
      );

      spans.add(const TextSpan(text: ' '));

      if (moveData.comments != null && moveData.comments!.isNotEmpty) {
        final comment = _filterComment(moveData.comments!.first);
        if (comment.isNotEmpty) {
          spans.add(TextSpan(
            text: '{$comment} ',
            style: const TextStyle(color: Colors.green, fontStyle: FontStyle.italic),
          ));
        }
      }
      
      // Insert analysis variations inline after branch point
      if (_analysisRoots.isNotEmpty && i == _analysisBranchPoint - 1) {
        spans.addAll(_buildAnalysisSpans());
      }

      if (!isWhiteTurn) {
        moveNumber++;
      }
      isWhiteTurn = !isWhiteTurn;
    }
    
    // If branch point is at end of game
    if (_analysisRoots.isNotEmpty && _analysisBranchPoint >= _moveHistory.length) {
      spans.addAll(_buildAnalysisSpans());
    }

    return RichText(
      text: TextSpan(
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 14,
          color: Colors.grey[300],
        ),
        children: spans,
      ),
    );
  }
  
  /// Build spans for the entire analysis tree with proper nesting
  List<InlineSpan> _buildAnalysisSpans() {
    final spans = <InlineSpan>[];
    
    // Calculate starting move number
    var moveNumber = (_analysisBranchPoint ~/ 2) + 1;
    var isWhiteTurn = _analysisBranchPoint % 2 == 0;
    
    // Build all root variations
    for (int i = 0; i < _analysisRoots.length; i++) {
      final root = _analysisRoots[i];
      
      spans.add(TextSpan(
        text: '( ',
        style: TextStyle(color: Colors.orange[300], fontWeight: FontWeight.bold),
      ));
      
      // Build this variation tree
      spans.addAll(_buildNodeSpans(root, moveNumber, isWhiteTurn, true));
      
      spans.add(TextSpan(
        text: ') ',
        style: TextStyle(color: Colors.orange[300], fontWeight: FontWeight.bold),
      ));
    }
    
    return spans;
  }
  
  /// Recursively build spans for a node and its children
  List<InlineSpan> _buildNodeSpans(AnalysisNode node, int moveNumber, bool isWhiteTurn, bool isFirst) {
    final spans = <InlineSpan>[];
    
    // Move number
    if (isWhiteTurn) {
      spans.add(TextSpan(
        text: '$moveNumber. ',
        style: TextStyle(color: Colors.orange[200], fontWeight: FontWeight.bold),
      ));
    } else if (isFirst) {
      spans.add(TextSpan(
        text: '$moveNumber... ',
        style: TextStyle(color: Colors.orange[200], fontWeight: FontWeight.bold),
      ));
    }
    
    // The move itself
    final isCurrentNode = _analysisPath.isNotEmpty && _analysisPath.last.id == node.id;
    
    spans.add(
      TextSpan(
        text: node.san,
        style: TextStyle(
          color: isCurrentNode ? Colors.white : Colors.orange[300],
          fontWeight: isCurrentNode ? FontWeight.bold : FontWeight.normal,
          backgroundColor: isCurrentNode ? Colors.orange[700] : null,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () => _goToAnalysisNode(node),
      ),
    );
    
    spans.add(const TextSpan(text: ' '));
    
    // Update move number for next move
    final nextMoveNumber = isWhiteTurn ? moveNumber : moveNumber + 1;
    final nextIsWhite = !isWhiteTurn;
    
    // Children (variations)
    if (node.children.isNotEmpty) {
      // Main continuation first
      spans.addAll(_buildNodeSpans(node.children.first, nextMoveNumber, nextIsWhite, false));
      
      // Then variations in parentheses
      for (int i = 1; i < node.children.length; i++) {
        final variation = node.children[i];
        
        spans.add(TextSpan(
          text: '( ',
          style: TextStyle(color: Colors.amber[400], fontWeight: FontWeight.bold),
        ));
        
        spans.addAll(_buildNodeSpans(variation, nextMoveNumber, nextIsWhite, true));
        
        spans.add(TextSpan(
          text: ') ',
          style: TextStyle(color: Colors.amber[400], fontWeight: FontWeight.bold),
        ));
      }
    }
    
    return spans;
  }
}
