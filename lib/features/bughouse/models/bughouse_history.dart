import 'package:dartchess/dartchess.dart';

import 'bughouse_state.dart';

/// One half-move played on one board.
///
/// A bughouse game is not one move list, and the fix is not to interleave the
/// two into one. FICS never did: it ran the two boards as two ordinary games,
/// each with its own numbering, its own clock and its own movetext, linked
/// only by the partnership. So each ply records the board it landed on and
/// reads back with *that board's* move number — `2. e5` on A, `2... dxc4` on
/// B — and the entry order survives as the index into the line, which is what
/// navigation uses.
class BughousePly {
  const BughousePly({
    required this.board,
    required this.move,
    required this.san,
    required this.before,
    required this.after,
  });

  final BughouseBoard board;
  final Move move;

  /// SAN as played on its own board, e.g. `Nf3`, `P@e5`.
  final String san;

  /// Positions either side of this ply, so navigation is a lookup rather than
  /// a replay — and so a capture's cross-board piece flow is never recomputed
  /// (and never drifts) while stepping backwards.
  final BughouseState before;
  final BughouseState after;

  /// `1e2e4` — the board-prefixed form the engine speaks.
  String get enginePrefixedUci => '${board.uciPrefix}${move.uci}';

  String get label => '${board.shortLabel}: $san';

  /// This board's own move number, as an ordinary game would count it.
  int get moveNumber => before.board(board).fullmoves;

  /// Who played it, on its own board.
  Side get side => before.board(board).turn;

  /// `12.` or `12...` — the prefix a movetext puts before this ply.
  String get numberLabel =>
      side == Side.white ? '$moveNumber.' : '$moveNumber...';
}

/// The played line plus a cursor into it.
///
/// Navigating does not truncate; playing a new move from a rewound position
/// does, which is the behaviour every board viewer has.
class BughouseHistory {
  BughouseHistory(this.initial) : _plies = [], _cursor = 0;

  BughouseHistory._(this.initial, this._plies, this._cursor);

  /// The position the line starts from — restored by [toStart] and by [reset].
  final BughouseState initial;

  final List<BughousePly> _plies;
  int _cursor;

  List<BughousePly> get plies => List.unmodifiable(_plies);

  /// How many plies are behind the cursor.
  int get cursor => _cursor;
  int get length => _plies.length;
  bool get isEmpty => _plies.isEmpty;
  bool get canGoBack => _cursor > 0;
  bool get canGoForward => _cursor < _plies.length;

  /// The position at the cursor.
  BughouseState get current =>
      _cursor == 0 ? initial : _plies[_cursor - 1].after;

  /// The ply that produced [current], if any — what a move list highlights.
  BughousePly? get currentPly => _cursor == 0 ? null : _plies[_cursor - 1];

  /// Appends a ply, discarding anything after the cursor.
  void push(BughousePly ply) {
    if (_cursor < _plies.length) _plies.removeRange(_cursor, _plies.length);
    _plies.add(ply);
    _cursor = _plies.length;
  }

  /// Removes the ply before the cursor and steps back onto its predecessor.
  BughousePly? undo() {
    if (_cursor == 0) return null;
    final removed = _plies.removeAt(_cursor - 1);
    _cursor--;
    // Everything after a removed ply was computed from it, so it cannot be
    // kept — undo in a two-board game is a truncation, not a step back.
    if (_cursor < _plies.length) _plies.removeRange(_cursor, _plies.length);
    return removed;
  }

  void goTo(int index) => _cursor = index.clamp(0, _plies.length);
  void back() => goTo(_cursor - 1);
  void forward() => goTo(_cursor + 1);
  void toStart() => goTo(0);
  void toEnd() => goTo(_plies.length);

  /// A fresh history rooted at [state], keeping nothing.
  static BughouseHistory from(BughouseState state) => BughouseHistory(state);

  /// Re-roots the line at [state] while keeping the plies — used when a
  /// setting that is not part of the position (team, clocks, time advantage)
  /// changes and every recorded position needs it applied.
  BughouseHistory rerootWith(BughouseState Function(BughouseState) transform) {
    return BughouseHistory._(
      transform(initial),
      _plies
          .map(
            (p) => BughousePly(
              board: p.board,
              move: p.move,
              san: p.san,
              before: transform(p.before),
              after: transform(p.after),
            ),
          )
          .toList(),
      _cursor,
    );
  }
}
