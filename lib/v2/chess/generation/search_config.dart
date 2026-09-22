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
    this.pins = const {},
    this.replyFloor = 0,
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

  /// The most nodes the tree may hold, the root counted among them. Null
  /// runs to the horizon however large that is.
  ///
  /// An expansion is begun only when every legal move of the position would
  /// still fit, which is what keeps expansions whole: the count is taken
  /// before the first evaluation, on the legal moves rather than on the ones
  /// the loss window will keep. The rejected moves are not charged, so a
  /// finished tree is usually smaller than its budget and the last of it can
  /// go unused when the next expansion does not fit.
  final int? nodeBudget;

  /// The moves we have already decided on, by the position they are played
  /// from ([Fen.position], the four fields) to the moves in standard or
  /// dartchess UCI. At a pinned position only those moves are enumerated,
  /// so a fill continues the chapter the user has rather than second-guessing
  /// it; the loss window still ranks the pinned moves among themselves. A
  /// pin naming no legal move is ignored.
  final Map<String, Set<String>> pins;

  /// A reply reached less often than this, as a share of the games that
  /// start at the root, is valued where it stands and never expanded — the
  /// `Cover replies met once in N` rule, as `1/N`. Zero expands everything
  /// the horizon allows. Our own moves count as certain, so the reach only
  /// falls at the opponent's moves.
  final double replyFloor;
}
