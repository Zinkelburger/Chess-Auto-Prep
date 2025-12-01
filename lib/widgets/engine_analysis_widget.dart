import 'package:flutter/material.dart';
import '../services/ease_service.dart';

class EngineAnalysisWidget extends StatefulWidget {
  final String fen;
  final bool isActive;

  const EngineAnalysisWidget({
    super.key,
    required this.fen,
    this.isActive = true,
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

              return ListView(
                padding: const EdgeInsets.all(8),
                children: [
                  // Ease Score Card
                  Card(
                    color: _getEaseColor(result.ease),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          const Text('EASE SCORE', 
                            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)
                          ),
                          Text(
                            result.ease.toStringAsFixed(2),
                            style: const TextStyle(
                              fontSize: 32, 
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Raw: ${result.rawEase.toStringAsFixed(2)} • Safety: ${(result.safetyFactor * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),
                  const Text('Move Analysis', style: TextStyle(fontWeight: FontWeight.bold)),
                  const Divider(),

                  // Moves Table
                  ...result.moves.map((move) => _buildMoveItem(move)),
                  
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
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        title: Row(
          children: [
            SizedBox(
              width: 60, 
              child: Text(move.uci, style: const TextStyle(fontWeight: FontWeight.bold))
            ),
            Text('${(move.prob * 100).toStringAsFixed(1)}%',
              style: TextStyle(color: Colors.blue[300], fontSize: 12)
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
                Text('Eval: ${move.score > 0 ? "+" : ""}${move.score / 100}',
                  style: TextStyle(
                    color: move.score > 50 ? Colors.green : (move.score < -50 ? Colors.red : Colors.grey),
                    fontSize: 12
                  )
                ),
                Text('Regret: ${move.regret.toStringAsFixed(3)}',
                   style: const TextStyle(color: Colors.orange, fontSize: 12)
                ),
              ],
            ),
          ],
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
