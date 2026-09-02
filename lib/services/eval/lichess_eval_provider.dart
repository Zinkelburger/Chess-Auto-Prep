/// The Lichess cloud evaluations as an eval-chain source.
library;

import 'package:flutter/foundation.dart';

import '../../utils/eval_constants.dart';
import '../../utils/fen_utils.dart';
import '../master_games/position_key.dart';
import 'external_eval_provider.dart';
import 'lichess_eval_store.dart';

/// Looks positions up in a built [LichessEvalStore].
///
/// The store is White-relative (as published); [EvalHit] is white-normalized
/// centipawns with a side-to-move relative mate distance, the convention every
/// other provider uses, so both conversions happen here.
class LichessEvalProvider implements ExternalEvalProvider {
  LichessEvalProvider({required this.directory});

  final String directory;
  LichessEvalStore? _store;

  /// Positions available, or 0 before [init].
  int get records => _store?.records ?? 0;

  /// Opens the store; false when the directory holds no finished build.
  Future<bool> init() async {
    if (_store != null) return true;
    try {
      _store = await LichessEvalStore.open(directory);
    } catch (e) {
      if (kDebugMode) debugPrint('[LichessEvalProvider] open failed: $e');
      _store = null;
    }
    return _store != null;
  }

  Future<void> close() async {
    await _store?.close();
    _store = null;
  }

  @override
  Future<EvalLookupResult> lookup(String fen, {required int minDepth}) async {
    final store = _store;
    if (store == null) return const EvalLookupResult.miss();

    final StoredEval? found;
    try {
      found = await store.lookup(positionKey(fen));
    } catch (e) {
      if (kDebugMode) debugPrint('[LichessEvalProvider] lookup failed: $e');
      return const EvalLookupResult.miss();
    }
    if (found == null) return const EvalLookupResult.hardMiss();

    final isWhiteStm = isWhiteToMove(fen);
    final whiteMate = found.mate;
    final int whiteCp;
    int? stmMate;
    if (whiteMate != null) {
      stmMate = isWhiteStm ? whiteMate : -whiteMate;
      whiteCp = whiteMate > 0
          ? kMateCpBase - whiteMate
          : -kMateCpBase - whiteMate;
    } else {
      whiteCp = found.cp;
    }

    if (found.depth < minDepth) return const EvalLookupResult.shallow();

    return EvalLookupResult.found(
      EvalHit(
        cp: whiteCp,
        mate: stmMate,
        depth: found.depth,
        bestMove: found.move,
      ),
    );
  }
}
