/// Cross-game memo of opening evaluations for one import run.
library;

import '../../../services/engine/eval_worker.dart';

/// Opening evaluations keyed by FEN.
///
/// The same player repeats the same first moves across most of their games,
/// so positions up to fullmove [maxFullmove] are searched once per import run
/// and reused. Futures (not results) are stored so two workers reaching the
/// same position concurrently coalesce into one search.
class OpeningEvalCache {
  OpeningEvalCache({required this.depth});

  /// Search depth of every cached entry — one cache is only valid for one
  /// depth, which holds because depth is fixed for a whole import run.
  final int depth;

  final Map<String, Future<EvalResult>> _byFen = {};

  static const int maxFullmove = 10;

  static bool _isOpeningFen(String fen) {
    final fields = fen.split(' ');
    if (fields.length < 6) return false;
    final fullmove = int.tryParse(fields[5]);
    return fullmove != null && fullmove <= maxFullmove;
  }

  /// Evaluate [fen] on [worker], serving repeats from the cache.
  Future<EvalResult> evaluate(EvalWorker worker, String fen) async {
    if (!_isOpeningFen(fen)) return worker.evaluateFen(fen, depth);
    final cached = _byFen[fen];
    if (cached != null) return cached;
    final search = worker.evaluateFen(fen, depth);
    _byFen[fen] = search;
    try {
      return await search;
    } catch (_) {
      // Don't let a failed search (engine hiccup, cancellation) poison the
      // position for every later game in the run.
      _byFen.remove(fen); // ignore: unawaited_futures
      rethrow;
    }
  }
}
