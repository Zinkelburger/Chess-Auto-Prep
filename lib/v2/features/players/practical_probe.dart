import '../../chess/fen.dart';
import '../../chess/generation/eval.dart';
import '../../chess/pv_text.dart';
import '../../engines/engine_line.dart';
import '../../engines/fixed_depth.dart';
import '../../engines/maia/move_policy.dart';

/// A bounded, conservative estimate of an attacker's chance after a candidate
/// move. Only the five most likely legal replies are probed; unprobed mass is
/// valued as perfect defence. These are model estimates, never forced wins.
Future<double?> practicalScore({
  required Fen start,
  required EngineLine candidate,
  required MovePolicy model,
  required int rating,
  required Future<EngineLine?> Function(Fen) evaluate,
  required bool Function() cancelled,
}) async {
  final move = pvMoves(start, candidate.pv.take(1).toList()).firstOrNull;
  if (move == null) return null;
  final answer = await model.policy(move.after, rating);
  if (answer is MaiaFailed) throw StateError(answer.reason);
  if (cancelled()) return null;
  final shares = (answer as MaiaPolicy).shares.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final base = expectedScore(packedCp(candidate.score));
  var value = base;
  for (final reply in shares.take(5)) {
    if (cancelled()) return null;
    final after = pvMoves(move.after, [reply.key]).firstOrNull?.after;
    if (after == null || reply.value <= 0) continue;
    final evaluated = await evaluate(after);
    if (evaluated == null || cancelled()) return null;
    // Two plies after start: the attacker is on move again.
    final actual = expectedScore(packedCp(evaluated.score));
    value += reply.value * (actual - base).clamp(0, 1);
  }
  return value.clamp(0, 1);
}
