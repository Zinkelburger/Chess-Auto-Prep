import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../chess/book/book_check.dart';
import '../../chess/book/played_game.dart';
import '../../chess/pgn/chapter.dart' show readOffThreadFrom;
import '../../chess/tactics/game_ids.dart';
import '../../storage/chapter_files.dart';
import '../../storage/my_accounts.dart';
import '../../storage/my_games_files.dart';
import '../../workspace/repertoire_shelf.dart';

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

/// The user's own games read against their repertoires: for each saved
/// game of their accounts, the newest [bookCheckWindow] of each, where it
/// left the book and how; and across them, the places it keeps happening.
///
/// It reads only while a pane showing it is up ([watch]): opening the mode
/// reads the games and the books again, and so does a download or a change
/// to the repertoires while it is open. A later read overtakes an earlier
/// one, whose result is dropped.
final class GameBook extends ChangeNotifier {
  GameBook({
    required AccountStore accounts,
    required GamesCache cache,
    required RepertoireShelf shelf,
  }) : _accounts = accounts,
       _cache = cache,
       _shelf = shelf;

  final AccountStore _accounts;
  final GamesCache _cache;
  final RepertoireShelf _shelf;

  BookState _state = const BookReading();
  int _reads = 0;
  int _watching = 0;
  bool _disposed = false;

  BookState get state => _state;

  /// The checked game [file] holds at [game], or null when it is not one.
  CheckedGame? find(ChapterRef? file, int? game) {
    final state = _state;
    if (state is! BookChecked || file == null || game == null) return null;
    for (final checked in state.games) {
      if (checked.file == file && checked.game.index == game) return checked;
    }
    return null;
  }

  /// A pane showing the book is up: read the games and the books now, and
  /// again whenever either changes while it is.
  void watch() {
    if (_watching++ == 0) unawaited(_read());
  }

  void unwatch() {
    if (_watching > 0) _watching--;
  }

  /// New games were saved, the usernames changed or a repertoire file was
  /// written: read again now if a pane is up, else when one comes up.
  void recheck() {
    if (_watching > 0) unawaited(_read());
  }

  Future<void> _read() async {
    final ticket = ++_reads;
    bool overtaken() => _disposed || ticket != _reads;
    final accounts = await _accounts.read();
    if (overtaken()) return;
    if (accounts.isEmpty) return _become(const BookNoAccounts());
    final played = <(ChapterRef, GameSite, PlayedGame)>[];
    for (final MapEntry(key: site, value: account) in accounts.entries) {
      final saved = await _cache.newest(
        site,
        account.username,
        max: bookCheckWindow,
      );
      if (overtaken()) return;
      final file = ChapterRef.at(_cache.refFor(site, account.username).path);
      for (final game in await _readGames(saved ?? [], account.username)) {
        played.add((file, site, game));
      }
      if (overtaken()) return;
    }
    _shelf.forget();
    await _shelf.read(gone: overtaken);
    if (overtaken()) return;
    _become(_checked(played));
  }

  BookChecked _checked(List<(ChapterRef, GameSite, PlayedGame)> played) {
    final books = [
      for (final ref in _shelf.refs)
        if (_shelf.indexOf(ref) case final index?)
          BookFile(path: ref.path, name: ref.name, index: index),
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
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
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
