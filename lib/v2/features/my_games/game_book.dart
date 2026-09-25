import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../chess/book/book_check.dart';
import '../../chess/book/played_game.dart';
import '../../chess/pgn/chapter.dart' show readOffThreadFrom;
import '../../chess/tactics/game_ids.dart';
import '../../storage/chapter_files.dart';
import '../../storage/document_repository.dart';
import '../../diagnostics/log.dart';
import '../../storage/book_list.dart' show Book;
import '../../storage/my_accounts.dart';
import '../../storage/my_games_files.dart';
import '../../workspace/books.dart';
import '../../workspace/repertoire_shelf.dart';
import 'book_words.dart' show matchesSearch;

/// One of the user's games and what their books say about it.
final class CheckedGame {
  const CheckedGame({
    required this.file,
    required this.site,
    required this.game,
    required this.verdict,
  });

  /// The saved-games file it is in; [PlayedGame.index] is where.
  final ChapterRef file;
  final GameSite site;
  final PlayedGame game;
  final BookVerdict verdict;

  /// How many of the game's moves to show when it is opened for its
  /// verdict: the move that left the book, the last move of a book that
  /// ran out, the end of a game in book throughout, else the start.
  int get moment => switch (verdict) {
    LeftBook(kind: Deviation.bookEnded, :final ply) => ply,
    LeftBook(:final ply) => ply + 1,
    InBookThroughout() => game.moves.length,
    NoBook() || OtherOpening() => 0,
  };
}

/// Games that left the book the same way — the same move at the same
/// place, or the same place where the book ends — newest first.
final class SameWay {
  const SameWay(this.games);

  final List<CheckedGame> games;

  /// The newest game's verdict, which speaks for all of them.
  LeftBook get verdict => games.first.verdict as LeftBook;
}

sealed class BookState {
  const BookState();
}

/// The games or the books are being read; nothing to show yet.
final class BookReading extends BookState {
  const BookReading();
}

/// No book is in use, so there is nothing to check the games against.
final class BookNotSet extends BookState {
  const BookNotSet();
}

/// No username is saved, so there are no games to check.
final class BookNoAccounts extends BookState {
  const BookNoAccounts();
}

/// Every saved game of the accounts, checked, newest first; and the ways
/// they left the book, most often first.
final class BookChecked extends BookState {
  const BookChecked({required this.games, required this.ways});

  final List<CheckedGame> games;
  final List<SameWay> ways;

  /// The ways games left the book of [kind], most often first.
  List<SameWay> waysOf(Deviation kind) => [
    for (final way in ways)
      if (way.verdict.kind == kind) way,
  ];
}

/// The user's own games read against the book in use ([Books]): for each saved
/// game of their accounts, the newest [bookCheckWindow] of each, where it
/// left the book and how; and across them, the places it keeps happening.
///
/// It reads only while a pane showing it is up ([watch]): opening the mode
/// reads the games and the books again, and so does a download or a change
/// to the repertoires while it is open. A later read overtakes an earlier
/// one, whose result is dropped.
///
/// The search over the list is the book's too ([search]): the list shows
/// the games it finds and ↑ and ↓ walk them, so the keys never open a game
/// the list is hiding.
final class GameBook extends ChangeNotifier {
  GameBook({
    required AccountStore accounts,
    required GamesCache cache,
    required RepertoireShelf shelf,
    required Books books,
  }) : _accounts = accounts,
       _cache = cache,
       _shelf = shelf,
       _books = books {
    _books.addListener(_bookChanged);
  }

  final AccountStore _accounts;
  final GamesCache _cache;
  final RepertoireShelf _shelf;
  final Books _books;

  /// The book as the last read saw it: another book in use, or an edit to
  /// this one, reads again.
  (Book?, int)? _bookSeen;
  (Book?, int) get _bookInput => (_books.active, _books.revision);

  BookState _state = const BookReading();
  String _query = '';
  int _reads = 0;
  int _watching = 0;
  bool _disposed = false;
  String? _problem;

  /// Why the games could not be compared at all, when they could not; the
  /// last comparison stays on screen meanwhile.
  String? get problem => _problem;

  BookState get state => _state;

  /// What the list is narrowed to, trimmed and in lower case; empty while
  /// it shows every game.
  String get query => _query;

  /// Narrows the list to the games a search for [words] finds.
  void search(String words) {
    final query = words.trim().toLowerCase();
    if (query == _query) return;
    _query = query;
    notifyListeners();
  }

  /// The checked games the search finds, newest first: every game while
  /// nothing is typed, and none before the games are read.
  List<CheckedGame> get shown => switch (_state) {
    BookChecked(:final games) => [
      for (final checked in games)
        if (_found(checked)) checked,
    ],
    _ => const [],
  };

  /// The checked game [file] holds at [game], or null when it is not one.
  CheckedGame? find(ChapterRef? file, int? game) {
    final state = _state;
    if (state is! BookChecked || file == null || game == null) return null;
    for (final checked in state.games) {
      if (checked.file == file && checked.game.index == game) return checked;
    }
    return null;
  }

  /// The game [by] places after the one [file] holds at [game] among the
  /// games the search finds, newest first, counted from where that game
  /// sits in the list even when the search hides it; null past either end
  /// or when that is not a checked game.
  CheckedGame? step(ChapterRef? file, int? game, int by) {
    final state = _state;
    final here = find(file, game);
    if (state is! BookChecked || here == null) return null;
    final games = state.games;
    var at = games.indexOf(here);
    var left = by.abs();
    while (left > 0) {
      at += by.sign;
      if (at < 0 || at >= games.length) return null;
      if (_found(games[at])) left--;
    }
    return games[at];
  }

  bool _found(CheckedGame checked) =>
      _query.isEmpty || matchesSearch(checked, _query);

  /// A pane showing the book is up: read the games and the books now, and
  /// again whenever either changes while it is.
  void watch() {
    if (_watching++ == 0) unawaited(_read());
  }

  void unwatch() {
    if (_watching > 0 && --_watching == 0) _reads++;
  }

  /// New games were saved, the usernames changed or a repertoire file was
  /// written: read again now if a pane is up, else when one comes up.
  void recheck() {
    if (_watching > 0) unawaited(_read());
  }

  /// A catalog publication only changes the comparison when one of the
  /// selected book's native inputs changed (or the user explicitly refreshed).
  void repertoiresChanged(List<DocumentChange> changes, {required bool all}) {
    final inputs = _books.inputs(_books.active);
    if (all || changes.any((change) => inputs.any(change.touches))) recheck();
  }

  /// Refreshes the persisted selection too: an external book-file change can
  /// invalidate a comparison while the local membership owner is unchanged.
  Future<void> retry() async {
    if (_disposed) return;
    final reads = _reads;
    _books.canRetry ? await _books.retry() : await _books.load();
    // Load notifications already start the current comparison when observed.
    if (!_disposed && _reads == reads) recheck();
  }

  /// Another book is in use, or the one in use was edited.
  void _bookChanged() {
    final inputs = _bookInput;
    if (inputs == _bookSeen) return;
    _bookSeen = inputs;
    recheck();
  }

  Future<void> _read() async {
    final ticket = ++_reads;
    bool overtaken() => _disposed || ticket != _reads || _watching == 0;
    final book = _books.active;
    _bookSeen = _bookInput;
    try {
      if (book == null) return _become(const BookNotSet());
      final accountRead = await _accounts.snapshot();
      if (overtaken()) return;
      if (accountRead is AccountsUnavailable) {
        throw StateError(accountRead.detail);
      }
      final accounts = (accountRead as AccountsSnapshot).accounts;
      if (accounts.isEmpty) return _become(const BookNoAccounts());
      final corpus = await _readCorpus(accounts, overtaken);
      if (corpus == null || overtaken()) return;
      _shelf.forget();
      await _shelf.read(gone: overtaken);
      if (overtaken()) return;
      _become(_checked(corpus, book));
    } on Object catch (error) {
      if (overtaken()) return;
      _problem = '$error';
      log.w('compare downloaded games with the repertoire', error);
      notifyListeners();
    }
  }

  /// The newest saved games of each account, or null when overtaken.
  Future<List<(ChapterRef, GameSite, PlayedGame)>?> _readCorpus(
    Map<GameSite, Account> accounts,
    bool Function() overtaken,
  ) async {
    final played = <(ChapterRef, GameSite, PlayedGame)>[];
    for (final MapEntry(key: site, value: account) in accounts.entries) {
      final saved = await _cache.snapshotNewest(
        site,
        account.username,
        max: bookCheckWindow,
      );
      if (overtaken()) return null;
      if (saved is CachedGamesUnavailable) throw StateError(saved.detail);
      final snapshot = saved as CachedGamesSnapshot;
      final file = ChapterRef.at(snapshot.ref.path);
      for (final game in await _readGames(snapshot.games, account.username)) {
        played.add((file, site, game));
      }
      if (overtaken()) return null;
    }
    return played;
  }

  BookChecked _checked(
    List<(ChapterRef, GameSite, PlayedGame)> played,
    Book selected,
  ) {
    final books = [
      for (final ref in _shelf.refs)
        if (_books.contains(selected, ref))
          if (_shelf.indexOf(ref) case final index?)
            BookFile(
              path: ref.path,
              section: ref.section,
              name: ref.name,
              index: index,
            ),
    ];
    final games = [
      for (final (file, site, game) in played)
        CheckedGame(
          file: file,
          site: site,
          game: game,
          verdict: checkGame(game, books),
        ),
    ]..sort((a, b) => b.game.playedAt.compareTo(a.game.playedAt));
    return BookChecked(games: List.unmodifiable(games), ways: _ways(games));
  }

  /// The games that left the book, grouped by how, the most games first
  /// and then the most recent.
  static List<SameWay> _ways(List<CheckedGame> newestFirst) {
    final byWay = <String, List<CheckedGame>>{};
    for (final checked in newestFirst) {
      if (checked.verdict case final LeftBook left) {
        (byWay[left.sameWay] ??= []).add(checked);
      }
    }
    final ways = [for (final games in byWay.values) SameWay(games)];
    // Stable after the sort by size, so a tie keeps the newest first.
    mergeSort(ways, compare: (a, b) => b.games.length - a.games.length);
    return List.unmodifiable(ways);
  }

  void _become(BookState state) {
    if (_disposed) return;
    _state = state;
    _problem = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _books.removeListener(_bookChanged);
    super.dispose();
  }
}

/// The chapter a book file is, to open it at a [BookPlace]: a chapter of a
/// course file is its games in that file, not the whole file.
extension BookFileRef on BookFile {
  ChapterRef get ref => ChapterRef.at(path, section: section);
}

/// [saved] read as [username]'s games, the ones that are not theirs left
/// out; off the calling isolate when there is enough text to be worth it.
Future<List<PlayedGame>> _readGames(List<CachedGame> saved, String username) {
  List<PlayedGame> read() => [
    for (final game in saved)
      ?readPlayedGame(game.text, index: game.index, username: username),
  ];
  final size = saved.fold(0, (sum, game) => sum + game.text.length);
  return size < readOffThreadFrom ? Future.value(read()) : Isolate.run(read);
}
