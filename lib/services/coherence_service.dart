/// Repertoire coherence analysis via FP-Growth on our-move itemsets.
///
/// Measures how much lines share common move patterns, groups lines
/// into clusters by shared structural moves.
library;

import 'dart:isolate';
import 'dart:math' show pow;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../models/repertoire_line.dart';
import 'fp_growth.dart';

/// Serializable input for FP-Growth mining in a background isolate.
class FpGrowthInput {
  final List<Set<String>> transactions;
  final double minSupport;

  const FpGrowthInput({required this.transactions, required this.minSupport});
}

/// Top-level entry point for [Isolate.run] / background FP-Growth.
List<FrequentItemset> runFpGrowthMining(FpGrowthInput input) {
  final miner = FPGrowthMiner(
    minSupport: input.minSupport,
    transactions: input.transactions,
  );
  final allItemsets = miner.mine();
  return miner.maximalItemsets(allItemsets);
}

/// Browse-mode coherence hint for a candidate move.
class CoherenceCandidateHint {
  final double score;
  final String? clusterName;

  const CoherenceCandidateHint({required this.score, this.clusterName});
}

/// Returns a hint when [candidateSan] extends a frequent itemset or cluster.
CoherenceCandidateHint? coherenceHintForCandidateMove({
  required List<String> currentMoves,
  required String candidateSan,
  required bool playAsWhite,
  required CoherenceResult result,
}) {
  if (result.maximalItemsets.isEmpty) return null;

  final moves = [...currentMoves, candidateSan];
  final itemset = extractItemset(
    RepertoireLine(
      id: '_candidate',
      name: '_candidate',
      moves: moves,
      color: playAsWhite ? 'white' : 'black',
      startPosition: Chess.initial,
      fullPgn: '',
    ),
    playAsWhite,
  );

  final score = lineCoherence(itemset, result.maximalItemsets);

  String? clusterName;
  for (final cluster in result.clusters) {
    if (cluster.id == 'unclustered') continue;
    final sig = cluster.signature.items;
    if (sig.isNotEmpty && sig.every(itemset.contains)) {
      clusterName = cluster.autoName;
      break;
    }
  }

  final extendsItemset = result.maximalItemsets.any(
    (mfi) => mfi.items.every(itemset.contains),
  );
  if (!extendsItemset && clusterName == null && score < 0.35) {
    return null;
  }

  return CoherenceCandidateHint(score: score, clusterName: clusterName);
}

/// Extract the set of our moves from a line.
Set<String> extractItemset(RepertoireLine line, bool playAsWhite) {
  final items = <String>{};
  for (var i = 0; i < line.moves.length; i++) {
    final isOurMove = playAsWhite ? (i % 2 == 0) : (i % 2 == 1);
    if (isOurMove) {
      items.add(line.moves[i]);
    }
  }
  return items;
}

/// Compute how coherent a single line is with the repertoire's patterns.
double lineCoherence(
  Set<String> lineItemset,
  List<FrequentItemset> maximalItemsets,
) {
  if (maximalItemsets.isEmpty) return 0.0;
  double score = 0;
  for (final mfi in maximalItemsets) {
    if (mfi.items.every((item) => lineItemset.contains(item))) {
      score += mfi.support;
    }
  }
  final maxPossible = maximalItemsets
      .map((m) => m.support)
      .reduce((a, b) => a + b);
  return maxPossible > 0 ? (score / maxPossible).clamp(0.0, 1.0) : 0.0;
}

/// Risk-weighted coherence penalizes incoherent rare lines.
double computeRiskWeightedCoherence(
  Map<String, double> lineCoherences,
  Map<String, double> lineProbabilities, {
  double alpha = 0.5,
  double beta = 1.5,
}) {
  double numerator = 0;
  double denominator = 0;
  for (final id in lineCoherences.keys) {
    final p = lineProbabilities[id] ?? 0.01;
    final c = lineCoherences[id] ?? 0;
    final weight = pow(p, alpha).toDouble();
    numerator += weight * c;
    denominator += weight;
  }
  return denominator > 0 ? numerator / denominator : 0;
}

class CoherenceCluster {
  final String id;
  final FrequentItemset signature;
  final String autoName;
  final List<String> lineIds;
  final double probabilityMass;

  const CoherenceCluster({
    required this.id,
    required this.signature,
    required this.autoName,
    required this.lineIds,
    required this.probabilityMass,
  });
}

class CoherenceResult {
  final double globalCoherence;
  final double riskWeightedCoherence;
  final List<CoherenceCluster> clusters;
  final Map<String, double> lineCoherenceById;
  final List<FrequentItemset> maximalItemsets;
  final double topNCoverage;

  const CoherenceResult({
    required this.globalCoherence,
    required this.riskWeightedCoherence,
    required this.clusters,
    required this.lineCoherenceById,
    required this.maximalItemsets,
    required this.topNCoverage,
  });
}

class CoherenceService extends ChangeNotifier {
  CoherenceResult? _result;
  CoherenceResult? get result => _result;
  bool _computing = false;

  Future<void> compute({
    required List<RepertoireLine> lines,
    required bool playAsWhite,
    double minSupport = 0.05,
  }) async {
    if (_computing || lines.length < 5) return;
    _computing = true;

    final transactions = lines
        .map((l) => extractItemset(l, playAsWhite))
        .toList();

    final maximal = await Isolate.run(
      () => runFpGrowthMining(
        FpGrowthInput(transactions: transactions, minSupport: minSupport),
      ),
    );

    final lineScores = <String, double>{};
    for (var i = 0; i < lines.length; i++) {
      lineScores[lines[i].id] = lineCoherence(transactions[i], maximal);
    }

    final clusters = _buildClusters(lines, maximal, transactions, playAsWhite);

    final lineProbabilities = <String, double>{};
    for (final l in lines) {
      lineProbabilities[l.id] = l.importance ?? 0.01;
    }

    final global = _weightedAverage(lineScores, lineProbabilities);
    final riskWeighted = computeRiskWeightedCoherence(
      lineScores,
      lineProbabilities,
    );
    final topN = clusters.length >= 3
        ? clusters.take(3).map((c) => c.probabilityMass).reduce((a, b) => a + b)
        : clusters.isNotEmpty
        ? clusters.map((c) => c.probabilityMass).reduce((a, b) => a + b)
        : 0.0;

    _result = CoherenceResult(
      globalCoherence: global,
      riskWeightedCoherence: riskWeighted,
      clusters: clusters,
      lineCoherenceById: lineScores,
      maximalItemsets: maximal,
      topNCoverage: topN,
    );

    _computing = false;
    notifyListeners();
  }

  void invalidate() {
    _result = null;
    notifyListeners();
  }

  List<CoherenceCluster> _buildClusters(
    List<RepertoireLine> lines,
    List<FrequentItemset> maximal,
    List<Set<String>> transactions,
    bool playAsWhite,
  ) {
    final ranked = maximal.toList()
      ..sort(
        (a, b) =>
            (b.support * b.items.length).compareTo(a.support * a.items.length),
      );

    final assigned = <String>{};
    final clusters = <CoherenceCluster>[];
    int clusterId = 0;

    for (final mfi in ranked) {
      final members = <RepertoireLine>[];
      for (var i = 0; i < lines.length; i++) {
        if (assigned.contains(lines[i].id)) continue;
        if (mfi.items.every((item) => transactions[i].contains(item))) {
          members.add(lines[i]);
        }
      }
      if (members.isEmpty) continue;

      for (final m in members) {
        assigned.add(m.id);
      }

      clusters.add(
        CoherenceCluster(
          id: 'cluster_${clusterId++}',
          signature: mfi,
          autoName: _generateClusterName(mfi),
          lineIds: members.map((l) => l.id).toList(),
          probabilityMass: members
              .map((l) => l.importance ?? 0.01)
              .fold(0.0, (a, b) => a + b),
        ),
      );
    }

    final unclustered = lines.where((l) => !assigned.contains(l.id)).toList();
    if (unclustered.isNotEmpty) {
      clusters.add(
        CoherenceCluster(
          id: 'unclustered',
          signature: const FrequentItemset(items: {}, support: 0, count: 0),
          autoName: 'Unclustered',
          lineIds: unclustered.map((l) => l.id).toList(),
          probabilityMass: unclustered
              .map((l) => l.importance ?? 0.01)
              .fold(0.0, (a, b) => a + b),
        ),
      );
    }

    return clusters;
  }

  static double _weightedAverage(
    Map<String, double> scores,
    Map<String, double> weights,
  ) {
    double num = 0;
    double den = 0;
    for (final id in scores.keys) {
      final w = weights[id] ?? 0.01;
      num += w * scores[id]!;
      den += w;
    }
    return den > 0 ? num / den : 0;
  }

  static String _generateClusterName(FrequentItemset mfi) {
    final items = mfi.items.toList();
    final structural = items.where(_isStructural).toList();
    final development = items.where(_isDevelopment).toList();

    if (structural.contains('g3') && development.contains('Bg2')) {
      return 'Fianchetto setup';
    }
    if (structural.contains('d4') && structural.contains('c4')) {
      return 'd4 + c4 complex';
    }
    if (structural.contains('d4') && development.contains('Bf4')) {
      return 'London-style';
    }
    if (structural.contains('e4') && structural.contains('d4')) {
      return 'Open center';
    }

    final topMoves = items.toList()..sort();
    return '${topMoves.take(3).join(" + ")} setup';
  }

  static bool _isStructural(String san) {
    if (san.length < 2) return false;
    final first = san[0];
    return first == first.toLowerCase() && first != 'x';
  }

  static bool _isDevelopment(String san) {
    if (san.length < 2) return false;
    final first = san[0];
    return first == 'N' || first == 'B';
  }
}
