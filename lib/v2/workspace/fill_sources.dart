import 'package:dartchess/dartchess.dart' show Position, Side;

import '../chess/fen.dart';
import '../chess/generation/eval.dart';
import '../chess/generation/sources.dart';
import '../engines/maia/move_policy.dart';
import '../storage/eval_cache.dart';

/// The engine with the cache in front of it: a position the cache holds at
/// the depth asked for is answered from there, and every verdict the engine
/// gives is written back, from White's side, so a later run of either app
/// finds it.
///
/// The engine answers from the side to move and the cache keeps White's
/// view, so one negation each way when it is Black's move.
final class CachedEvaluator implements PositionEvaluator {
  const CachedEvaluator(this.engine, this.cache, {required this.depth});

  final PositionEvaluator engine;
  final EvalCache cache;
  final int depth;

  @override
  Future<EvaluationResult> evaluate(Position position) async {
    final fen = Fen(position.fen);
    final white = position.turn == Side.white;
    final kept = cache.read(fen.position, minDepth: depth);
    if (kept != null) return Evaluated(Eval(white ? kept : -kept));
    final answer = await evaluationOf(engine, position);
    if (answer case Evaluated(:final eval)) {
      cache.write(
        fen.position,
        cpWhite: white ? eval.cp : -eval.cp,
        depth: depth,
      );
    }
    return answer;
  }
}

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
