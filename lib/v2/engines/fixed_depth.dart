import 'package:dartchess/dartchess.dart' show Position;

import '../chess/fen.dart';
import '../chess/generation/eval.dart';
import '../chess/generation/sources.dart';
import 'engine.dart';
import 'engine_line.dart';

/// An engine as the search sees it: one fixed-depth verdict per position,
/// from the side to move, the way UCI reports it.
///
/// Each question is one `go depth` search on [engine]; the engine answers
/// them one after another, and the last best line it reports before
/// `bestmove` is the verdict — but only if it reached [depth]. A search that
/// ends with no line, or whose last line is shallower (an engine that died,
/// or was quit under the run, part way through), is [EvaluationUnavailable],
/// which is what stops the search rather than scoring the position level or
/// letting the cache keep a depth-5 guess labelled depth 14.
///
/// Two shallow lines are verdicts all the same: a mate score, which is
/// proven by the moves after it and is where an engine may stop iterating
/// early, and a line with no moves, which is a game already over (Stockfish
/// answers checkmate or stalemate at depth 0).
final class FixedDepthEvaluator implements PositionEvaluator {
  const FixedDepthEvaluator(this.engine, {required this.depth});

  final Engine engine;
  final int depth;

  @override
  Future<EvaluationResult> evaluate(Position position) async {
    final search = engine.analyse(Fen(position.fen), multiPv: 1, depth: depth);
    EngineLine? verdict;
    await for (final line in search.lines) {
      if (line.multiPv == 1) verdict = line;
    }
    if (verdict == null) {
      return EvaluationUnavailable('${engine.name} gave no evaluation');
    }
    final settled =
        verdict.depth >= depth || verdict.score is MateIn || verdict.pv.isEmpty;
    if (!settled) {
      return EvaluationUnavailable(
        '${engine.name} stopped at depth ${verdict.depth} of $depth',
      );
    }
    return Evaluated(packedCp(verdict.score));
  }
}

/// A score as the search's packed centipawns: a mate in N is ±(10000 − N)
/// for the side giving it, which is how the old builder and the C builder
/// write one, and what [expectedScore] saturates on.
Eval packedCp(Score score) => switch (score) {
  Centipawns(:final value) => Eval(value),
  MateIn(:final moves, :final mating) => Eval(
    mating ? mateBaseCp - moves.abs() : -(mateBaseCp - moves.abs()),
  ),
};
