import 'package:dartchess/dartchess.dart' show Side;

/// What one search is asked to do.
///
/// The defaults are the ones the product ships: look four half-moves ahead
/// and prepare every move that costs at most two pawns against the best one.
/// A deeper horizon costs exponentially more, which is why four is the
/// default rather than a compromise.
final class SearchConfig {
  const SearchConfig({
    required this.side,
    this.horizonPlies = 4,
    this.lossLimitCp = 200,
    this.nodeBudget,
  });

  /// The side the repertoire is for. Our nodes are the ones where this side
  /// is to move, wherever in the tree they fall, and every value in the tree
  /// is an expected score for it.
  final Side side;

  /// How many half-moves from the root the search plays out before it stops
  /// and lets the engine value the position instead.
  final int horizonPlies;

  /// L in centipawns: one of our legal moves is prepared when the engine
  /// scores it within this much of our best move at the fixed depth.
  final int lossLimitCp;

  /// Stop rather than begin an expansion that would take the tree past this
  /// many nodes. Null runs to the horizon however large that is. The budget
  /// is spent on whole expansions, so some of it can be left unused when the
  /// next one does not fit.
  final int? nodeBudget;
}
