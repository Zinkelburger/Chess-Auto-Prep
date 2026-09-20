import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:chess_auto_prep/v2/chess/generation/sources.dart';
import 'package:dartchess/dartchess.dart';

Position positionOf(String fen) => Chess.fromSetup(Setup.parseFen(fen));

/// The position [uci] reaches from [from], for writing a scripted answer
/// about it.
Position afterUci(Position from, String uci) =>
    from.play(from.normalizeMove(NormalMove.fromUci(uci)));

/// An engine that reads its verdicts off a table keyed by FEN and says
/// [fallback] about everything else.
///
/// Scores are written the way a real engine reports them — from the side to
/// move — so a position that is good for White is a negative number when it
/// is Black's move. [asked] records the positions it was given, so a test can
/// say what the search should not have needed.
final class ScriptedEvaluator implements PositionEvaluator {
  ScriptedEvaluator({this.scores = const {}, this.fallback = 0, this.failAt});

  final Map<String, int> scores;
  final int fallback;

  /// A position the engine refuses to score.
  final String? failAt;

  final List<String> asked = [];

  @override
  Future<EvaluationResult> evaluate(Position position) async {
    final fen = position.fen;
    asked.add(fen);
    if (fen == failAt) {
      return const EvaluationUnavailable('the scripted engine gave up');
    }
    return Evaluated(Eval(scores[fen] ?? fallback));
  }
}

/// An engine that answers nothing but zero, and records how many questions
/// it was holding at once, so a test can say whether they were asked one
/// after another or all together.
final class CountingEvaluator implements PositionEvaluator {
  int inFlight = 0;
  int peakInFlight = 0;

  @override
  Future<EvaluationResult> evaluate(Position position) async {
    inFlight++;
    if (inFlight > peakInFlight) peakInFlight = inFlight;
    await Future<void>.delayed(Duration.zero);
    inFlight--;
    return const Evaluated(Eval(0));
  }
}

/// An opponent model that answers every position with the same weights, keyed
/// by standard UCI. A move it does not mention is a move it says will not be
/// played.
final class ScriptedPolicy implements OpponentPolicy {
  const ScriptedPolicy(this.weights);

  final Map<String, double> weights;

  @override
  Future<PolicyResult> policyFor(Position position) async =>
      PolicyFound(Policy(weights));
}

/// An opponent model with a different answer at each position, keyed by
/// FEN. A position it holds nothing for is a position it cannot answer,
/// which is what a real model does when it is asked about a position its
/// weights do not cover.
final class TabulatedPolicy implements OpponentPolicy {
  const TabulatedPolicy(this.byFen);

  final Map<String, Map<String, double>> byFen;

  @override
  Future<PolicyResult> policyFor(Position position) async {
    final weights = byFen[position.fen];
    return weights == null
        ? const PolicyUnavailable('no scripted policy for this position')
        : PolicyFound(Policy(weights));
  }
}

/// An engine adapter that breaks rather than answering, the way a dead
/// process or a decoder does.
final class ThrowingEvaluator implements PositionEvaluator {
  const ThrowingEvaluator();

  @override
  Future<EvaluationResult> evaluate(Position position) async =>
      throw StateError('the engine process is gone');
}

/// An opponent model that breaks the same way.
final class ThrowingPolicy implements OpponentPolicy {
  const ThrowingPolicy();

  @override
  Future<PolicyResult> policyFor(Position position) async =>
      throw StateError('the model file is truncated');
}

/// An opponent model that is not available at all.
final class AbsentPolicy implements OpponentPolicy {
  const AbsentPolicy();

  @override
  Future<PolicyResult> policyFor(Position position) async =>
      const PolicyUnavailable('the scripted model is not loaded');
}
