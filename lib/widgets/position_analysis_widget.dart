import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_chess_board/flutter_chess_board.dart';

import '../core/app_state.dart';

class PositionAnalysisWidget extends StatefulWidget {
  const PositionAnalysisWidget({super.key});

  @override
  State<PositionAnalysisWidget> createState() => _PositionAnalysisWidgetState();
}

class _PositionAnalysisWidgetState extends State<PositionAnalysisWidget> {
  late ChessBoardController _boardController;

  @override
  void initState() {
    super.initState();
    _boardController = ChessBoardController();
  }

  @override
  void dispose() {
    _boardController.dispose();
    super.dispose();
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
                Text('Analyzing weak positions...'),
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
                Icon(Icons.analytics, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text(
                  'No positions to analyze',
                  style: TextStyle(fontSize: 18, color: Colors.grey),
                ),
                SizedBox(height: 8),
                Text(
                  'Use the analytics button to analyze weak positions',
                  style: TextStyle(color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        }

        return Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    'Position Analysis',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    position.description,
                    style: Theme.of(context).textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                  if (position.gameSource != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'From: ${position.gameSource}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                ],
              ),
            ),

            Expanded(
              child: Row(
                children: [
                  // Chess board
                  Expanded(
                    flex: 2,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 1.0,
                        child: ChessBoard(
                          controller: _boardController,
                          enableUserMoves: false,
                          boardColor: BoardColor.brown,
                        ),
                      ),
                    ),
                  ),

                  // Analysis panel
                  Expanded(
                    flex: 1,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Analysis',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 16),

                          // Best move
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Best Move',
                                    style: Theme.of(context).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    position.bestMove,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(height: 16),

                          // Evaluation
                          if (position.evaluation != null)
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Evaluation',
                                      style: Theme.of(context).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      position.evaluation! > 0
                                          ? '+${position.evaluation!.toStringAsFixed(2)}'
                                          : position.evaluation!.toStringAsFixed(2),
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: position.evaluation! > 0
                                            ? Colors.green
                                            : Colors.red,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                          const SizedBox(height: 16),

                          // Alternative moves
                          if (position.alternativeMoves.isNotEmpty)
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Alternative Moves',
                                      style: Theme.of(context).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 8),
                                    ...position.alternativeMoves.map(
                                      (move) => Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 2),
                                        child: Text(move),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                          const Spacer(),

                          // Navigation
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              IconButton(
                                onPressed: appState.tacticsPositions.length > 1
                                    ? () {
                                        appState.previousTacticsPosition();
                                        _updatePosition();
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
                                        _updatePosition();
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
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  void _updatePosition() {
    final position = context.read<AppState>().currentPosition;
    if (position != null) {
      _boardController.loadFen(position.fen);
    }
  }
}