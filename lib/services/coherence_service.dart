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
import '../utils/safe_change_notifier.dart';
import 'fp_growth.dart';

/// Reach probability assumed for a line that carries no importance — an
/// imported course, say — so it still counts, just barely.
const double _defaultLineProbability = 0.01;

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

/// A candidate below this coherence that extends no itemset and completes no
/// cluster is not worth a hint.
const double _hintScoreFloor = 0.35;

/// Returns a hint when [candidateSan] extends a frequent itemset or cluster.
CoherenceCandidateHint? coherenceHintForCandidateMove({
  required List<String> currentMoves,
  required String candidateSan,
  required bool playAsWhite,
  required CoherenceResult result,
}) {
  if (result.maximalItemsets.isEmpty) return null;

  final itemset = extractItemset(
    RepertoireLine(
      id: '_candidate',
      name: '_candidate',
      moves: [...currentMoves, candidateSan],
      color: playAsWhite ? 'white' : 'black',
      startPosition: Chess.initial,
      fullPgn: '',
    ),
    playAsWhite,
  );

  final score = lineCoherence(itemset, result.maximalItemsets);

  String? clusterName;
  for (final cluster in result.clusters) {
    if (cluster.isUnclustered) continue;
    final signature = cluster.signature.items;
    if (signature.isNotEmpty && signature.every(itemset.contains)) {
      clusterName = cluster.autoName;
      break;
    }
  }

  final extendsItemset = result.maximalItemsets.any(
    (mfi) => mfi.items.every(itemset.contains),
  );
  if (!extendsItemset && clusterName == null && score < _hintScoreFloor) {
    return null;
  }

  return CoherenceCandidateHint(score: score, clusterName: clusterName);
}

/// Extract the set of our moves from a line.
Set<String> extractItemset(RepertoireLine line, bool playAsWhite) => {
  for (var i = playAsWhite ? 0 : 1; i < line.moves.length; i += 2)
    line.moves[i],
};

/// Compute how coherent a single line is with the repertoire's patterns:
/// the support of every maximal itemset the line contains, as a share of
/// all the support there is.
double lineCoherence(
  Set<String> lineItemset,
  List<FrequentItemset> maximalItemsets,
) {
  if (maximalItemsets.isEmpty) return 0.0;
  var score = 0.0;
  var maxPossible = 0.0;
  for (final mfi in maximalItemsets) {
    maxPossible += mfi.support;
    if (mfi.items.every(lineItemset.contains)) score += mfi.support;
  }
  return maxPossible > 0 ? (score / maxPossible).clamp(0.0, 1.0) : 0.0;
}

/// Risk-weighted coherence penalizes incoherent rare lines: each line's
/// coherence is weighted by its probability raised to [alpha], so a rare
/// line still counts more than its bare probability would give it.
double computeRiskWeightedCoherence(
  Map<String, double> lineCoherences,
  Map<String, double> lineProbabilities, {
  double alpha = 0.5,
}) => _weightedMean(lineCoherences, lineProbabilities, exponent: alpha);

/// Mean of [scores] weighted by `probability ^ exponent`; a line with no
/// probability weighs [_defaultLineProbability].
double _weightedMean(
  Map<String, double> scores,
  Map<String, double> probabilities, {
  required double exponent,
}) {
  var numerator = 0.0;
  var denominator = 0.0;
  for (final entry in scores.entries) {
    final probability = probabilities[entry.key] ?? _defaultLineProbability;
    final weight = pow(probability, exponent).toDouble();
    numerator += weight * entry.value;
    denominator += weight;
  }
  return denominator > 0 ? numerator / denominator : 0;
}

/// Lines grouped by the maximal itemset they all contain.
class CoherenceCluster {
  static const String unclusteredId = 'unclustered';

  final String id;
  final FrequentItemset signature;
  final String autoName;
  final List<String> lineIds;

  /// Total importance of the member lines.
  final double probabilityMass;

  const CoherenceCluster({
    required this.id,
    required this.signature,
    required this.autoName,
    required this.lineIds,
    required this.probabilityMass,
  });

  /// The catch-all cluster of lines that matched no itemset.
  bool get isUnclustered => id == unclusteredId;
}

/// One [CoherenceService.compute] outcome.
class CoherenceResult {
  final double globalCoherence;
  final double riskWeightedCoherence;
  final List<CoherenceCluster> clusters;
  final Map<String, double> lineCoherenceById;
  final List<FrequentItemset> maximalItemsets;

  /// Probability mass of the largest few clusters (see
  /// [CoherenceService.topClusterCount]).
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

/// Mines a repertoire's lines for shared move patterns and publishes the
/// latest [CoherenceResult].
class CoherenceService extends ChangeNotifier with SafeChangeNotifier {
  /// Fewer lines than this have no patterns worth mining.
  static const int minLines = 5;

  /// How many clusters [CoherenceResult.topNCoverage] sums.
  static const int topClusterCount = 3;

  /// Runs the FP-Growth mining; the default hands it to a background
  /// isolate. Injectable so tests can script a failure.
  final Future<List<FrequentItemset>> Function(FpGrowthInput input) _mine;

  CoherenceService({
    Future<List<FrequentItemset>> Function(FpGrowthInput input)? mine,
  }) : _mine = mine ?? _mineInIsolate;

  static Future<List<FrequentItemset>> _mineInIsolate(FpGrowthInput input) =>
      Isolate.run(() => runFpGrowthMining(input));

  CoherenceResult? _result;
  CoherenceResult? get result => _result;
  bool _computing = false;

  /// Mine [lines] and publish the result. A call that overlaps a running
  /// computation, or has fewer than [minLines] lines, does nothing.
  Future<void> compute({
    required List<RepertoireLine> lines,
    required bool playAsWhite,
    double minSupport = 0.05,
  }) async {
    if (_computing || lines.length < minLines) return;
    _computing = true;
    try {
      _result = await _compute(lines, playAsWhite, minSupport);
    } finally {
      _computing = false;
    }
    notifyListeners();
  }

  Future<CoherenceResult> _compute(
    List<RepertoireLine> lines,
    bool playAsWhite,
    double minSupport,
  ) async {
    final transactions = [
      for (final line in lines) extractItemset(line, playAsWhite),
    ];

    final maximal = await _mine(
      FpGrowthInput(transactions: transactions, minSupport: minSupport),
    );

    final lineScores = {
      for (var i = 0; i < lines.length; i++)
        lines[i].id: lineCoherence(transactions[i], maximal),
    };
    final lineProbabilities = {
      for (final line in lines) line.id: _probabilityOf(line),
    };
    final clusters = _buildClusters(lines, maximal, transactions);

    return CoherenceResult(
      globalCoherence: _weightedMean(
        lineScores,
        lineProbabilities,
        exponent: 1,
      ),
      riskWeightedCoherence: computeRiskWeightedCoherence(
        lineScores,
        lineProbabilities,
      ),
      clusters: clusters,
      lineCoherenceById: lineScores,
      maximalItemsets: maximal,
      topNCoverage: clusters
          .take(topClusterCount)
          .fold(0.0, (sum, cluster) => sum + cluster.probabilityMass),
    );
  }

  void invalidate() {
    _result = null;
    notifyListeners();
  }

  /// Assign each line to the first cluster (largest support × size first)
  /// whose signature it contains; the rest go to the unclustered group.
  static List<CoherenceCluster> _buildClusters(
    List<RepertoireLine> lines,
    List<FrequentItemset> maximal,
    List<Set<String>> transactions,
  ) {
    final ranked = maximal.toList()
      ..sort(
        (a, b) =>
            (b.support * b.items.length).compareTo(a.support * a.items.length),
      );

    final assigned = <String>{};
    final clusters = <CoherenceCluster>[];

    for (final mfi in ranked) {
      final members = [
        for (var i = 0; i < lines.length; i++)
          if (!assigned.contains(lines[i].id) &&
              mfi.items.every(transactions[i].contains))
            lines[i],
      ];
      if (members.isEmpty) continue;

      assigned.addAll(members.map((line) => line.id));
      clusters.add(
        CoherenceCluster(
          id: 'cluster_${clusters.length}',
          signature: mfi,
          autoName: _generateClusterName(mfi),
          lineIds: [for (final line in members) line.id],
          probabilityMass: _probabilityMass(members),
        ),
      );
    }

    final unclustered = [
      for (final line in lines)
        if (!assigned.contains(line.id)) line,
    ];
    if (unclustered.isNotEmpty) {
      clusters.add(
        CoherenceCluster(
          id: CoherenceCluster.unclusteredId,
          signature: const FrequentItemset(items: {}, support: 0, count: 0),
          autoName: 'Unclustered',
          lineIds: [for (final line in unclustered) line.id],
          probabilityMass: _probabilityMass(unclustered),
        ),
      );
    }

    return clusters;
  }

  static double _probabilityOf(RepertoireLine line) =>
      line.importance ?? _defaultLineProbability;

  static double _probabilityMass(List<RepertoireLine> lines) =>
      lines.fold(0.0, (sum, line) => sum + _probabilityOf(line));

  static String _generateClusterName(FrequentItemset mfi) {
    final items = mfi.items.toList();
    final structural = items.where(_isPawnMove).toList();
    final development = items.where(_isMinorPieceMove).toList();

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

  /// A pawn move: SAN starting with a file letter (captures like `exd5`
  /// included, since the first character is still the file).
  static bool _isPawnMove(String san) {
    if (san.length < 2) return false;
    final first = san[0];
    return first == first.toLowerCase() && first != 'x';
  }

  static bool _isMinorPieceMove(String san) =>
      san.length >= 2 && (san[0] == 'N' || san[0] == 'B');
}
