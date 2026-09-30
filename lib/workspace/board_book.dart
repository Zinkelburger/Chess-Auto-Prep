import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';

import '../chess/book/book_check.dart';
import '../chess/book/played_game.dart';
import '../chess/pgn/chapter.dart';
import 'books.dart';
import 'document_session.dart';
import 'repertoire_shelf.dart';

/// What the book in use says about the game on the board, for the side the
/// board is seen from: the viewer's My books tab and the line under a
/// game's heading. The same check My games makes of the user's own games
/// (`chess/book/book_check.dart`), over the same shelf.
///
/// It reads only while something showing it is up ([watch]); a newer game,
/// an edit, a flip, another book in use or a changed repertoire checks
/// again, and a read overtaken by one of them is dropped.
final class BoardBook extends ChangeNotifier {
  BoardBook({
    required DocumentSession session,
    required RepertoireShelf shelf,
    required Books books,
  }) : _session = session,
       _shelf = shelf,
       _books = books {
    _session.addListener(_changed);
    _shelf.addListener(_changed);
    _books.addListener(_changed);
  }

  final DocumentSession _session;
  final RepertoireShelf _shelf;
  final Books _books;

  BoardBookState _state = const BoardBookIdle();
  BoardBookState get state => _state;

  int _watching = 0;
  int _checks = 0;
  bool _disposed = false;

  /// What the last check was of: another input checks again.
  Object? _checked;

  /// A pane showing the verdict is up: check now, and again whenever the
  /// game or the book changes while it is.
  void watch() {
    if (_watching++ == 0) _changed();
  }

  void unwatch() {
    if (_watching > 0 && --_watching == 0) {
      _checks++;
      _checked = null;
    }
  }

  void _changed() {
    if (_disposed || _watching == 0) return;
    final chapter = _session.chapter;
    final game = _session.game;
    final inputs = (
      chapter,
      _session.orientation,
      _books.active,
      _books.revision,
      _shelf.version,
      _shelf.stale,
    );
    if (inputs == _checked) return;
    _checked = inputs;
    if (chapter == null || game == null || _session.isScratch) {
      return _become(const BoardBookIdle());
    }
    unawaited(_check(chapter, game, _session.orientation));
  }

  Future<void> _check(Chapter chapter, int game, Side side) async {
    final ticket = ++_checks;
    bool overtaken() => _disposed || ticket != _checks;
    final book = _books.active;
    if (book == null) return _become(const BoardBookNotSet());
    final line = chapter.lines[game];
    final tree = line.tree;
    if (tree == null) return _become(const BoardBookIdle());
    if (_shelf.stale) {
      if (_state is! BoardBookChecked) _become(const BoardBookReading());
      await _shelf.read(gone: overtaken);
      if (overtaken()) return;
      // A read that ended fresh notified, which checked again.
      if (_shelf.stale) return _become(const BoardBookFailed());
    }
    final played = playedGame(
      line.tags,
      tree,
      index: game,
      side: side,
      text: line.text,
    );
    final files = _shelf.bookFiles((ref) => _books.contains(book, ref));
    _become(
      BoardBookChecked(
        game: played,
        verdict: checkGame(played, files),
        book: book.name,
      ),
    );
  }

  void _become(BoardBookState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _session.removeListener(_changed);
    _shelf.removeListener(_changed);
    _books.removeListener(_changed);
    super.dispose();
  }
}

/// What the check of the game on the board came to.
sealed class BoardBookState {
  const BoardBookState();
}

/// No game of a file is on the board, so there is nothing to check.
final class BoardBookIdle extends BoardBookState {
  const BoardBookIdle();
}

/// The repertoires are being read.
final class BoardBookReading extends BoardBookState {
  const BoardBookReading();
}

/// The repertoires could not be read; the log says why.
final class BoardBookFailed extends BoardBookState {
  const BoardBookFailed();
}

/// No book is in use.
final class BoardBookNotSet extends BoardBookState {
  const BoardBookNotSet();
}

/// The game, read as the side the board is seen from, and what the book
/// called [book] says about it.
final class BoardBookChecked extends BoardBookState {
  const BoardBookChecked({
    required this.game,
    required this.verdict,
    required this.book,
  });

  final PlayedGame game;
  final BookVerdict verdict;
  final String book;
}
