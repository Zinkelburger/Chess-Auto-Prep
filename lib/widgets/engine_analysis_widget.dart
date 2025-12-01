import 'package:flutter/material.dart';
import '../services/maia_service.dart';
import '../services/stockfish_service.dart';
import '../models/engine_evaluation.dart';

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
  final StockfishService _stockfish = StockfishService();
  final MaiaService _maia = MaiaService();
  
  int _maiaElo = 1500;
  Map<String, double>? _maiaProbs;
  bool _isMaiaLoading = false;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) {
      _stockfish.startAnalysis(widget.fen);
      _analyzeMaia();
    }
  }

  @override
  void didUpdateWidget(EngineAnalysisWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && (widget.fen != oldWidget.fen || !oldWidget.isActive)) {
      _stockfish.startAnalysis(widget.fen);
      _analyzeMaia();
    } else if (!widget.isActive && oldWidget.isActive) {
      _stockfish.stopAnalysis();
    }
  }

  Future<void> _analyzeMaia() async {
    if (!mounted) return;
    setState(() {
      _isMaiaLoading = true;
      _maiaProbs = null;
    });

    try {
      final probs = await _maia.evaluate(widget.fen, _maiaElo);
      if (mounted) {
        setState(() {
          _maiaProbs = probs;
          _isMaiaLoading = false;
        });
      }
    } catch (e) {
      print('Maia error: $e');
      if (mounted) {
        setState(() {
          _isMaiaLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _stockfish.stopAnalysis();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive) {
      return const Center(child: Text('Analysis paused'));
    }

    return ListView(
      children: [
        // Stockfish Section
        _buildStockfishSection(),
        const Divider(),
        // Maia Section
        _buildMaiaSection(),
      ],
    );
  }

  Widget _buildStockfishSection() {
    return ValueListenableBuilder<EngineEvaluation?>(
      valueListenable: _stockfish.evaluation,
      builder: (context, eval, child) {
        if (eval == null) {
          return const Padding(
            padding: EdgeInsets.all(16.0),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        return Card(
          margin: const EdgeInsets.all(8.0),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Stockfish 16', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('Depth: ${eval.depth}'),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Evaluation: ${eval.scoreString}',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: _getScoreColor(eval),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Best: ${eval.pv.join(' ')}',
                  style: const TextStyle(fontFamily: 'Monospace'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMaiaSection() {
    return Card(
      margin: const EdgeInsets.all(8.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Maia (Human Probabilities)', style: TextStyle(fontWeight: FontWeight.bold)),
                DropdownButton<int>(
                  value: _maiaElo,
                  isDense: true,
                  items: [1100, 1300, 1500, 1700, 1900].map((elo) {
                    return DropdownMenuItem(
                      value: elo,
                      child: Text('Elo $elo'),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _maiaElo = val);
                      _analyzeMaia();
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_isMaiaLoading)
              const Center(child: LinearProgressIndicator())
            else if (_maiaProbs == null || _maiaProbs!.isEmpty)
              const Text('No human moves found')
            else
              Column(
                children: _maiaProbs!.entries.take(5).map((entry) {
                  final prob = (entry.value * 100).toStringAsFixed(1);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 50,
                          child: Text(
                            entry.key,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Expanded(
                          child: Stack(
                            children: [
                              LinearProgressIndicator(
                                value: entry.value,
                                minHeight: 20,
                                backgroundColor: Colors.grey[200],
                                color: Colors.blue[300],
                              ),
                              Padding(
                                padding: const EdgeInsets.only(left: 8.0),
                                child: Text('$prob%', style: const TextStyle(fontSize: 12)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    );
  }

  Color _getScoreColor(EngineEvaluation eval) {
    if (eval.scoreMate != null) {
      return eval.scoreMate! > 0 ? Colors.green : Colors.red;
    }
    if (eval.scoreCp != null) {
      if (eval.scoreCp! > 50) return Colors.green;
      if (eval.scoreCp! < -50) return Colors.red;
    }
    return Colors.grey[700]!;
  }
}
