/// The board after every ply of a game's mainline, computed once per game.
///
/// Every consumer of a viewer's mainline — cursor navigation, "jump to this
/// FEN", the last-move highlight, the inline comment-line previews — needs
/// the position at some ply.  Each used to replay the SAN list from the start
/// on every call, so a right-arrow press at ply 120 cost 120 `parseSan` +
/// `play` rounds, twice (once for the cursor, once for the highlight).
///
/// This is the single memo behind all of them.  It is keyed on the identity
/// of the `moveHistory` list, the same object the model and the movetext
/// widget share, so both read the same entry; it grows in place when the
/// mainline is extended (amend mode) and is rebuilt when the list is replaced
/// or shrinks.
library;

import 'package:dartchess/dartchess.dart';

import '../../utils/chess_utils.dart' show playSanOrNullMove;
import '../../utils/fen_utils.dart';

class MainlinePositions {
  MainlinePositions._(this.start, this._history);

  /// The position before the first ply.
  final Position start;

  final List<PgnNodeData> _history;

  /// `[k]` is the board after `k` half-moves.  Shorter than the mainline
  /// when a SAN fails to play; see [reachablePlies].
  final List<Position> _positions = [];

  /// Normalised FENs of [_positions], filled on first use by [indexOfFen].
  List<String>? _normalizedFens;

  /// How many mainline entries have been consumed, legal or not.  Equals the
  /// mainline length once every ply has been tried.
  int _consumed = 0;

  static final Expando<MainlinePositions> _byHistory = Expando(
    'MainlinePositions',
  );

  /// The memo for [moveHistory] played from [start]; creates or refreshes it
  /// as needed.  A different [start] object for the same list (a reload)
  /// rebuilds from scratch.
  static MainlinePositions of(List<PgnNodeData> moveHistory, Position start) {
    final cached = _byHistory[moveHistory];
    if (cached != null && identical(cached.start, start)) {
      return cached.._sync();
    }
    final fresh = MainlinePositions._(start, moveHistory)
      .._positions.add(start)
      .._sync();
    _byHistory[moveHistory] = fresh;
    return fresh;
  }

  /// Bring [_positions] in line with the current [_history]: play the plies
  /// added since last time, or start over if the list shrank.
  void _sync() {
    if (_history.length < _consumed) {
      _positions.length = 1;
      _normalizedFens = null;
      _consumed = 0;
    }
    if (_consumed == _history.length) return;
    // A ply that failed to play leaves everything after it unreachable; the
    // positions stop there, but the plies still count as consumed so the
    // same illegal move is not retried on every read.
    var pos = _positions.last;
    final broken = _positions.length - 1 < _consumed;
    for (var i = _consumed; i < _history.length; i++) {
      if (!broken) {
        final next = playSanOrNullMove(pos, _history[i].san);
        if (next != null) {
          pos = next;
          _positions.add(pos);
          continue;
        }
      }
      // Once broken, fall through for the rest.
      _consumed = _history.length;
      return;
    }
    _consumed = _history.length;
  }

  /// Number of plies with a position: `[0, reachablePlies]` are valid
  /// arguments to [at].
  int get reachablePlies => _positions.length - 1;

  /// The board after [ply] half-moves, or the last reachable board when the
  /// mainline breaks before [ply] — what a cursor parked past an illegal move
  /// should show.
  Position at(int ply) => _positions[ply.clamp(0, _positions.length - 1)];

  /// The board after [ply] half-moves, or null when [ply] is out of range or
  /// past an illegal move.
  Position? tryAt(int ply) =>
      ply >= 0 && ply < _positions.length ? _positions[ply] : null;

  /// Read-only view of every reachable position, `[k]` after `k` plies.
  List<Position> get positions => List.unmodifiable(_positions);

  /// Ply whose position matches [normalizedFen] (4-field), or null.  Ply 0
  /// is [start].
  int? indexOfFen(String normalizedFen) {
    final fens = _normalizedFens ??= [];
    for (var i = fens.length; i < _positions.length; i++) {
      fens.add(normalizeFen(_positions[i].fen));
    }
    final index = fens.indexOf(normalizedFen);
    return index < 0 ? null : index;
  }
}
