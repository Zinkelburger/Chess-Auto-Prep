import 'package:flutter/material.dart';
import '../services/ease_service.dart';

class EngineAnalysisWidget extends StatefulWidget {
  final String fen;
  final bool isActive;
  final bool? isUserTurn; // True if it's the user's turn to move
  final Function(String uciMove)? onMoveSelected;

  const EngineAnalysisWidget({
    super.key,
    required this.fen,
    this.isActive = true,
    this.isUserTurn,
    this.onMoveSelected,
  });

  @override
  State<EngineAnalysisWidget> createState() => _EngineAnalysisWidgetState();
}

class _EngineAnalysisWidgetState extends State<EngineAnalysisWidget> {
  final EaseService _easeService = EaseService();

  @override
  void initState() {
    super.initState();
    if (widget.isActive) {
      _easeService.calculateEase(widget.fen);
    }
  }

  @override
  void didUpdateWidget(EngineAnalysisWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && (widget.fen != oldWidget.fen || !oldWidget.isActive)) {
      _easeService.calculateEase(widget.fen);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive) {
      return const Center(child: Text('Analysis paused'));
    }

    return Column(
      children: [
        // Status Bar
        ValueListenableBuilder<String>(
          valueListenable: _easeService.status,
          builder: (context, status, _) {
            return Container(
              padding: const EdgeInsets.all(8),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              width: double.infinity,
              child: Text(
                status,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            );
          },
        ),
        
        // Main Content
        Expanded(
          child: ValueListenableBuilder<EaseResult?>(
            valueListenable: _easeService.currentResult,
            builder: (context, result, _) {
              if (result == null) {
                return const Center(child: CircularProgressIndicator());
              }

              // Sort moves based on turn perspective
              final moves = List<EaseMove>.from(result.moves);
              final isUserTurn = widget.isUserTurn ?? true; // Default to user turn if unknown
              
              moves.sort((a, b) {
                if (a.moveEase == null || b.moveEase == null) return 0;
                
                // If User's turn: We want HIGH Ease for the resulting position (easy for opponent? NO)
                // Wait: If User plays move X -> resulting position is Opponent's turn.
                // The "Ease" calculated is "Ease for side to move".
                // So "moveEase" is "Ease for Opponent".
                // User wants to make life DIFFICULT for opponent.
                // So user wants LOW Ease for opponent.
                // -> Sort by Ease Ascending (Low to High)
                
                // If Opponent's turn: Opponent plays move X -> resulting position is User's turn.
                // "moveEase" is "Ease for User".
                // User wants HIGH Ease for themselves.
                // -> Sort by Ease Descending (High to Low)
                
                if (isUserTurn) {
                  // User's turn -> Give opponent trouble -> Low Ease first
                  return a.moveEase!.compareTo(b.moveEase!);
                } else {
                  // Opponent's turn -> Hope for easy position -> High Ease first
                  return b.moveEase!.compareTo(a.moveEase!);
                }
              });

              return ListView(
                padding: const EdgeInsets.all(8),
                children: [
                  // Ease Score Card
                  Card(
                    // Removed background color for cleaner look
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Tooltip(
                            message: "Ease Score: How easy it is to find good moves in this position.\nHigh Ease = Intuitive good moves.\nLow Ease = Tricky position, easy to blunder.",
                            child: Text('Current Position Ease:', 
                              style: TextStyle(
                                fontWeight: FontWeight.w500, 
                                fontSize: 14,
                              )
                            ),
                          ),
                          Text(
                            result.ease.toStringAsFixed(2),
                            style: TextStyle(
                              fontSize: 20, 
                              fontWeight: FontWeight.bold,
                              // Keep text color for quick readability
                              color: _getEaseColor(result.ease),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),
                  Text(
                    'Move Analysis (${isUserTurn ? "Your Turn - Seek Low Ease" : "Opponent's Turn - Seek High Ease"})', 
                    style: const TextStyle(fontWeight: FontWeight.bold)
                  ),
                  const Divider(),

                  // Moves Table
                  ...moves.map((move) => _buildMoveItem(move)),
                  
                  if (result.moves.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('No candidate moves found.', style: TextStyle(color: Colors.grey)),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMoveItem(EaseMove move) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => widget.onMoveSelected?.call(move.uci),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          title: Row(
            children: [
            SizedBox(
              width: 60, 
              child: Text(move.uci, style: const TextStyle(fontWeight: FontWeight.bold))
            ),
            Tooltip(
              message: "Maia: Probability of a human playing this move",
              child: Text('${(move.prob * 100).toStringAsFixed(1)}%',
                style: TextStyle(color: Colors.blue[300], fontSize: 12)
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Tooltip(
                  message: "Stockfish Evaluation (Centipawns)",
                  child: Text('Eval: ${move.score > 0 ? "+" : ""}${move.score / 100}',
                    style: TextStyle(
                      color: move.score > 50 ? Colors.green : (move.score < -50 ? Colors.red : Colors.grey),
                      fontSize: 12
                    )
                  ),
                ),
                Tooltip(
                  message: "Regret: Max Eval - this move's eval",
                  child: Text('Regret: ${move.regret.toStringAsFixed(3)}',
                     style: const TextStyle(color: Colors.orange, fontSize: 12)
                  ),
                ),
                if (move.moveEase != null)
                  Tooltip(
                    message: "Ease of the resulting position\n(Higher = Easier for side to move)",
                    child: Text('Ease: ${move.moveEase!.toStringAsFixed(2)}',
                       style: const TextStyle(color: Colors.blue, fontSize: 12)
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  }

  Color _getEaseColor(double ease) {
    if (ease >= 0.8) return Colors.green[700]!;
    if (ease >= 0.6) return Colors.lightGreen[700]!;
    if (ease >= 0.4) return Colors.orange[800]!;
    return Colors.red[800]!;
  }
}
