import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:chess/chess.dart' hide State;

import '../core/app_state.dart';
import '../models/tactics_position.dart';
import 'chess_board_widget.dart';

class TacticsWidget extends StatefulWidget {
  const TacticsWidget({super.key});

  @override
  State<TacticsWidget> createState() => _TacticsWidgetState();
}

class _TacticsWidgetState extends State<TacticsWidget> {
  Chess? _chess;
  bool _showSolution = false;
  String? _feedback;

  @override
  void initState() {
    super.initState();
    _initializePosition();
  }

  void _initializePosition() {
    final appState = context.read<AppState>();
    final position = appState.currentPosition;

    if (position != null) {
      print('=== TACTICS POSITION LOADED ===');
      print('FEN: ${position.fen}');
      print('Best move: "${position.bestMove}"');
      print('Correct line: ${position.correctLine}');
      print('User mistake: "${position.userMove}"');
      print('Mistake analysis: ${position.mistakeAnalysis}');
      print('Position context: ${position.positionContext}');
      print('===============================');

      _chess = Chess.fromFEN(position.fen);
      _showSolution = false;
      _feedback = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        if (appState.isLoading) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Loading tactics positions...'),
              ],
            ),
          );
        }

        final position = appState.currentPosition;
        if (position == null) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.psychology, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text(
                  'No tactics loaded',
                  style: TextStyle(fontSize: 18, color: Colors.grey),
                ),
                SizedBox(height: 8),
                Text(
                  'Tap the brain icon to load tactics',
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          );
        }

        return Column(
          children: [
            // Header with position info
            Container(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    position.description,
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  if (position.gameSource != null)
                    Text(
                      'From: ${position.gameSource}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  if (position.moveNumber != null && position.playerToMove != null)
                    Text(
                      'Move ${position.moveNumber}, ${position.playerToMove} to move',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),

            // Chess board
            Expanded(
              child: Center(
                child: _chess != null
                    ? ChessBoardWidget(
                        game: _chess!,
                        flipped: _chess!.turn == Color.BLACK, // Flip board when black to move
                        onMove: _onMove,
                      )
                    : const SizedBox(),
              ),
            ),

            // Feedback and controls
            Container(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (_feedback != null)
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: _feedback!.contains('Correct')
                            ? Colors.green.withValues(alpha: 0.1)
                            : Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _feedback!.contains('Correct')
                              ? Colors.green
                              : Colors.red,
                        ),
                      ),
                      child: Text(
                        _feedback!,
                        style: TextStyle(
                          color: _feedback!.contains('Correct')
                              ? Colors.green.shade700
                              : Colors.red.shade700,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),

                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _showHint,
                          child: const Text('Hint'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _showSolution ? null : _revealSolution,
                          child: const Text('Solution'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _resetPosition,
                          child: const Text('Reset'),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Navigation
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        onPressed: appState.tacticsPositions.length > 1
                            ? () {
                                appState.previousTacticsPosition();
                                _initializePosition();
                              }
                            : null,
                        icon: const Icon(Icons.skip_previous),
                        tooltip: 'Previous position',
                      ),
                      Text(
                        '${appState.tacticsPositions.indexOf(position) + 1} / ${appState.tacticsPositions.length}',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      IconButton(
                        onPressed: appState.tacticsPositions.length > 1
                            ? () {
                                appState.nextTacticsPosition();
                                _initializePosition();
                              }
                            : null,
                        icon: const Icon(Icons.skip_next),
                        tooltip: 'Next position',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  void _onMove(Move move) {
    if (_chess == null) return;

    final position = context.read<AppState>().currentPosition;
    if (position == null) return;

    // Make the move and check if it matches the best move
    final moveString = move.toString();
    final isCorrect = _checkMoveCorrectness(move, position.bestMove);

    if (isCorrect) {
      setState(() {
        _feedback = 'Correct! Well done!';
      });

      // Auto-advance after a delay
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          context.read<AppState>().nextTacticsPosition();
          _initializePosition();
        }
      });
    } else {
      setState(() {
        _feedback = 'Try again. That\'s not the best move.';
      });

      // Reset position after a delay
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) {
          _resetPosition();
        }
      });
    }
  }

  void _showHint() {
    final position = context.read<AppState>().currentPosition;
    if (position == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hint'),
        content: Text(_generateHint(position)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  bool _checkMoveCorrectness(Move move, String bestMove) {
    if (_chess == null) return false;

    print('=== TACTICS MOVE CHECKING ===');
    print('Expected best move: "$bestMove"');

    // SIMPLE CHECK: Just check if the target square matches like Python does
    final targetSquare = move.toAlgebraic;
    print('Player target square: "$targetSquare"');

    if (bestMove.length >= 2) {
      final expectedTarget = bestMove.substring(bestMove.length - 2);
      print('Expected target square: "$expectedTarget"');

      if (targetSquare.toLowerCase() == expectedTarget.toLowerCase()) {
        print('✓ MATCH: Target squares match');
        return true;
      }
    }

    print('✗ NO MATCH');
    print('===================');
    return false;
  }

  String _generateHint(TacticsPosition position) {
    final move = position.bestMove;

    if (move.contains('x')) {
      return 'Look for a capture!';
    } else if (move.contains('+')) {
      return 'Give check!';
    } else if (move.contains('#')) {
      return 'Find checkmate!';
    } else if (move.contains('=')) {
      return 'Promote your pawn!';
    } else {
      return 'Look for the most forcing move.';
    }
  }

  void _revealSolution() {
    final position = context.read<AppState>().currentPosition;
    if (position == null) return;

    setState(() {
      _showSolution = true;
      _feedback = 'Solution: ${position.bestMove}';
    });
  }

  void _resetPosition() {
    final position = context.read<AppState>().currentPosition;
    if (position == null) return;

    _chess = Chess.fromFEN(position.fen);
    setState(() {
      _feedback = null;
      _showSolution = false;
    });
  }
}