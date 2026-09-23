import 'dart:async';

import '../chess/book/book_check.dart' show BookPlace;
import '../features/my_games/game_book.dart';
import '../storage/chapter_files.dart';
import '../workspace/document_session.dart';
import 'workspace_requests.dart';

/// Where My games takes the user: one of their games at the moment its
/// verdict is about, the next or previous game of the list, and the place
/// in the book where a game left it, in the builder.
final class MyGamesDoors {
  MyGamesDoors({
    required WorkspaceRequests requests,
    required DocumentSession session,
    required GameBook book,
  }) : _requests = requests,
       _session = session,
       _book = book;

  final WorkspaceRequests _requests;
  final DocumentSession _session;
  final GameBook _book;

  /// The game on the board, seen from the user's side, at its moment.
  void open(CheckedGame checked) => unawaited(
    _requests.openGame(
      checked.file,
      game: checked.game.index,
      ply: checked.moment,
      side: checked.game.side,
    ),
  );

  /// The game [by] places down the list from the one on the board.
  void step(int by) {
    final next = _book.step(_session.source, _session.game, by);
    if (next != null) open(next);
  }

  /// The file of the book at [place], in the builder.
  void readBook(BookPlace place) => unawaited(
    _requests.readInBuilder(ChapterRef.at(place.file.path), place.sans),
  );
}
