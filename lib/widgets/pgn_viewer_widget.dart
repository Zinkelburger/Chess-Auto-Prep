import 'package:flutter/material.dart';
import 'package:dartchess/dartchess.dart';
import 'dart:io' as io;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/gestures.dart';

class PgnViewerWidget extends StatefulWidget {
  final String? gameId;
  final int? moveNumber;
  final bool? isWhiteToPlay;
  final Function(Position)? onPositionChanged;

  const PgnViewerWidget({
    super.key,
    this.gameId,
    this.moveNumber,
    this.isWhiteToPlay,
    this.onPositionChanged,
  });

  @override
  State<PgnViewerWidget> createState() => _PgnViewerWidgetState();
}

class _PgnViewerWidgetState extends State<PgnViewerWidget> {
  PgnGame? _game;
  List<PgnNodeData> _moveHistory = [];
  int _currentMoveIndex = 0;
  Position _currentPosition = Chess.initial;
  String _gameInfo = '';
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadGame();
  }

  @override
  void didUpdateWidget(PgnViewerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.gameId != oldWidget.gameId) {
      _loadGame();
    }
  }

  Future<void> _loadGame() async {
    if (widget.gameId == null) {
      setState(() {
        _error = 'No game ID provided';
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final pgnText = await _findGamePgn(widget.gameId!);
      if (pgnText.isEmpty) {
        setState(() {
          _error = 'Game not found in PGN files';
          _isLoading = false;
        });
        return;
      }

      final game = PgnGame.parsePgn(pgnText);
      final moveHistory = game.moves.mainline().toList();

      setState(() {
        _game = game;
        _moveHistory = moveHistory;
        _currentMoveIndex = 0;
        _currentPosition = Chess.initial;
        _gameInfo = _buildGameInfo(game);
        _isLoading = false;
      });

      // Jump to the tactic move if specified
      if (widget.moveNumber != null && widget.isWhiteToPlay != null) {
        _jumpToMove(widget.moveNumber!, widget.isWhiteToPlay!);
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
      final directory = await getApplicationDocumentsDirectory();
      final pgnFile = io.File('${directory.path}/imported_games.pgn');

      if (!await pgnFile.exists()) {
        return '';
      }

      final content = await pgnFile.readAsString();
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

    // Calculate ply number
    int targetPly = (moveNumber - 1) * 2;
    if (!isWhiteToPlay) targetPly += 1;

    // Clamp to valid range
    targetPly = targetPly.clamp(0, _moveHistory.length);

    _goToMove(targetPly);
  }

  void _goToMove(int moveIndex) {
    if (moveIndex < 0 || moveIndex > _moveHistory.length) return;

    // Rebuild position up to the target move
    Position position = Chess.initial;
    for (int i = 0; i < moveIndex; i++) {
      final move = position.parseSan(_moveHistory[i].san);
      if (move != null) {
        position = position.play(move);
      } else {
        break;
      }
    }

    setState(() {
      _currentMoveIndex = moveIndex;
      _currentPosition = position;
    });

    widget.onPositionChanged?.call(position);
  }

  void _goToStart() {
    _goToMove(0);
  }

  void _goBack() {
    if (_currentMoveIndex > 0) {
      _goToMove(_currentMoveIndex - 1);
    }
  }

  void _goForward() {
    if (_currentMoveIndex < _moveHistory.length) {
      _goToMove(_currentMoveIndex + 1);
    }
  }

  void _onMoveClicked(int moveIndex) {
    _goToMove(moveIndex + 1); // +1 because we want position AFTER the move
  }

  String _filterComment(String comment) {
    // Filter out evaluation and clock comments like the Python version
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
        // Game info
        Container(
          padding: const EdgeInsets.all(8),
          child: Text(
            _gameInfo,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),

        // PGN moves
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: _buildPgnDisplay(),
          ),
        ),

        // Navigation buttons
        Container(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                onPressed: _currentMoveIndex > 0 ? _goToStart : null,
                icon: const Icon(Icons.skip_previous),
                tooltip: 'Start',
              ),
              IconButton(
                onPressed: _currentMoveIndex > 0 ? _goBack : null,
                icon: const Icon(Icons.chevron_left),
                tooltip: 'Back',
              ),
              IconButton(
                onPressed: _currentMoveIndex < _moveHistory.length ? _goForward : null,
                icon: const Icon(Icons.chevron_right),
                tooltip: 'Forward',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPgnDisplay() {
    if (_moveHistory.isEmpty) return const SizedBox();

    final moves = <InlineSpan>[];
    var moveNumber = 1;
    var isWhiteTurn = true;

    for (int i = 0; i < _moveHistory.length; i++) {
      final moveData = _moveHistory[i];
      final san = moveData.san;

      // Add move number for white's moves
      if (isWhiteTurn) {
        moves.add(TextSpan(
          text: '$moveNumber. ',
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
        ));
      }

      // Add the move as a clickable span
      final isCurrentMove = i == _currentMoveIndex - 1; // -1 because currentMoveIndex is position after move
      moves.add(
        TextSpan(
          text: san,
          style: TextStyle(
            color: isCurrentMove ? Colors.black : Colors.blue,
            fontWeight: isCurrentMove ? FontWeight.bold : FontWeight.normal,
            backgroundColor: isCurrentMove ? Colors.yellow : null,
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () => _onMoveClicked(i),
        ),
      );

      moves.add(const TextSpan(text: ' '));

      // Add comments if they exist and are meaningful
      if (moveData.comments != null && moveData.comments!.isNotEmpty) {
        final comment = _filterComment(moveData.comments!.first);
        if (comment.isNotEmpty) {
          moves.add(TextSpan(
            text: '($comment) ',
            style: const TextStyle(color: Colors.green, fontStyle: FontStyle.italic),
          ));
        }
      }

      // Update for next iteration
      if (!isWhiteTurn) {
        moveNumber++;
      }
      isWhiteTurn = !isWhiteTurn;
    }

    return RichText(
      text: TextSpan(
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 14,
          color: Colors.black,
        ),
        children: moves,
      ),
    );
  }
}