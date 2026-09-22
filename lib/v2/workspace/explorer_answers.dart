import '../chess/explorer_answer.dart';
import '../chess/explorer_choice.dart';
import '../chess/fen.dart';

/// What the databases have answered this session, and what that says about
/// asking deeper.
///
/// Answers are kept by choice and position, the oldest dropped past
/// [cacheSize]. Empty answers are counted along a line: each one deeper
/// than the last adds to the run, and after [emptiesBeforeStopping] of
/// them nothing deeper is asked — a line that left the database three
/// positions ago will not come back into it. A non-empty answer, or an
/// empty one no deeper than the last, starts the count again.
///
/// Example: empty answers at plies 8, 9 and 10 stop the asking at ply 11
/// and below; the user stepping back to ply 7 is asked about as usual.
final class ExplorerAnswers {
  /// How many answers are kept.
  static const cacheSize = 2000;

  /// How many empty answers in a row, each deeper than the last, stop the
  /// asking on that line.
  static const emptiesBeforeStopping = 3;

  final _cache = <String, ExplorerAnswer>{};
  int _emptyRun = 0;
  int _emptyPly = -1;

  ExplorerAnswer? at(Fen fen, ExplorerChoice choice) =>
      _cache[_key(fen, choice)];

  /// Keeps [answer] and counts it if it is empty.
  void remember(Fen fen, ExplorerChoice choice, ExplorerAnswer answer) {
    _cache[_key(fen, choice)] = answer;
    while (_cache.length > cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    if (!answer.isEmpty) {
      _emptyRun = 0;
      return;
    }
    final ply = plyOf(fen);
    _emptyRun = ply > _emptyPly ? _emptyRun + 1 : 1;
    _emptyPly = ply;
  }

  /// Drops the answer for [fen], so the next ask goes to the database.
  void forget(Fen fen, ExplorerChoice choice) =>
      _cache.remove(_key(fen, choice));

  /// The line's empty answers no longer stop anything: the user asked again
  /// or asked another database.
  void resetEmpties() => _emptyRun = 0;

  /// Whether a position [ply] plies deep is past the empty answers on its
  /// line, and so not worth asking about.
  bool pastEmpties(int ply) =>
      _emptyRun >= emptiesBeforeStopping && ply > _emptyPly;

  String _key(Fen fen, ExplorerChoice choice) =>
      '${choice.key}|${fen.position}';
}

/// How many plies deep [fen] is: nought at the start.
int plyOf(Fen fen) => (fen.fullMove - 1) * 2 + (fen.whiteToMove ? 0 : 1);
