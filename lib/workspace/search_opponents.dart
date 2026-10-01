import 'package:dartchess/dartchess.dart' show Position;

import '../chess/fen.dart';
import '../chess/generation/mainline_book.dart' show PlayedMove;
import '../chess/generation/sources.dart';
import '../engines/maia/move_policy.dart';
import '../storage/master_book.dart';

// The opponents a search from the board plays against: the Maia model for
// the practical search, the masters' games for the mainline book. And what
// the engine told it that the tree does not keep.

/// The Maia model as the search's opponent, at one rating.
///
/// The model answers with shares over the legal moves, most likely first,
/// which is already a policy; a position it cannot read is a position the
/// search stops at, as the algorithm requires.
final class MaiaOpponent implements OpponentPolicy {
  const MaiaOpponent(this.model, {required this.elo});

  final MovePolicy model;
  final int elo;

  @override
  Future<PolicyResult> policyFor(Position position) async =>
      switch (await model.policy(Fen(position.fen), elo)) {
        MaiaPolicy(:final shares) => PolicyFound(Policy(shares)),
        MaiaFailed(:final reason) => PolicyUnavailable(reason),
      };
}

/// The replies masters played, in the games on this machine, as the
/// mainline book follows them.
final class MastersPlayed {
  const MastersPlayed(this._book);

  final MasterBook _book;

  /// The replies masters played at [fen], most played first, over the
  /// board or not; none where the games cannot be read.
  Future<List<PlayedMove>> at(Fen fen) async => switch (await _book.lookup(
    fen,
    classicalOnly: false,
  )) {
    BookFound(:final answer) => [
      for (final move in answer.moves) (uci: move.uci, games: move.games),
    ],
    BookAbsent() || BookUnreadable() || BookClassicalIncomplete() => const [],
  };
}

/// What the engine said during one owner's searches that the tree does not
/// keep: the depth each score was reached at, and the engine's best line.
/// Only answers the evaluator actually supplied are recorded — a cached
/// score has no line — and both are session-local: a saved tree records
/// neither.
///
/// Keyed by the four-field position, since neither depends on the clocks.
final class EngineAnswers implements PositionEvaluator {
  EngineAnswers(this.evaluator, {required this.depths, required this.lines});

  final PositionEvaluator evaluator;
  final Map<String, int> depths;
  final Map<String, List<String>> lines;

  @override
  Future<EvaluationResult> evaluate(Position position) async {
    final result = await evaluationOf(evaluator, position);
    if (result case Evaluated(:final depth, :final pv)) {
      final key = Fen(position.fen).position;
      if (depth != null) depths[key] = depth;
      if (pv.isNotEmpty) lines[key] = pv;
    }
    return result;
  }
}
