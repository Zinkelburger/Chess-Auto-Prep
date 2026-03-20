/// Compact footer for the unified engine pane showing overall difficulty and
/// cumulative probability.
library;

import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/engine_settings.dart';
import '../../services/analysis_service.dart';
import '../../services/probability_service.dart';
import '../../utils/chess_utils.dart' show formatCount, uciToSan;

class EnginePaneFooter extends StatelessWidget {
  final EngineSettings settings;
  final AnalysisService analysis;
  final ProbabilityService probabilityService;
  final String fen;
  final Map<String, double>? maiaProbs;
  final bool isWhiteRepertoire;
  final VoidCallback? onSetRoot;

  const EnginePaneFooter({
    super.key,
    required this.settings,
    required this.analysis,
    required this.probabilityService,
    required this.fen,
    required this.maiaProbs,
    this.isWhiteRepertoire = true,
    this.onSetRoot,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.grey[800]!, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          if (settings.showDifficulty) ...[
            ListenableBuilder(
              listenable: Listenable.merge([
                analysis.results,
                analysis.discoveryResult,
                analysis.poolStatus,
              ]),
              builder: (_, __) {
                final rawEase = _computeOverallEase();
                final difficulty = rawEase != null
                    ? (1.0 - rawEase) * kEaseDisplayScale
                    : null;
                final isAnalyzing = analysis.poolStatus.value.isEvaluating;
                if (difficulty == null) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Difficulty ',
                        style: TextStyle(
                            fontSize: 15, color: Colors.grey[500]),
                      ),
                      if (isAnalyzing)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child:
                              CircularProgressIndicator(strokeWidth: 1.5),
                        )
                      else
                        Text(
                          '--',
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey[500]),
                        ),
                    ],
                  );
                }

                final fenParts = fen.split(' ');
                final isWhiteToMove =
                    fenParts.length >= 2 && fenParts[1] == 'w';
                final side = isWhiteToMove ? "White's" : "Black's";

                String topMoveExtra = '';
                if (maiaProbs != null && maiaProbs!.isNotEmpty) {
                  final sorted = maiaProbs!.entries.toList()
                    ..sort((a, b) => b.value.compareTo(a.value));
                  final top = sorted.first;
                  final topSan = uciToSan(fen, top.key);
                  topMoveExtra = '\n$topSan, ${(top.value * 100).toStringAsFixed(0)}% chance';
                }

                return Tooltip(
                  message:
                      "$side ${difficulty < 0.01 ? 'move is not' : difficulty < 1.5 ? 'moves are not very' : difficulty < 3.0 ? 'moves are moderately' : 'moves are very'} "
                      "difficult (${difficulty.toStringAsFixed(1)}/5)"
                      "$topMoveExtra",
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Difficulty ',
                        style:
                            TextStyle(fontSize: 15, color: Colors.grey[500]),
                      ),
                      Text(
                        difficulty.toStringAsFixed(1),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.amber[300],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(width: 20),
          ],

          if (settings.showProbability) ...[
            ValueListenableBuilder<double>(
              valueListenable: probabilityService.cumulativeProbability,
              builder: (_, cumulative, __) {
                return Tooltip(
                  message: 'Cumulative probability along this line',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Cumulative DB ',
                        style:
                            TextStyle(fontSize: 15, color: Colors.grey[500]),
                      ),
                      Text(
                        '${cumulative.toStringAsFixed(1)}%',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.cyan[300],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            if (onSetRoot != null) ...[
              const SizedBox(width: 8),
              SizedBox(
                height: 26,
                child: TextButton.icon(
                  onPressed: onSetRoot,
                  icon: const Icon(Icons.my_location, size: 14),
                  label: const Text('Set as root',
                      style: TextStyle(fontSize: 11)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ],
          ],

          const Spacer(),

          if (settings.showProbability)
            ValueListenableBuilder<ExplorerResponse?>(
              valueListenable: probabilityService.currentPosition,
              builder: (_, posData, __) {
                if (posData == null || posData.totalGames == 0) {
                  return const SizedBox.shrink();
                }
                return Text(
                  '${formatCount(posData.totalGames)} games',
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                );
              },
            ),
        ],
      ),
    );
  }

  // ─── Overall Ease Computation ──────────────────────────────────────────

  double? _computeOverallEase() {
    if (maiaProbs == null) return null;

    final fenParts = fen.split(' ');
    final isWhiteTurn = fenParts.length >= 2 && fenParts[1] == 'w';

    final discoveryLines = analysis.discoveryResult.value.lines;
    if (discoveryLines.isEmpty) return null;

    final topCp = discoveryLines.first.effectiveCp;
    final rootCp = isWhiteTurn ? topCp : -topCp;
    final maxQ = scoreToQ(rootCp);

    final sorted = maiaProbs!.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final poolResults = analysis.results.value;
    double sumWeightedRegret = 0.0;
    double cumulativeProb = 0.0;
    int found = 0;
    int skippedNoEval = 0;

    for (final entry in sorted) {
      if (entry.value < 0.01) continue;

      int? whiteCp;

      for (final line in discoveryLines) {
        if (line.pv.isNotEmpty && line.pv.first == entry.key) {
          whiteCp = line.effectiveCp;
          break;
        }
      }
      if (whiteCp == null) {
        final pr = poolResults[entry.key];
        if (pr != null && pr.hasEval) {
          whiteCp = pr.effectiveCp;
        }
      }
      if (whiteCp == null) {
        skippedNoEval++;
        continue;
      }

      final moveCp = isWhiteTurn ? whiteCp : -whiteCp;
      final qVal = scoreToQ(moveCp);

      final regret = math.max(0.0, maxQ - qVal);
      sumWeightedRegret += math.pow(entry.value, kEaseBeta) * regret;

      found++;
      cumulativeProb += entry.value;
      if (cumulativeProb > 0.90) break;
    }

    if (found == 0) {
      if (kDebugMode && analysis.poolStatus.value.isComplete) {
        print('[Engine] Overall difficulty: null — '
            'found=0, skippedNoEval=$skippedNoEval, '
            'maiaProbs=${maiaProbs!.length}, '
            'discovery=${discoveryLines.length}, '
            'poolResults=${poolResults.length}');
      }
      return null;
    }

    final ease = 1.0 - math.pow(sumWeightedRegret / 2, kEaseAlpha);
    return ease;
  }
}
