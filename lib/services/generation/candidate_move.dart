/// A candidate move for our side during repertoire generation.
///
/// Holds the engine evaluation and DB win rate so that
/// [MoveSelectionPolicy] implementations can rank candidates
/// without re-fetching data.
library;

class CandidateMove {
  final String uci;
  final String san;
  final String childFen;

  /// Evaluation in centipawns from White's perspective.
  final int evalWhiteCp;

  /// Win rate from our repertoire side's perspective (0–1).
  final double winRate;

  const CandidateMove({
    required this.uci,
    required this.san,
    required this.childFen,
    required this.evalWhiteCp,
    required this.winRate,
  });

  /// Evaluation from the given side's perspective.
  int evalForSide({required bool asWhite}) =>
      asWhite ? evalWhiteCp : -evalWhiteCp;
}
