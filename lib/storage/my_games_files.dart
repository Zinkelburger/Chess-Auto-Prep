import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../chess/pgn/chapter.dart' show readOffThreadFrom;
import '../chess/pgn/game_text.dart';
import '../chess/pgn/games_written.dart';
import '../chess/tactics/game_ids.dart';
import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'disk_usage.dart' show deleteDerivedFile;
import 'document_ref.dart';
import 'edit_scope.dart';
import 'file_lock.dart';
import 'pgn_document_store.dart';
import 'recovery_files.dart';

/// The files the review of the user's games shares with the old app.

/// How many of an account's newest saved games the book check reads, and
/// how many a download asks for while fewer than that are saved: the old
/// app's `Games per site to check against my repertoires`.
const bookCheckWindow = 200;

/// A saved game and where it is in its file, counting from zero.
typedef CachedGame = ({int index, String text});

/// A corpus read and the exact file version it came from. An absent
/// file is a successful empty input whose absence must still be validated.
sealed class CachedGamesRead {
  const CachedGamesRead();
}

final class CachedGamesSnapshot extends CachedGamesRead {
  CachedGamesSnapshot({
    required this.ref,
    required this.revision,
    required List<CachedGame> games,
  }) : games = List.unmodifiable(games);
  final DocumentRef ref;
  final Revision? revision;
  final List<CachedGame> games;
}

final class CachedGamesUnavailable extends CachedGamesRead {
  const CachedGamesUnavailable(this.detail);
  final String detail;
}

/// The corpus and its fetched note have both been acknowledged.
sealed class GamesKeep {
  const GamesKeep();
}

final class GamesKept extends GamesKeep {
  const GamesKept();
}

final class GamesNotKept extends GamesKeep {
  const GamesNotKept(this.detail);
  final String detail;
}

sealed class GamesDiscard {
  const GamesDiscard();
}

final class GamesDiscarded extends GamesDiscard {
  const GamesDiscarded(this.recoveredTo);

  /// Where the file went, or null when there was none.
  final String? recoveredTo;
}

final class GamesNotDiscarded extends GamesDiscard {
  const GamesNotDiscarded(this.detail);
  final String detail;
}

/// The ids of the games one saved file holds and the version of the file
/// they were read from: what a caller keeps so the next [GamesCache.lookUp]
/// of a game the file did not hold answers without parsing it again.
typedef SavedIds = ({Revision revision, Set<String> ids});

sealed class GameLookup {
  const GameLookup();
}

final class SavedGameFound extends GameLookup {
  const SavedGameFound(this.text, this.ids);
  final String text;
  final SavedIds ids;
}

/// The file does not hold the game; [ids] is null when there is no file.
final class SavedGameMissing extends GameLookup {
  const SavedGameMissing(this.ids);
  final SavedIds? ids;
}

final class SavedGameUnreadable extends GameLookup {
  const SavedGameUnreadable(this.detail);
  final String detail;
}

/// The user's downloaded games, one PGN per site and username under
/// `Documents/games_library/` — `lichess_bob.pgn`, `chesscom_bob.pgn` —
/// with a `.fetched` file beside it saying when they came down. The old
/// app's cache, read by its PGN Viewer and Player analysis; a download that
/// does not happen is answered from it however old it is.
final class GamesCache {
  GamesCache(this._store, {required this.folder});

  final PgnDocumentStore _store;

  /// `Documents/games_library`.
  final String folder;

  DocumentRef refFor(GameSite site, String username) {
    final key = username.trim().toLowerCase().replaceAll(
      RegExp('[^a-z0-9_-]'),
      '_',
    );
    return DocumentRef(p.join(folder, '${site.name}_$key.pgn'));
  }

  /// Reads a frozen corpus input without conflating unavailable and absent:
  /// the newest [max] games, of the time controls [speeds] lets through
  /// when it is given.
  Future<CachedGamesRead> snapshotNewest(
    GameSite site,
    String username, {
    required int max,
    Set<GameSpeed>? speeds,
  }) => _snapshot(site, username, max: max, speeds: speeds);

  /// Every saved game, in file order, with the same exact native proof used
  /// by the bounded book check. Absence remains distinct from an unreadable file.
  Future<CachedGamesRead> snapshotAll(GameSite site, String username) =>
      _snapshot(site, username);

  Future<CachedGamesRead> _snapshot(
    GameSite site,
    String username, {
    int? max,
    Set<GameSpeed>? speeds,
  }) async {
    final ref = refFor(site, username);
    try {
      switch (await _store.open(ref)) {
        case Opened(:final text, :final revision):
          return CachedGamesSnapshot(
            ref: ref,
            revision: revision,
            games: max == null
                ? [
                    for (final (index, game) in (await _gamesOf(text)).indexed)
                      (index: index, text: game),
                  ]
                : await _newestOf(text, max, speeds),
          );
        case Absent():
          return CachedGamesSnapshot(ref: ref, revision: null, games: const []);
        case Unreadable(:final detail):
          return CachedGamesUnavailable(detail);
      }
    } on Object catch (error) {
      return CachedGamesUnavailable('$error');
    }
  }

  /// The newest [max] games saved for [username], newest first, or null
  /// when there are none or the file cannot be read.
  Future<List<String>?> read(
    GameSite site,
    String username, {
    required int max,
  }) async {
    final games = await newest(site, username, max: max);
    return games == null ? null : [for (final game in games) game.text];
  }

  /// The same games with where each is in the file, counting from zero, so
  /// one can be opened there.
  Future<List<CachedGame>?> newest(
    GameSite site,
    String username, {
    required int max,
  }) async {
    final text = await _textOf(site, username);
    if (text == null) return null;
    final games = await _newestOf(text, max);
    return games.isEmpty ? null : games;
  }

  /// The saved game of [username] whose id ([gameIdIn]) is [id]. [known]
  /// is what an earlier lookup of this file answered: while the file is
  /// still that version, a game it did not hold is missing without the file
  /// being parsed again.
  Future<GameLookup> lookUp(
    GameSite site,
    String username,
    String id, {
    SavedIds? known,
  }) async {
    try {
      switch (await _store.open(refFor(site, username))) {
        case Absent():
          return const SavedGameMissing(null);
        case Unreadable(:final detail):
          return SavedGameUnreadable(detail);
        case Opened(:final text, :final revision):
          if (known != null &&
              known.revision == revision &&
              !known.ids.contains(id)) {
            return SavedGameMissing(known);
          }
          final (ids, found) = await _offThread(text, () => _findIn(text, id));
          final read = (revision: revision, ids: ids);
          return found == null
              ? SavedGameMissing(read)
              : SavedGameFound(found, read);
      }
    } on Object catch (error) {
      return SavedGameUnreadable('$error');
    }
  }

  /// Every game saved for [username], in the order the file has them, or
  /// null when there is no file or it cannot be read.
  Future<List<String>?> all(GameSite site, String username) async {
    final text = await _textOf(site, username);
    return text == null ? null : _gamesOf(text);
  }

  Future<String?> _textOf(GameSite site, String username) async {
    final read = await _store.open(refFor(site, username));
    if (read is Unreadable) {
      log.w('read the ${site.label} games of $username', read.detail);
    }
    return read is Opened ? read.text : null;
  }

  /// Publishes deduplicated games before their freshness note. Failures keep
  /// the downloaded input with the caller for exact retry, including lost acks.
  /// Another download of the same account landing first is merged with, up
  /// to [_keepAttempts] times: the merge skips games the file has, so doing
  /// it again adds nothing twice.
  Future<GamesKeep> keep(
    GameSite site,
    String username,
    List<String> downloaded,
    DateTime when,
  ) async {
    final frozen = List<String>.unmodifiable(downloaded);
    final ref = refFor(site, username);
    try {
      for (var attempt = 1; ; attempt++) {
        final read = await _store.open(ref);
        final _Attempt outcome = switch (read) {
          Absent() => _created(
            await _store.create(ref, '${_freshIn('', frozen).join('\n\n')}\n'),
          ),
          Opened(readOnly: null, :final text, :final revision) =>
            await _appended(ref, text, revision, frozen),
          Opened(:final readOnly?) => (raced: false, failure: readOnly),
          Unreadable(:final detail) => (raced: false, failure: detail),
        };
        if (outcome.raced && attempt < _keepAttempts) continue;
        if (outcome.failure case final failure?) return GamesNotKept(failure);
        break;
      }
      await _stamp(ref, when);
      return const GamesKept();
    } on Object catch (error) {
      log.w('keep the ${site.label} games of $username', error);
      return GamesNotKept('$error');
    }
  }

  static const _keepAttempts = 3;

  Future<_Attempt> _appended(
    DocumentRef ref,
    String text,
    Revision revision,
    List<String> downloaded,
  ) async {
    final fresh = await freshGamesOf(text, downloaded);
    if (fresh.isEmpty) return _done;
    final base = text.trimRight();
    final joined = fresh.join('\n\n');
    final saved = await _store.save(
      ref,
      base.isEmpty ? '$joined\n' : '$base\n\n$joined\n',
      expected: revision,
      scope: GamesEdited(GamesWritten(appended: fresh.length)),
    );
    return switch (saved) {
      Saved() => _done,
      Conflict() => (
        raced: true,
        failure: 'the file changed while it was read',
      ),
      SaveDidNotLand(:final detail) => (raced: false, failure: detail),
    };
  }

  static _Attempt _created(CreateResult created) => switch (created) {
    Created() => _done,
    Collision() => (
      raced: true,
      failure: 'the file appeared while it was read',
    ),
    IoFailure(:final detail) => (raced: false, failure: detail),
  };

  /// When [username]'s games last came down, from the `.fetched` note, or
  /// null when there is none or it cannot be read: freshness is a hint.
  Future<DateTime?> fetchedAt(GameSite site, String username) async {
    final file = File('${refFor(site, username).path}.fetched');
    try {
      if (!await file.exists()) return null;
      final ms = int.tryParse((await file.readAsString()).trim());
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } on Object catch (error) {
      log.w('read when the ${site.label} games of $username came down', error);
      return null;
    }
  }

  /// Moves [username]'s downloaded games into the recovery folder, where a
  /// deleted chapter goes, and drops their `.fetched` note. The next
  /// download starts a new file. Nothing to delete is a success.
  Future<GamesDiscard> discard(GameSite site, String username) async {
    final ref = refFor(site, username);
    try {
      final String? recoveredTo;
      switch (await _store.open(ref)) {
        case Absent():
          recoveredTo = null;
        case Opened(:final revision):
          switch (await _store.delete(ref, expected: revision)) {
            case Deleted(recoveredTo: final path):
              recoveredTo = path;
            case Conflict():
              return const GamesNotDiscarded('the file changed while deleting');
            case IoFailure(:final detail):
              return GamesNotDiscarded(detail);
          }
        case Unreadable(:final detail):
          return GamesNotDiscarded(detail);
      }
      final note = '${ref.path}.fetched';
      if (await File(note).exists()) {
        final problem = await withDirectoryLock(
          Directory(p.dirname(ref.path)),
          () => deleteDerivedFile(note),
        );
        if (problem != null) return GamesNotDiscarded(problem);
      }
      return GamesDiscarded(recoveredTo);
    } on Object catch (error) {
      log.w('delete the ${site.label} games of $username', error);
      return GamesNotDiscarded('$error');
    }
  }

  /// The old app's `.fetched` note: milliseconds since the epoch.
  Future<void> _stamp(DocumentRef ref, DateTime when) =>
      withDirectoryLock(Directory(p.dirname(ref.path)), () async {
        final path = '${ref.path}.fetched';
        await discardLeftoverStage(path);
        await replaceFile(path, utf8.encode('${when.millisecondsSinceEpoch}'));
      });
}

/// One try at publishing downloaded games: [failure] is null when they
/// landed, and [raced] says another writer changed the file in between.
typedef _Attempt = ({bool raced, String? failure});

const _Attempt _done = (raced: false, failure: null);

// What reads every game of a saved file. The file grows with every
// download, to megabytes the window would wait for; so from
// [readOffThreadFrom] characters on, the work goes to another isolate, with
// nothing but the text in hand.

Future<List<String>> _gamesOf(String text) =>
    _offThread(text, () => _gamesIn(text));

Future<List<CachedGame>> _newestOf(
  String text,
  int max, [
  Set<GameSpeed>? speeds,
]) => _offThread(text, () => _newestIn(text, max, speeds));

/// The games of [downloaded] that [text] does not have yet, each once, by
/// site id or else exact text; worked out off the UI isolate for big files.
Future<List<String>> freshGamesOf(String text, List<String> downloaded) =>
    _offThread(text, () => _freshIn(text, downloaded));

Future<T> _offThread<T>(String text, T Function() work) =>
    text.length < readOffThreadFrom ? Future.value(work()) : Isolate.run(work);

List<String> _gamesIn(String text) => [
  for (final game in splitChapterText(text).games) game.text,
];

/// The ids of the games of [text], and the game whose id is [id].
(Set<String>, String?) _findIn(String text, String id) {
  final ids = <String>{};
  String? found;
  for (final game in _gamesIn(text)) {
    final gameId = gameIdIn(game);
    if (gameId.isEmpty) continue;
    ids.add(gameId);
    if (gameId == id) found ??= game;
  }
  return (ids, found);
}

/// The newest [max] games of [text] that [speeds] lets through (all of
/// them when null), newest first. Stable, so games that do not say when
/// they were played keep the order the file has them in.
List<CachedGame> _newestIn(String text, int max, [Set<GameSpeed>? speeds]) {
  final games = _gamesIn(text);
  final order =
      [
        for (final (i, g) in games.indexed)
          if (speeds == null || keepsSpeed(speeds, g)) (i, playedAt(g)),
      ]..sort((a, b) {
        final byTime = b.$2.compareTo(a.$2);
        return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
      });
  return [for (final (i, _) in order.take(max)) (index: i, text: games[i])];
}

/// The games of [downloaded] that [text] does not have yet, each once.
List<String> _freshIn(String text, List<String> downloaded) {
  final have = {for (final game in _gamesIn(text)) _identityOf(game)};
  return [
    for (final game in downloaded)
      if (have.add(_identityOf(game))) game,
  ];
}

// Missing metadata must not collapse unrelated downloaded games into one.
(String, String) _identityOf(String game) {
  final id = gameIdIn(game);
  return id.isEmpty ? ('text', game.trim()) : ('id', id);
}

/// The ids of games the old app reviewed before its sets carried their own
/// analysed-games line: `Documents/analyzed_games.txt`, one per line. It
/// goes on reading them beside the line, so both apps count them as done.
/// A missing file is none; null when the file is there and cannot be read,
/// which is no answer: every game it names would be mined again.
Future<Set<String>?> readOlderAnalyzed(Directory documents) async {
  final file = File(p.join(documents.path, 'analyzed_games.txt'));
  try {
    if (!await file.exists()) return {};
    return {
      for (final id in const LineSplitter().convert(await file.readAsString()))
        if (id.trim().isNotEmpty) id.trim(),
    };
  } on Object catch (error) {
    log.w('read ${file.path}', error);
    return null;
  }
}
