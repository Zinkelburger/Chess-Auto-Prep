/// Ranked move lists from an external position database (ChessDB).
///
/// The eval chain ([resolveEvalChain]) asks a database one question — "how
/// good is this position?" — and throws the rest of the answer away.  ChessDB
/// actually answers a bigger one: *every* move it knows from the position,
/// scored and ranked.  That answer is what a mainline book is built from, and
/// it costs the same single lookup, so this is the interface for asking it.
library;

/// One move of a database's ranked answer for a position.
class DbMove {
  /// UCI move played from the queried position, e.g. `e2e4`.
  final String uci;

  /// SAN when the source supplies it — ChessDB's JSON API does, the cdbdirect
  /// dump does not.  Empty means "work it out from the position".
  final String san;

  /// Score **after** this move, from the point of view of the side to move in
  /// the *queried* position.  Positive is good for the player choosing.  This
  /// is ChessDB's own convention; see the sign zoo in
  /// `lib/services/generation/README.md` before moving it anywhere.
  final int stmCp;

  /// Moves to mate when this is a mate score, signed like [stmCp].
  final int? mate;

  /// ChessDB's coarse quality bucket for the move, or null when the source
  /// reports none.
  ///
  /// Carried for display and debugging only — deliberately **not** part of
  /// any ordering.  The live `queryall` API ranks *upward* (a `rank:2` move
  /// scoring 10 sits above a `rank:0` move annotated `?`), which is the
  /// opposite of what the C reader this ports assumed of the dump, and one
  /// of the two must be wrong.  Score is the number both faces agree on, so
  /// score is what decides; see [DbMoveList.sorted].
  final int? rank;

  /// ChessDB's annotation for the move (`!`, `!?`, `??`, …), when present.
  final String? note;

  const DbMove({
    required this.uci,
    this.san = '',
    required this.stmCp,
    this.mate,
    this.rank,
    this.note,
  });

  @override
  String toString() => 'DbMove($uci, $stmCp, rank $rank)';
}

/// A database's full answer for one position, best move first.
class DbMoveList {
  /// Sorted best-first: descending [DbMove.stmCp], ties broken by rank.
  final List<DbMove> moves;

  /// Which source answered.  Recorded so a build can report how much of the
  /// book came from the dump, the network, and the engine.
  final DbMoveSource source;

  const DbMoveList({required this.moves, required this.source});

  static const DbMoveList empty = DbMoveList(
    moves: [],
    source: DbMoveSource.none,
  );

  bool get isEmpty => moves.isEmpty;
  bool get isNotEmpty => moves.isNotEmpty;

  /// The database's own best move, or null when it knows nothing here.
  DbMove? get best => moves.isEmpty ? null : moves.first;

  /// Score of the position itself: the best move's score.
  int? get bestStmCp => moves.isEmpty ? null : moves.first.stmCp;

  /// Every move within [windowCp] of the best.  Used for tie-breaking, never
  /// for widening the book — a mainline book plays one move.
  List<DbMove> withinCp(int windowCp) {
    if (moves.isEmpty) return const [];
    final top = moves.first.stmCp;
    return [
      for (final m in moves)
        if (top - m.stmCp <= windowCp) m,
    ];
  }

  /// Sort a raw move list into best-first order.
  ///
  /// Score decides, and score alone — [DbMove.rank] means opposite things on
  /// the two ChessDB faces (see its doc) and is not trustworthy enough to
  /// order by.  Exact score ties keep the source's order, which is stable
  /// rather than meaningful; the book builder settles those on master games
  /// instead.
  static List<DbMove> sorted(Iterable<DbMove> raw) {
    // Indexed so ties keep source order: Dart's sort is not stable, and two
    // identical const DbMoves are the same object, so identity cannot stand
    // in for position.
    final indexed = raw.indexed.toList()
      ..sort((a, b) {
        final byScore = b.$2.stmCp.compareTo(a.$2.stmCp);
        return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
      });
    return [for (final e in indexed) e.$2];
  }
}

/// Where a [DbMoveList] came from.
enum DbMoveSource {
  /// Nothing answered.
  none,

  /// Local TerarkDB dump through cdbdirect (FFI).
  cdbDirect,

  /// chessdb.cn `queryall` over the network.
  chessDbApi,

  /// Local engine, when no database knew the position.
  stockfish,
}

/// A source that can answer with a whole ranked move list, not just a score.
abstract class ExternalMoveProvider {
  /// Every move [fen] is known by, best first.  Empty on a miss.
  Future<DbMoveList> lookupMoves(String fen);
}
