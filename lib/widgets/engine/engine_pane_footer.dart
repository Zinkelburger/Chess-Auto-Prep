/// Compact footer for the unified engine pane showing overall ease and
/// cumulative probability.
library;

import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/engine_settings.dart';
import '../../services/move_analysis_pool.dart';
import '../../services/probability_service.dart';
import '../../utils/chess_utils.dart' show formatCount;

class EnginePaneFooter extends StatelessWidget {
  final EngineSettings settings;
  final MoveAnalysisPool pool;
  final ProbabilityService probabilityService;
  final String fen;
  final Map<String, double>? maiaProbs;
  final bool isWhiteRepertoire;

  const EnginePaneFooter({
    super.key,
    required this.settings,
    required this.pool,
    required this.probabilityService,
    required this.fen,
    required this.maiaProbs,
    this.isWhiteRepertoire = true,
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
          if (settings.showEase) ...[
            ListenableBuilder(
              listenable: Listenable.merge([
                pool.results,
                pool.discoveryResult,
                pool.poolStatus,
              ]),
              builder: (_, __) {
                final rawEase = _computeOverallEase();
                // Normalise to the player's perspective.
                // Raw ease = navigability for the side to move.
                // Player's turn → show as-is.  Opponent's turn → invert.
                final fenParts = fen.split(' ');
                final isWhiteToMove =
                    fenParts.length >= 2 && fenParts[1] == 'w';
                final isPlayerTurn =
                    (isWhiteToMove == isWhiteRepertoire);
                final ease = rawEase != null
                    ? (isPlayerTurn ? rawEase : 1.0 - rawEase)
                        * kEaseDisplayScale
                    : null;
                final isAnalyzing = pool.poolStatus.value.isEvaluating;
                if (ease == null) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Ease ',
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

                return Tooltip(
                  message:
                      'Ease from your perspective (0–5 scale)\n'
                      'Higher = better for you\n'
                      'Raw: ${rawEase?.toStringAsFixed(3) ?? '--'}',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Ease ',
                        style:
                            TextStyle(fontSize: 15, color: Colors.grey[500]),
                      ),
                      Text(
                        ease.toStringAsFixed(1),
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

    final discoveryLines = pool.discoveryResult.value.lines;
    if (discoveryLines.isEmpty) return null;

    final topCp = discoveryLines.first.effectiveCp;
    final rootCp = isWhiteTurn ? topCp : -topCp;
    final maxQ = scoreToQ(rootCp);

    final sorted = maiaProbs!.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final poolResults = pool.results.value;
    double sumWeightedRegret = 0.0;
    double cumulativeProb = 0.0;
    int found = 0;
    int skippedNoEval = 0;

    for (final entry in sorted) {
      if (entry.value < 0.01) continue;

      int? whiteCp;

      // Check discovery lines first
      for (final line in discoveryLines) {
        if (line.pv.isNotEmpty && line.pv.first == entry.key) {
          whiteCp = line.effectiveCp;
          break;
        }
      }
      // Check pool results
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
      if (kDebugMode && pool.poolStatus.value.isComplete) {
        print('[Engine] Overall ease: null — '
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
