/// The board after every ply of a game's mainline, computed once per game.
///
/// Every consumer of a viewer's mainline — cursor navigation, "jump to this
/// FEN", the last-move highlight, the inline comment-line previews — needs
/// the position at some ply.  Each used to replay the SAN list from the start
/// on every call, so a right-arrow press at ply 120 cost 120 `parseSan` +
/// `play` rounds, twice (once for the cursor, once for the highlight).
///
/// This is the single memo behind all of them.  It is keyed on the identity
/// of the owner's private mainline list. The model supplies this memo to its
/// movetext widget, so immutable annotation revisions do not trigger SAN replay.
/// It grows when the mainline is extended and is rebuilt when the list is
/// replaced or shrinks. Standalone hosts can key a memo on immutable snapshots.
library;

import 'package:dartchess/dartchess.dart';
import 'pgn_game_view.dart';

import '../../utils/chess_utils.dart' show playSanOrNullMove;
import '../../utils/fen_utils.dart';

class MainlinePositions {
  MainlinePositions._(this.start, this._length, this._sanAt);

  /// The position before the first ply.
  final Position start;

  final int Function() _length;
  final String Function(int) _sanAt;

  /// `[k]` is the board after `k` half-moves.  Shorter than the mainline
  /// when a SAN fails to play; see [reachablePlies].
  final List<Position> _positions = [];

  /// Normalised FENs of [_positions], filled on first use by [indexOfFen].
  List<String>? _normalizedFens;
  List<Position>? _positionsView;

  /// How many mainline entries have been consumed, legal or not.  Equals the
  /// mainline length once every ply has been tried.
  int _consumed = 0;

  static final Expando<MainlinePositions> _byHistory = Expando(
    'MainlinePositions',
  );

  /// The memo for [history] played from [start]; creates or refreshes it
  /// as needed.  A different [start] object for the same list (a reload)
  /// rebuilds from scratch.
  static MainlinePositions of(List<PgnNodeData> history, Position start) =>
      _forHistory(history, start, () => history.length, (i) => history[i].san);

  static MainlinePositions ofSnapshots(
    List<PgnMoveSnapshot> history,
    Position start,
  ) => _forHistory(history, start, () => history.length, (i) => history[i].san);

  static MainlinePositions _forHistory(
    Object moveHistory,
    Position start,
    int Function() length,
    String Function(int) sanAt,
  ) {
    final cached = _byHistory[moveHistory];
    if (cached != null && identical(cached.start, start)) {
      return cached.._sync();
    }
    final fresh = MainlinePositions._(start, length, sanAt)
      .._positions.add(start)
      .._sync();
    _byHistory[moveHistory] = fresh;
    return fresh;
  }

  /// Bring [_positions] in line with the current history: play the plies
  /// added since last time, or start over if the list shrank.
  void _sync() {
    if (_length() < _consumed) {
      _positions.length = 1;
      _positionsView = null;
      _normalizedFens = null;
      _consumed = 0;
    }
    if (_consumed == _length()) return;
    _positionsView = null;
    // A ply that failed to play leaves everything after it unreachable; the
    // positions stop there, but the plies still count as consumed so the
    // same illegal move is not retried on every read.
    var pos = _positions.last;
    final broken = _positions.length - 1 < _consumed;
    for (var i = _consumed; i < _length(); i++) {
      if (!broken) {
        final next = playSanOrNullMove(pos, _sanAt(i));
        if (next != null) {
          pos = next;
          _positions.add(pos);
          continue;
        }
      }
      // Once broken, fall through for the rest.
      _consumed = _length();
      return;
    }
    _consumed = _length();
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
  List<Position> get positions =>
      _positionsView ??= List.unmodifiable(_positions);

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
