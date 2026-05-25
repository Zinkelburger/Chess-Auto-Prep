/// Generic external evaluation lookup interface for the 3-phase eval chain.
library;

import 'eval_canonicalize.dart';

/// A qualifying evaluation from an external source.
///
/// [cp] is always white-normalized centipawns (same convention as [EvalCache]).
class EvalHit {
  final int cp;
  final int? mate;
  final int depth;
  final String? bestMove;

  const EvalHit({
    required this.cp,
    this.mate,
    required this.depth,
    this.bestMove,
  });
}

/// Outcome of a single provider lookup (hit, miss, shallow, or hard miss).
class EvalLookupResult {
  final EvalHit? hit;
  final bool shallow;
  final bool hardMiss;

  const EvalLookupResult._({
    this.hit,
    this.shallow = false,
    this.hardMiss = false,
  });

  const EvalLookupResult.miss() : this._();

  const EvalLookupResult.shallow() : this._(shallow: true);

  const EvalLookupResult.hardMiss() : this._(hardMiss: true);

  const EvalLookupResult.found(EvalHit value)
      : this._(hit: value, shallow: false, hardMiss: false);

  bool get isHit => hit != null;
}

/// Maps raw SQLite cp/mate columns to white-normalized centipawns.
///
/// [isWhiteToMove] is the side to move in the position being evaluated.
/// Returns null when neither cp nor mate is present.
int? mapSqliteScoreToWhiteCp({
  required int? cp,
  required int? mate,
  required bool isWhiteToMove,
}) {
  if (mate != null) {
    final stmCp = mate > 0 ? (10000 - mate) : (-10000 - mate);
    return isWhiteToMove ? stmCp : -stmCp;
  }
  if (cp != null) {
    return isWhiteToMove ? cp : -cp;
  }
  return null;
}

abstract class ExternalEvalProvider {
  /// Look up an eval for [fen] at or above [minDepth].
  ///
  /// Implementations canonicalize [fen] to 4 fields before lookup.
  Future<EvalLookupResult> lookup(String fen, {required int minDepth});
}
