/// Generic external evaluation lookup interface for the 3-phase eval chain.
library;

/// A qualifying evaluation from an external source.
///
/// [cp] is always white-normalized centipawns (same convention as `EvalCache`),
/// with a forced mate packed through `mateToCp`. [mate], when present, is the
/// distance in the source's own units from the side to move's point of view.
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

/// Outcome of a single provider lookup.
///
/// The four cases mean different things to the eval chain: a [hardMiss] says
/// the source has never seen the position (so its subtree is unlikely to be
/// known either), a plain miss says nothing, and [shallow] means the source
/// answered but below the depth the caller asked for.
sealed class EvalLookupResult {
  const EvalLookupResult();

  const factory EvalLookupResult.found(EvalHit hit) = EvalLookupHit;

  /// The source could not answer, for a reason unrelated to the position.
  const factory EvalLookupResult.miss() = EvalLookupMiss;

  /// The source knows the position, but not deep enough.
  const factory EvalLookupResult.shallow() = EvalLookupShallow;

  /// The source does not know the position at all.
  const factory EvalLookupResult.hardMiss() = EvalLookupHardMiss;

  /// The evaluation, when this is a hit.
  EvalHit? get hit => null;

  bool get isHit => this is EvalLookupHit;
  bool get shallow => this is EvalLookupShallow;
  bool get hardMiss => this is EvalLookupHardMiss;
}

/// The source answered at or above the requested depth.
final class EvalLookupHit extends EvalLookupResult {
  const EvalLookupHit(this.hit);

  @override
  final EvalHit hit;
}

/// The source could not answer (closed, offline, over quota, or it threw).
final class EvalLookupMiss extends EvalLookupResult {
  const EvalLookupMiss();
}

/// The source knows the position, but below the requested depth.
final class EvalLookupShallow extends EvalLookupResult {
  const EvalLookupShallow();
}

/// The source has no record of the position.
final class EvalLookupHardMiss extends EvalLookupResult {
  const EvalLookupHardMiss();
}

abstract class ExternalEvalProvider {
  /// Look up an eval for [fen] at or above [minDepth].
  ///
  /// Implementations canonicalize [fen] to 4 fields before lookup.
  Future<EvalLookupResult> lookup(String fen, {required int minDepth});
}
