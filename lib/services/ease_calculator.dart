/// Shared ease-of-position calculator.
///
/// Computes how much evaluation the likely responses at a position lose
/// relative to the best available move.  Higher ease means the opponent
/// is unlikely to blunder — every popular reply is close to optimal.
///
/// Used by both [MoveAnalysisPool] (per-move ease in the engine pane) and
/// [RepertoireGenerationService] (propagated MetaEase during generation).
library;

import 'dart:math' as math;

import '../models/explorer_response.dart';
import '../utils/chess_utils.dart' show playUciMove;
import '../utils/ease_utils.dart';
import 'engine/eval_worker.dart';
import 'maia_factory.dart';

class EaseCalculator {
  /// Minimum play fraction (0–1) for a candidate move.  Moves played in
  /// fewer than 1 % of games at this position are ignored.
  static const double kMinPlayFraction = 0.01;

  /// Stop collecting candidates once this cumulative probability mass
  /// (as a fraction, 0–1) is covered.
  static const double kMassCutoff = 0.90;

  /// Per-move game count below which DB data is considered unreliable
  /// and the calculator falls back to Maia probabilities.
  static const int kMinGamesReliable = 50;

  /// Compute the ease of position [fen].
  ///
  /// [evaluateBatch] evaluates a list of FENs at [evalDepth] and returns
  /// one [EvalResult] per FEN.  The caller decides whether evaluation is
  /// sequential (single worker) or parallel (across a pool).
  ///
  /// If [dbData] is provided it is used as the source of opponent move
  /// probabilities; otherwise, the method fetches nothing (callers should
  /// pre-fetch).  When DB data is missing or unreliable (< [kMinGamesReliable]
  /// games per move), Maia is used as a fallback.
  ///
  /// Returns `null` when no candidate data is available from either source.
  static Future<double?> compute({
    required String fen,
    required int evalDepth,
    required int maiaElo,
    required Future<List<EvalResult>> Function(List<String> fens, int depth)
        evaluateBatch,
    ExplorerResponse? dbData,
  }) async {
    final candidates = await _buildCandidates(fen, dbData, maiaElo);
    if (candidates == null) return null;

    final childFens = <String>[];
    final validCandidates = <MapEntry<String, double>>[];
    for (final entry in candidates) {
      final nextFen = playUciMove(fen, entry.key);
      if (nextFen == null) continue;
      childFens.add(nextFen);
      validCandidates.add(entry);
    }
    if (childFens.isEmpty) return null;

    final evalResults = await evaluateBatch(childFens, evalDepth);

    int bestForMover = -100000;
    final scores = <int>[];
    for (final eval in evalResults) {
      final forMover = -eval.effectiveCp;
      scores.add(forMover);
      bestForMover = math.max(bestForMover, forMover);
    }

    final maxQ = scoreToQ(bestForMover);
    double sumWeightedRegret = 0.0;
    for (int i = 0; i < validCandidates.length; i++) {
      final prob = validCandidates[i].value;
      final qVal = scoreToQ(scores[i]);
      final regret = math.max(0.0, maxQ - qVal);
      sumWeightedRegret += math.pow(prob, kEaseBeta) * regret;
    }

    return 1.0 - math.pow(sumWeightedRegret / 2, kEaseAlpha);
  }

  /// Collect candidate moves with their probabilities.
  ///
  /// Prefers DB data when every selected move has ≥ [kMinGamesReliable]
  /// games; otherwise falls back to Maia neural-network probabilities.
  static Future<List<MapEntry<String, double>>?> _buildCandidates(
    String fen,
    ExplorerResponse? dbData,
    int maiaElo,
  ) async {
    final candidates = <MapEntry<String, double>>[];

    if (dbData != null && dbData.moves.isNotEmpty) {
      double cumulative = 0.0;
      for (final move in dbData.moves) {
        if (move.uci.isEmpty) continue;
        final prob = move.playFraction;
        if (prob < kMinPlayFraction) continue;
        candidates.add(MapEntry(move.uci, prob));
        cumulative += prob;
        if (cumulative > kMassCutoff) break;
      }

      final reliable = candidates.isNotEmpty &&
          candidates.every((entry) {
            for (final move in dbData.moves) {
              if (move.uci == entry.key) return move.total > kMinGamesReliable;
            }
            return false;
          });
      if (!reliable) candidates.clear();
    }

    if (candidates.isEmpty) {
      if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
        return null;
      }
      final maiaProbs = await MaiaFactory.instance!.evaluate(fen, maiaElo);
      if (maiaProbs.isEmpty) return null;

      final sorted = maiaProbs.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      double cumulative = 0.0;
      for (final entry in sorted) {
        if (entry.value < kMinPlayFraction) continue;
        candidates.add(entry);
        cumulative += entry.value;
        if (cumulative > kMassCutoff) break;
      }
    }

    return candidates.isEmpty ? null : candidates;
  }
}
