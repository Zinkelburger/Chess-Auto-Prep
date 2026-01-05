/// Unified Engine Pane - Combines Stockfish, Maia, Ease, Coherence, and Probability
library;

import 'package:flutter/material.dart';
import 'package:chess/chess.dart' as chess;

import '../models/engine_settings.dart';
import '../services/stockfish_analysis_service.dart';
import '../services/ease_service.dart';
import '../services/maia_factory.dart';
import '../services/probability_service.dart';

class UnifiedEnginePane extends StatefulWidget {
  final String fen;
  final bool isActive;
  final bool? isUserTurn;
  final Function(String uciMove)? onMoveSelected;
  final List<String> currentMoveSequence;
  final bool isWhiteRepertoire;
  final VoidCallback? onEaseDetailsTap;

  const UnifiedEnginePane({
    super.key,
    required this.fen,
    this.isActive = true,
    this.isUserTurn,
    this.onMoveSelected,
    this.currentMoveSequence = const [],
    this.isWhiteRepertoire = true,
    this.onEaseDetailsTap,
  });

  @override
  State<UnifiedEnginePane> createState() => _UnifiedEnginePaneState();
}

class _UnifiedEnginePaneState extends State<UnifiedEnginePane> {
  final EngineSettings _settings = EngineSettings();
  final StockfishAnalysisService _stockfishService = StockfishAnalysisService();
  final EaseService _easeService = EaseService();
  final ProbabilityService _probabilityService = ProbabilityService();

  Map<String, double>? _maiaProbs;
  bool _isLoadingMaia = false;
  bool _initialAnalysisStarted = false;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onSettingsChanged);
    
    // Listen for Stockfish to be ready before starting analysis
    _stockfishService.isReady.addListener(_onStockfishReady);
    
    // Delay initial analysis to allow services to initialize
    if (widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startInitialAnalysis();
      });
    }
  }
  
  void _onStockfishReady() {
    if (_stockfishService.isReady.value && widget.isActive && !_initialAnalysisStarted) {
      _startInitialAnalysis();
    }
  }
  
  void _startInitialAnalysis() {
    if (!mounted || _initialAnalysisStarted) return;
    _initialAnalysisStarted = true;
    
    // Stagger the analysis to avoid conflicts
    // Start Stockfish first (if ready), then others
    if (_settings.showStockfish && _stockfishService.isReady.value) {
      _stockfishService.startAnalysis(widget.fen);
    }
    
    // Delay Ease analysis slightly since it also uses Stockfish internally
    if (_settings.showEase) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          _easeService.calculateEase(widget.fen);
        }
      });
    }

    if (_settings.showMaia) {
      _runMaiaAnalysis();
    }

    if (_settings.showProbability) {
      _calculateCumulativeProbability();
    }
  }

  @override
  void didUpdateWidget(UnifiedEnginePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && (widget.fen != oldWidget.fen || !oldWidget.isActive)) {
      _runAnalysis();
    }
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _stockfishService.isReady.removeListener(_onStockfishReady);
    super.dispose();
  }

  void _onSettingsChanged() {
    setState(() {});
    if (widget.isActive) {
      _stockfishService.updateSettings();
      _runAnalysis();
    }
  }

  void _runAnalysis() {
    // Run all enabled analyses - stagger to avoid conflicts
    if (_settings.showStockfish && _stockfishService.isReady.value) {
      _stockfishService.startAnalysis(widget.fen);
    }

    // Delay Ease analysis slightly since it also uses Stockfish internally
    if (_settings.showEase) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          _easeService.calculateEase(widget.fen);
        }
      });
    }

    if (_settings.showMaia) {
      _runMaiaAnalysis();
    }

    if (_settings.showProbability) {
      _calculateCumulativeProbability();
    }
  }

  Future<void> _runMaiaAnalysis() async {
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) return;

    setState(() {
      _isLoadingMaia = true;
    });

    try {
      final probs = await MaiaFactory.instance!.evaluate(widget.fen, _settings.maiaElo);
      if (mounted) {
        setState(() {
          _maiaProbs = probs;
          _isLoadingMaia = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingMaia = false;
        });
      }
    }
  }

  Future<void> _calculateCumulativeProbability() async {
    // Fetch probabilities for current position (for display in the move list)
    await _probabilityService.fetchProbabilities(widget.fen);
    
    // Calculate cumulative probability along the move sequence
    if (widget.currentMoveSequence.isEmpty) {
      // Reset to 100% at starting position
      _probabilityService.cumulativeProbability.value = 100.0;
      return;
    }

    // Use the probability service to calculate cumulative probability
    // This traverses all moves from the start, querying the database for each opponent move
    await _probabilityService.calculateCumulativeProbability(
      widget.currentMoveSequence,
      isUserWhite: widget.isWhiteRepertoire,
      startingMoves: _settings.probabilityStartMoves,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive) {
      return const Center(child: Text('Analysis paused'));
    }

    return Column(
      children: [
        // Settings bar
        _buildSettingsBar(),
        const Divider(height: 1),

        // Analysis sections
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(8),
            children: [
              if (_settings.showStockfish) _buildStockfishSection(),
              if (_settings.showMaia) _buildMaiaSection(),
              if (_settings.showEase) _buildEaseSection(),
              if (_settings.showCoherence) _buildCoherenceSection(),
              if (_settings.showProbability) _buildProbabilitySection(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          // Status
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: _stockfishService.status,
              builder: (context, status, _) {
                return Text(
                  status,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[400],
                  ),
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
          ),

          // Settings button
          IconButton(
            icon: const Icon(Icons.settings, size: 18),
            tooltip: 'Engine Settings',
            onPressed: _showSettingsDialog,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  Widget _buildStockfishSection() {
    return _AnalysisSection(
      title: 'Stockfish',
      icon: Icons.memory,
      iconColor: Colors.blue,
      onSettingsTap: () => _showStockfishSettings(),
      child: ValueListenableBuilder<bool>(
        valueListenable: _stockfishService.isReady,
        builder: (context, isReady, _) {
          if (!isReady) {
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Initializing engine...',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                ],
              ),
            );
          }
          
          return ValueListenableBuilder<AnalysisResult>(
            valueListenable: _stockfishService.analysis,
            builder: (context, analysis, _) {
              if (analysis.lines.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                );
              }

              return Column(
                children: analysis.lines.map((line) => _buildAnalysisLine(line)).toList(),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildAnalysisLine(AnalysisLine line) {
    final evalColor = line.effectiveCp > 50
        ? Colors.green
        : (line.effectiveCp < -50 ? Colors.red : Colors.grey);

    return InkWell(
      onTap: () {
        if (line.pv.isNotEmpty) {
          widget.onMoveSelected?.call(line.pv.first);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Eval
            Container(
              width: 56,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: evalColor.withAlpha(30),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                line.scoreString,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: evalColor,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 8),

            // PV line
            Expanded(
              child: Text(
                _formatPv(line.pv),
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[300],
                  fontFamily: 'monospace',
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatPv(List<String> pv) {
    if (pv.isEmpty) return '...';

    // Convert UCI to SAN for better readability
    final game = chess.Chess.fromFEN(widget.fen);
    final sanMoves = <String>[];

    for (final uci in pv.take(6)) {
      if (uci.length < 4) continue;
      final from = uci.substring(0, 2);
      final to = uci.substring(2, 4);
      String? promotion;
      if (uci.length > 4) promotion = uci.substring(4);

      final moveMap = <String, String>{'from': from, 'to': to};
      if (promotion != null) moveMap['promotion'] = promotion;

      // Find the SAN representation of the move
      final legalMoves = game.moves({'verbose': true});
      final matchingMove = legalMoves.firstWhere(
        (m) => m['from'] == from && m['to'] == to && 
               (promotion == null || m['promotion'] == promotion),
        orElse: () => <String, dynamic>{},
      );

      if (matchingMove.isNotEmpty && game.move(moveMap)) {
        sanMoves.add(matchingMove['san'] as String);
      } else {
        sanMoves.add(uci);
      }
    }

    return sanMoves.join(' ');
  }

  Widget _buildMaiaSection() {
    return _AnalysisSection(
      title: 'Maia ${_settings.maiaElo}',
      icon: Icons.psychology,
      iconColor: Colors.purple,
      child: _buildMaiaContent(),
    );
  }

  Widget _buildMaiaContent() {
    if (!MaiaFactory.isAvailable) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'Maia not available on this platform',
          style: TextStyle(color: Colors.grey[500], fontSize: 12),
        ),
      );
    }

    if (_isLoadingMaia || _maiaProbs == null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              _isLoadingMaia ? 'Analyzing with Maia...' : 'Initializing Maia...',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
          ],
        ),
      );
    }

    final topMoves = _maiaProbs!.entries.take(5).toList();

    return Column(
      children: topMoves.map((entry) {
        final prob = entry.value * 100;
        return InkWell(
          onTap: () => widget.onMoveSelected?.call(entry.key),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 50,
                  child: Text(
                    entry.key,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                ),
                Expanded(
                  child: LinearProgressIndicator(
                    value: prob / 100,
                    backgroundColor: Colors.grey[800],
                    valueColor: AlwaysStoppedAnimation(Colors.purple[300]),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 45,
                  child: Text(
                    '${prob.toStringAsFixed(1)}%',
                    style: TextStyle(
                      color: Colors.purple[300],
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildEaseSection() {
    return _AnalysisSection(
      title: 'Ease',
      icon: Icons.speed,
      iconColor: Colors.orange,
      onTap: widget.onEaseDetailsTap,
      child: ValueListenableBuilder<EaseResult?>(
        valueListenable: _easeService.currentResult,
        builder: (context, result, _) {
          if (result == null) {
            return ValueListenableBuilder<String>(
              valueListenable: _easeService.status,
              builder: (context, status, _) {
                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          status,
                          style: TextStyle(color: Colors.grey[500], fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          }

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Text(
                  result.ease.toStringAsFixed(2),
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: _getEaseColor(result.ease),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _getEaseDescription(result.ease),
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.isUserTurn == true
                            ? 'Your turn • Lower ease = harder for opponent'
                            : "Opponent's turn • Higher ease = easier for you",
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: Colors.grey[600],
                  size: 20,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _getEaseDescription(double ease) {
    if (ease >= 0.8) return 'Very easy position';
    if (ease >= 0.6) return 'Relatively easy';
    if (ease >= 0.4) return 'Moderate difficulty';
    if (ease >= 0.2) return 'Tricky position';
    return 'Very difficult';
  }

  Color _getEaseColor(double ease) {
    if (ease >= 0.8) return Colors.green[400]!;
    if (ease >= 0.6) return Colors.lightGreen[400]!;
    if (ease >= 0.4) return Colors.orange[400]!;
    if (ease >= 0.2) return Colors.deepOrange[400]!;
    return Colors.red[400]!;
  }

  Widget _buildCoherenceSection() {
    return _AnalysisSection(
      title: 'Coherence',
      icon: Icons.link,
      iconColor: Colors.teal,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Text(
              '—',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                'Coherence analysis coming soon',
                style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProbabilitySection() {
    return _AnalysisSection(
      title: 'Probability',
      icon: Icons.percent,
      iconColor: Colors.cyan,
      onSettingsTap: () => _showProbabilitySettings(),
      child: ValueListenableBuilder<bool>(
        valueListenable: _probabilityService.isLoading,
        builder: (context, isLoading, _) {
          return ValueListenableBuilder<double>(
            valueListenable: _probabilityService.cumulativeProbability,
            builder: (context, cumulative, _) {
              return ValueListenableBuilder<PositionProbabilities?>(
                valueListenable: _probabilityService.currentPosition,
                builder: (context, positionData, _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Cumulative probability header
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            if (isLoading)
                              const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            else
                              Text(
                                '${cumulative.toStringAsFixed(1)}%',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: _getProbabilityColor(cumulative),
                                ),
                              ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Cumulative probability',
                                    style: TextStyle(
                                      color: Colors.grey[400],
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _getProbabilitySubtitle(),
                                    style: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Line breakdown - how we got to this probability
                      if (widget.currentMoveSequence.isNotEmpty) ...[
                        const Divider(height: 1),
                        ValueListenableBuilder<List<MoveInLineProbability>>(
                          valueListenable: _probabilityService.lineBreakdown,
                          builder: (context, breakdown, _) {
                            if (breakdown.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            // Only show opponent moves that affected probability
                            final opponentMoves = breakdown.where((m) => m.isOpponentMove).toList();
                            if (opponentMoves.isEmpty) {
                              return Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(
                                  'No opponent moves yet',
                                  style: TextStyle(color: Colors.grey[500], fontSize: 11),
                                ),
                              );
                            }
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                  child: Text(
                                    'Opponent move probabilities',
                                    style: TextStyle(
                                      color: Colors.grey[500],
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                ...opponentMoves.map((move) => Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 24,
                                        child: Text(
                                          '${(move.moveNumber + 1) ~/ 2}.',
                                          style: TextStyle(
                                            color: Colors.grey[600],
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 50,
                                        child: Text(
                                          move.san,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: LinearProgressIndicator(
                                          value: move.probability > 0 ? move.probability / 100 : 0,
                                          backgroundColor: Colors.grey[800],
                                          valueColor: AlwaysStoppedAnimation(
                                            move.probability < 0 
                                                ? Colors.grey[600] 
                                                : Colors.cyan[300],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      SizedBox(
                                        width: 45,
                                        child: Text(
                                          move.probability < 0 
                                              ? '?' 
                                              : '${move.probability.toStringAsFixed(1)}%',
                                          style: TextStyle(
                                            color: move.probability < 0 
                                                ? Colors.grey[500] 
                                                : Colors.cyan[300],
                                            fontSize: 11,
                                          ),
                                          textAlign: TextAlign.right,
                                        ),
                                      ),
                                    ],
                                  ),
                                )),
                              ],
                            );
                          },
                        ),
                      ],

                      // Current position move probabilities
                      if (positionData != null && positionData.moves.isNotEmpty) ...[
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          child: Text(
                            'Next moves (${positionData.totalGames} games)',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        ...positionData.moves.take(5).map((move) => _buildMoveProbabilityRow(move)),
                      ],
                      
                      if (positionData == null && !isLoading && widget.currentMoveSequence.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            'No database data available',
                            style: TextStyle(color: Colors.grey[500], fontSize: 12),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildMoveProbabilityRow(MoveProbability move) {
    return InkWell(
      onTap: () {
        // Convert SAN to UCI and play the move
        final game = chess.Chess.fromFEN(widget.fen);
        final legalMoves = game.moves({'verbose': true});
        final matchingMove = legalMoves.firstWhere(
          (m) => m['san'] == move.san,
          orElse: () => <String, dynamic>{},
        );
        if (matchingMove.isNotEmpty) {
          final uci = '${matchingMove['from']}${matchingMove['to']}${matchingMove['promotion'] ?? ''}';
          widget.onMoveSelected?.call(uci);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 50,
              child: Text(
                move.san,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
              ),
            ),
            Expanded(
              child: LinearProgressIndicator(
                value: move.probability / 100,
                backgroundColor: Colors.grey[800],
                valueColor: AlwaysStoppedAnimation(Colors.cyan[300]),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 45,
              child: Text(
                '${move.probability.toStringAsFixed(1)}%',
                style: TextStyle(
                  color: Colors.cyan[300],
                  fontSize: 12,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getProbabilitySubtitle() {
    final startMoves = _settings.probabilityStartMoves;
    final hasStartMoves = startMoves.isNotEmpty;
    
    if (widget.currentMoveSequence.isEmpty) {
      return hasStartMoves 
          ? 'From: $startMoves'
          : 'Starting position';
    }
    
    final colorInfo = 'Playing as ${widget.isWhiteRepertoire ? "White" : "Black"}';
    final moveCount = '${widget.currentMoveSequence.length} moves';
    
    if (hasStartMoves) {
      return '$colorInfo • From: $startMoves';
    }
    return '$colorInfo • $moveCount';
  }

  Color _getProbabilityColor(double prob) {
    if (prob >= 50) return Colors.cyan[400]!;
    if (prob >= 20) return Colors.cyan[300]!;
    if (prob >= 5) return Colors.yellow[400]!;
    if (prob >= 1) return Colors.orange[400]!;
    return Colors.red[400]!;
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Engine Settings'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildToggleTile('Stockfish', _settings.showStockfish, (v) => _settings.showStockfish = v),
              _buildToggleTile('Maia', _settings.showMaia, (v) => _settings.showMaia = v),
              _buildToggleTile('Ease', _settings.showEase, (v) => _settings.showEase = v),
              _buildToggleTile('Coherence', _settings.showCoherence, (v) => _settings.showCoherence = v),
              _buildToggleTile('Probability', _settings.showProbability, (v) => _settings.showProbability = v),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleTile(String label, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      title: Text(label),
      value: value,
      onChanged: onChanged,
      contentPadding: EdgeInsets.zero,
    );
  }

  void _showStockfishSettings() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Stockfish Settings'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildNumberField(
                    label: 'Threads (Cores)',
                    value: _settings.cores,
                    min: 1,
                    max: 32,
                    onChanged: (v) {
                      _settings.cores = v;
                      setDialogState(() {});
                    },
                  ),
                  const SizedBox(height: 16),
                  _buildNumberField(
                    label: 'Hash (MB)',
                    value: _settings.hashMb,
                    min: 16,
                    max: 16384,
                    step: 64,
                    onChanged: (v) {
                      _settings.hashMb = v;
                      setDialogState(() {});
                    },
                  ),
                  const SizedBox(height: 16),
                  _buildNumberField(
                    label: 'Depth',
                    value: _settings.depth,
                    min: 1,
                    max: 99,
                    onChanged: (v) {
                      _settings.depth = v;
                      setDialogState(() {});
                    },
                  ),
                  const SizedBox(height: 16),
                  _buildNumberField(
                    label: 'Candidate Moves (MultiPV)',
                    value: _settings.multiPv,
                    min: 1,
                    max: 10,
                    onChanged: (v) {
                      _settings.multiPv = v;
                      setDialogState(() {});
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildNumberField({
    required String label,
    required int value,
    required int min,
    required int max,
    int step = 1,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(label),
        ),
        IconButton(
          icon: const Icon(Icons.remove),
          onPressed: value > min
              ? () => onChanged((value - step).clamp(min, max))
              : null,
        ),
        SizedBox(
          width: 60,
          child: Text(
            value.toString(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: value < max
              ? () => onChanged((value + step).clamp(min, max))
              : null,
        ),
      ],
    );
  }

  void _showProbabilitySettings() {
    final controller = TextEditingController(text: _settings.probabilityStartMoves);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Probability Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Starting Moves',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Calculate probability starting from these moves',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'e.g., 1. d4 d5 2. c4',
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            Text(
              'Leave empty to start from initial position',
              style: TextStyle(color: Colors.grey[600], fontSize: 11, fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () {
                controller.text = '';
              },
              child: const Text('Reset to initial position'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              _settings.probabilityStartMoves = controller.text;
              _calculateCumulativeProbability();
              Navigator.pop(context);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}

/// Reusable section wrapper for analysis panels
class _AnalysisSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color iconColor;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onSettingsTap;

  const _AnalysisSection({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.child,
    this.onTap,
    this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          InkWell(
            onTap: onTap,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: iconColor.withAlpha(20),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: iconColor),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: iconColor,
                    ),
                  ),
                  const Spacer(),
                  if (onSettingsTap != null)
                    InkWell(
                      onTap: onSettingsTap,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.tune,
                          size: 14,
                          color: iconColor.withAlpha(150),
                        ),
                      ),
                    ),
                  if (onTap != null)
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: iconColor.withAlpha(150),
                    ),
                ],
              ),
            ),
          ),

          // Content
          child,
        ],
      ),
    );
  }
}

