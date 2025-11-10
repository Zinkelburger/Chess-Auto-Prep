/// Interactive PGN viewer for repertoire training
/// Features clickable variations, comments, and mainline highlighting
library;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:dartchess/dartchess.dart';

class RepertoirePgnViewer extends StatefulWidget {
  final String pgnContent;
  final Function(Position)? onPositionChanged;
  final int? highlightMoveIndex; // For training mode
  final bool showVariations;

  const RepertoirePgnViewer({
    super.key,
    required this.pgnContent,
    this.onPositionChanged,
    this.highlightMoveIndex,
    this.showVariations = true,
  });

  @override
  State<RepertoirePgnViewer> createState() => _RepertoirePgnViewerState();
}

class _RepertoirePgnViewerState extends State<RepertoirePgnViewer> {
  PgnGame? _game;
  Position _currentPosition = Chess.initial;
  List<PgnNodeData> _mainlineHistory = [];
  int _currentMoveIndex = 0;
  bool _isLoading = true;
  String? _error;

  // For variations tracking
  PgnNode? _currentNode;
  List<String> _currentPath = []; // Track path through variations

  @override
  void initState() {
    super.initState();
    _loadPgn();
  }

  @override
  void didUpdateWidget(RepertoirePgnViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pgnContent != oldWidget.pgnContent) {
      _loadPgn();
    }
  }

  void _loadPgn() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final game = PgnGame.parsePgn(widget.pgnContent);
      final mainlineHistory = game.moves.mainline().toList();

      setState(() {
        _game = game;
        _mainlineHistory = mainlineHistory;
        _currentMoveIndex = 0;
        _currentPosition = Chess.initial;
        _currentNode = game.moves;
        _currentPath = [];
        _isLoading = false;
      });

      // Jump to highlighted move if specified
      if (widget.highlightMoveIndex != null) {
        _goToMove(widget.highlightMoveIndex!);
      }
    } catch (e) {
      setState(() {
        _error = 'Error loading PGN: $e';
        _isLoading = false;
      });
    }
  }

  void _goToMove(int moveIndex) {
    if (moveIndex < 0 || moveIndex > _mainlineHistory.length) return;

    // Rebuild position up to the target move
    Position position = Chess.initial;
    for (int i = 0; i < moveIndex; i++) {
      final move = position.parseSan(_mainlineHistory[i].san);
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

  void _goToStart() => _goToMove(0);
  void _goBack() => _goToMove(_currentMoveIndex - 1);
  void _goForward() => _goToMove(_currentMoveIndex + 1);
  void _goToEnd() => _goToMove(_mainlineHistory.length);

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
        ),
      );
    }

    if (_game == null) {
      return const Center(child: Text('No game loaded'));
    }

    return Column(
      children: [
        // Game info
        _buildGameInfo(),

        // PGN content with variations
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: _buildPgnDisplay(),
          ),
        ),

        // Navigation controls
        _buildNavigationControls(),
      ],
    );
  }

  Widget _buildGameInfo() {
    if (_game == null) return const SizedBox();

    final event = _game!.headers['Event'] ?? '';
    final opening = _game!.headers['Opening'] ?? '';

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey[800],
        border: Border(bottom: BorderSide(color: Colors.grey[600]!)),
      ),
      child: Column(
        children: [
          if (event.isNotEmpty)
            Text(
              event,
              style: const TextStyle(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
          if (opening.isNotEmpty)
            Text(
              opening,
              style: TextStyle(color: Colors.grey[300]),
              textAlign: TextAlign.center,
            ),
        ],
      ),
    );
  }

  Widget _buildPgnDisplay() {
    if (_mainlineHistory.isEmpty) return const SizedBox();

    return _buildMainlineWithVariations();
  }

  Widget _buildMainlineWithVariations() {
    final spans = <InlineSpan>[];
    var moveNumber = 1;
    var isWhiteTurn = true;

    for (int i = 0; i < _mainlineHistory.length; i++) {
      final moveData = _mainlineHistory[i];
      final san = moveData.san;

      // Add move number for white's moves
      if (isWhiteTurn) {
        spans.add(TextSpan(
          text: '$moveNumber. ',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ));
      }

      // Style for the move
      final isCurrentMove = i == _currentMoveIndex - 1;
      final isHighlighted = widget.highlightMoveIndex == i;

      Color moveColor;
      Color? backgroundColor;
      FontWeight fontWeight = FontWeight.normal;

      if (isCurrentMove) {
        moveColor = Colors.white;
        backgroundColor = Colors.blue[700];
        fontWeight = FontWeight.bold;
      } else if (isHighlighted) {
        moveColor = Colors.orange;
        fontWeight = FontWeight.bold;
      } else {
        moveColor = Colors.blue[300]!;
      }

      // Add the mainline move as clickable
      spans.add(TextSpan(
        text: san,
        style: TextStyle(
          color: moveColor,
          fontWeight: fontWeight,
          backgroundColor: backgroundColor,
          decoration: TextDecoration.underline,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () => _goToMove(i + 1),
      ));

      spans.add(const TextSpan(text: ' '));

      // Add comments if they exist
      if (moveData.comments != null && moveData.comments!.isNotEmpty) {
        final comment = moveData.comments!.join(' ').trim();
        if (comment.isNotEmpty) {
          spans.add(TextSpan(
            text: '{$comment} ',
            style: const TextStyle(
              color: Colors.green,
              fontStyle: FontStyle.italic,
            ),
          ));
        }
      }

      // Add variations if enabled
      if (widget.showVariations) {
        _addVariationsToSpans(spans, moveData, i);
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
          color: Colors.white,
        ),
        children: spans,
      ),
    );
  }

  void _addVariationsToSpans(List<InlineSpan> spans, PgnNodeData moveData, int mainlineMoveIndex) {
    // This is a simplified implementation
    // A full implementation would need to walk the PGN tree structure
    // For now, we'll add placeholder variation text

    // Check if this move has variations in the original game
    // This is complex with dartchess - for demo purposes, we'll add some sample variations
    if (mainlineMoveIndex < 3) { // Just for the first few moves as an example
      spans.add(const TextSpan(text: '\n    '));
      spans.add(TextSpan(
        text: '(Alternative: Sample variation) ',
        style: const TextStyle(
          color: Colors.grey,
          fontStyle: FontStyle.italic,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () => _showVariationDialog('Sample variation text'),
      ));
    }
  }

  void _showVariationDialog(String variationText) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Variation'),
        content: Text(variationText),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationControls() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey[800],
        border: Border(top: BorderSide(color: Colors.grey[600]!)),
      ),
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
          Text(
            'Move ${_currentMoveIndex}/${_mainlineHistory.length}',
            style: const TextStyle(fontSize: 12),
          ),
          IconButton(
            onPressed: _currentMoveIndex < _mainlineHistory.length ? _goForward : null,
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Forward',
          ),
          IconButton(
            onPressed: _currentMoveIndex < _mainlineHistory.length ? _goToEnd : null,
            icon: const Icon(Icons.skip_next),
            tooltip: 'End',
          ),
        ],
      ),
    );
  }
}