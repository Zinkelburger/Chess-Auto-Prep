import '../chess/explorer_answer.dart';
import '../chess/explorer_choice.dart';
import '../chess/fen.dart';
import '../net/lichess_explorer.dart';
import '../storage/master_book.dart';

/// The databases the explorer can ask: Lichess's two over the network and
/// the master book (TWIC) on this machine. Says how to reach each one for a
/// position or for one game's moves, and puts what went wrong in a sentence;
/// holds nothing between asks.
final class ExplorerDatabases {
  const ExplorerDatabases({
    required LichessExplorer lichess,
    required MasterBook book,
  }) : _lichess = lichess,
       _book = book;

  final LichessExplorer _lichess;
  final MasterBook _book;

  /// Whether the master book is on this machine.
  Future<bool> bookAvailable() => _book.available();

  /// What [choice] says about [fen], or the sentence saying why there is
  /// no answer. A network failure names TWIC when the book is here.
  Future<(ExplorerAnswer?, String?)> ask(Fen fen, ExplorerChoice choice) async {
    if (choice.source == ExplorerSource.twic) {
      return switch (await _book.lookup(
        fen,
        classicalOnly: choice.classicalOnly,
      )) {
        BookFound(:final answer) => (answer, null),
        BookAbsent() => (null, 'There is no master database on this machine.'),
        BookUnreadable() => (null, 'The master database could not be read.'),
      };
    }
    switch (await _lichess.fetch(ExplorerQuery(fen, choice))) {
      case ExplorerFetched(:final answer):
        return (answer, null);
      case ExplorerNotFetched(:final problem, :final sentence):
        final offline =
            problem == ExplorerProblem.unreachable && await _book.available();
        return (null, offline ? '$sentence TWIC works offline.' : sentence);
    }
  }

  /// The PGN of [game] from the database that listed it, or null when it
  /// could not be had.
  Future<String?> gamePgn(ExplorerGame game, ExplorerSource source) =>
      source == ExplorerSource.twic
      ? _book.gamePgn(game.id)
      : _lichess.gamePgn(game.id, masters: source == ExplorerSource.masters);
}
