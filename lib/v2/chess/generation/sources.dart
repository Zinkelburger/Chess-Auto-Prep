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
  const Evaluated(this.eval);

  final Eval eval;
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
