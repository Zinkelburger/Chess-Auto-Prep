import 'package:dartchess/dartchess.dart' show Position;

import 'eval.dart';

/// The engine the search scores positions with, always at one fixed depth.
///
/// Asynchronous because the real one is a UCI process, but the search itself
/// does no I/O: it asks, waits, and works with the value it is given.
abstract interface class PositionEvaluator {
  /// The fixed-depth score of [position] from the side to move's point of
  /// view. The same position must always come back with the same score
  /// within one search: the window that admits our moves and the value of a
  /// horizon leaf are both read from it.
  Future<EvaluationResult> evaluate(Position position);
}

/// A ranked engine shortlist at one of our deeper positions. Null means the
/// engine could not complete the requested fixed-depth ranking.
abstract interface class CandidateSource {
  Future<List<String>?> candidates(Position position, int count);
}

/// The engine's answer about [position], with a throw counted as one.
///
/// An adapter sits on a process, a socket or a decoder, and those fail in
/// ways it did not think of. An exception out of one of them means exactly
/// what [EvaluationUnavailable] means, and letting it escape the search
/// instead would take a whole build's tree with it, so the search asks
/// through here and never calls [PositionEvaluator.evaluate] directly.
Future<EvaluationResult> evaluationOf(
  PositionEvaluator evaluator,
  Position position,
) async {
  try {
    return await evaluator.evaluate(position);
  } catch (error) {
    return EvaluationUnavailable('$error');
  }
}

/// The model's answer about [position], on the same terms as [evaluationOf].
Future<PolicyResult> policyOf(OpponentPolicy policy, Position position) async {
  try {
    return await policy.policyFor(position);
  } catch (error) {
    return PolicyUnavailable('$error');
  }
}

/// What [PositionEvaluator.evaluate] answered. An engine that cannot score a
/// position is an expected outcome of a long build, not an exception.
sealed class EvaluationResult {
  const EvaluationResult();
}

final class Evaluated extends EvaluationResult {
  const Evaluated(this.eval, {this.depth, this.pv = const []});

  final Eval eval;

  /// Reported engine depth; absent when the source does not supply it.
  final int? depth;

  /// The engine's best line from the position, as UCI; empty when the
  /// source gives only a score (a cache, a database).
  final List<String> pv;
}

final class EvaluationUnavailable extends EvaluationResult {
  const EvaluationUnavailable(this.reason);

  /// Plain English for the log and the user: what the engine could not do.
  final String reason;
}

/// The opponent model: how likely the opponent is to play each reply.
///
/// Every position where the opponent is on move needs one. There is no
/// fallback to a game database, an average or a uniform guess; a position the
/// model cannot answer stops the search instead of being made up.
abstract interface class OpponentPolicy {
  Future<PolicyResult> policyFor(Position position);
}

sealed class PolicyResult {
  const PolicyResult();
}

final class PolicyFound extends PolicyResult {
  const PolicyFound(this.policy);

  final Policy policy;
}

final class PolicyUnavailable extends PolicyResult {
  const PolicyUnavailable(this.reason);

  final String reason;
}

/// Relative weights for the opponent's moves at one position, keyed by
/// standard UCI (`e7e5`, `e7e8q`, `e8g8` for castling).
///
/// Weights need not sum to anything in particular and moves the model did not
/// mention count as zero; [sharesOver] does the normalising, once, against
/// the moves that are actually legal.
final class Policy {
  const Policy(this.weights);

  final Map<String, double> weights;

  /// The share of the policy each move in [legal] holds, summing to one, with
  /// the moves the model gave no weight left out — every reply the opponent
  /// might really play stays in the search, and nothing else does.
  ///
  /// Example: weights `{e7e5: 0.6, c7c5: 0.3}` over the legal moves
  /// `[c7c5, e7e5, g8f6]` become `{c7c5: 1/3, e7e5: 2/3}`.
  ///
  /// Null when no legal move has positive weight. A policy about some other
  /// position, or one that is all zeroes, tells the search nothing, and
  /// guessing on the opponent's behalf is what this algorithm refuses to do.
  Map<String, double>? sharesOver(Iterable<String> legal) {
    final support = <String, double>{};
    for (final uci in legal) {
      final weight = weights[uci] ?? 0;
      if (weight.isFinite && weight > 0) support[uci] = weight;
    }
    final mass = support.values.fold(0.0, (sum, weight) => sum + weight);
    if (mass <= 0) return null;
    return {for (final entry in support.entries) entry.key: entry.value / mass};
  }
}

/// The likeliest of [shares], taken most likely first until they cover
/// [mass] of the opponent's move or number [most], whichever comes first,
/// and renormalised so the kept replies again sum to one. At least one reply
/// is always kept; null for both keeps every reply.
///
/// Example: `{e7e5: 0.5, c7c5: 0.42, e7e6: 0.05, d7d5: 0.03}` with mass 0.9
/// keeps e7e5 and c7c5 (0.92 covered) as `{e7e5: 0.543…, c7c5: 0.456…}`.
/// Equal shares are ordered by UCI so the cut does not depend on map order.
Map<String, double> likeliestReplies(
  Map<String, double> shares, {
  double? mass,
  int? most,
}) {
  if (mass == null && most == null) return shares;
  final ranked = shares.entries.toList()
    ..sort((a, b) {
      final order = b.value.compareTo(a.value);
      return order != 0 ? order : a.key.compareTo(b.key);
    });
  final kept = <String, double>{};
  var covered = 0.0;
  for (final entry in ranked) {
    if (kept.isNotEmpty &&
        ((most != null && kept.length >= most) ||
            (mass != null && covered >= mass - 1e-12))) {
      break;
    }
    kept[entry.key] = entry.value;
    covered += entry.value;
  }
  return {for (final entry in kept.entries) entry.key: entry.value / covered};
}
