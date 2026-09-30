import '../chess/fen.dart';
import '../chess/generation/mainline_book.dart'
    show BookAnswer, BookLost, BookMissed, BookMoves, BookSpent;
import 'remote_queue.dart';
import 'search_evaluator.dart' show chessDbCp;

/// One move ChessDB knows at a position and its score, from the side to
/// move, in the search's packed centipawns.
typedef ChessDbMove = ({String uci, int cp});

/// ChessDB's moves at a position (`queryall`), best first, for one run: the
/// audit's strong replies and the mainline book. Asked through the run's
/// share of the environment's [RemoteQueue], which keeps the requests to
/// ChessDB's manners. A position is asked once per run while it has an
/// answer; one that could not be asked is asked again next time.
///
/// See <https://www.chessdb.cn/cloudbookc_api_en.html>. `learn=0` asks
/// ChessDB not to queue the position for its own analysis.
final class ChessDbMoves {
  ChessDbMoves(this._run);

  final RemoteRun _run;
  final _answers = <String, Future<List<ChessDbMove>?>>{};

  /// Whether ChessDB stopped answering this run, so what it found is
  /// incomplete.
  bool get dropped => _run.dropped;

  /// The moves ChessDB scores at [fen], best first; empty when it knows the
  /// position and has no move for it (or does not know it), null when it
  /// could not be asked.
  Future<List<ChessDbMove>?> movesAt(Fen fen) {
    final key = fen.position;
    return _answers[key] ??= () async {
      final body = await _run.get(
        Uri.https('www.chessdb.cn', '/cdb.php', {
          'action': 'queryall',
          'board': fen.value,
          'learn': '0',
        }),
      );
      if (body == null) _answers.remove(key);
      return body == null ? null : chessDbMoves(body);
    }();
  }

  /// [movesAt] as the mainline book reads it: a position that could not be
  /// asked is one miss while ChessDB still answers the run, the end of the
  /// build once it stopped answering, and the build's budget once the run
  /// has asked every question it may.
  Future<BookAnswer> bookAt(Fen fen) async => switch (await movesAt(fen)) {
    final moves? => BookMoves(moves),
    null when _run.dropped => const BookLost(),
    null when _run.spent => const BookSpent(),
    null => const BookMissed(),
  };

  void close() => _run.close();
}

/// `move:e2e4,score:32,rank:2,…|move:d2d4,score:25,…` as moves, best first.
/// `unknown`, `checkmate`, `stalemate` and anything unreadable are no moves.
List<ChessDbMove> chessDbMoves(String body) {
  final moves = <ChessDbMove>[];
  for (final entry in body.trim().split('|')) {
    final fields = {
      for (final field in entry.split(','))
        if (field.indexOf(':') case final at when at > 0)
          field.substring(0, at): field.substring(at + 1),
    };
    final uci = fields['move'];
    final raw = int.tryParse(fields['score'] ?? '');
    final cp = raw == null ? null : chessDbCp(raw);
    if (uci == null || cp == null) continue;
    moves.add((uci: uci, cp: cp.cp));
  }
  moves.sort((a, b) => b.cp.compareTo(a.cp));
  return moves;
}
