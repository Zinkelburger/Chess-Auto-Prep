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

/// A bounded corpus read and the exact file version it came from. An absent
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

  /// Reads a frozen corpus input without conflating unavailable and absent.
  Future<CachedGamesRead> snapshotNewest(
    GameSite site,
    String username, {
    required int max,
  }) async {
    final ref = refFor(site, username);
    try {
      switch (await _store.open(ref)) {
        case Opened(:final text, :final revision):
          return CachedGamesSnapshot(
            ref: ref,
            revision: revision,
            games: await _newestOf(text, max),
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
  Future<GamesKeep> keep(
    GameSite site,
    String username,
    List<String> downloaded,
    DateTime when,
  ) async {
    final frozen = List<String>.unmodifiable(downloaded);
    final ref = refFor(site, username);
    try {
      final read = await _store.open(ref);
      final String? outcome = switch (read) {
        Absent() => _created(
          await _store.create(ref, '${_freshIn('', frozen).join('\n\n')}\n'),
        ),
        Opened(readOnly: null, :final text, :final revision) => await _appended(
          ref,
          text,
          revision,
          frozen,
        ),
        Opened(:final readOnly?) => readOnly,
        Unreadable(:final detail) => detail,
      };
      if (outcome != null) return GamesNotKept(outcome);
      await _stamp(ref, when);
      return const GamesKept();
    } on Object catch (error) {
      log.w('keep the ${site.label} games of $username', error);
      return GamesNotKept('$error');
    }
  }

  Future<String?> _appended(
    DocumentRef ref,
    String text,
    Revision revision,
    List<String> downloaded,
  ) async {
    final fresh = await _freshOf(text, downloaded);
    if (fresh.isEmpty) return null;
    final base = text.trimRight();
    final joined = fresh.join('\n\n');
    final saved = await _store.save(
      ref,
      base.isEmpty ? '$joined\n' : '$base\n\n$joined\n',
      expected: revision,
      scope: GamesEdited(GamesWritten(appended: fresh.length)),
    );
    return switch (saved) {
      Saved() => null,
      Conflict() => 'the file changed while it was read',
      SaveDidNotLand(:final detail) => detail,
    };
  }

  static String? _created(CreateResult created) => switch (created) {
    Created() => null,
    Collision() => 'the file appeared while it was read',
    IoFailure(:final detail) => detail,
  };

  /// The old app's `.fetched` note: milliseconds since the epoch.
  Future<void> _stamp(DocumentRef ref, DateTime when) =>
      withDirectoryLock(Directory(p.dirname(ref.path)), () async {
        final path = '${ref.path}.fetched';
        await requireUnusedRecoveryStage(path);
        await replaceFile(path, utf8.encode('${when.millisecondsSinceEpoch}'));
      });
}

// What reads every game of a saved file. The file grows with every
// download, to megabytes the window would wait for; so from
// [readOffThreadFrom] characters on, the work goes to another isolate, with
// nothing but the text in hand.

Future<List<String>> _gamesOf(String text) =>
    _offThread(text, () => _gamesIn(text));

Future<List<CachedGame>> _newestOf(String text, int max) =>
    _offThread(text, () => _newestIn(text, max));

Future<List<String>> _freshOf(String text, List<String> downloaded) =>
    _offThread(text, () => _freshIn(text, downloaded));

Future<T> _offThread<T>(String text, T Function() work) =>
    text.length < readOffThreadFrom ? Future.value(work()) : Isolate.run(work);

List<String> _gamesIn(String text) => [
  for (final game in splitChapterText(text).games) game.text,
];

/// The newest [max] games of [text], newest first. Stable, so games that
/// do not say when they were played keep the order the file has them in.
List<CachedGame> _newestIn(String text, int max) {
  final games = _gamesIn(text);
  final order = [for (final (i, g) in games.indexed) (i, playedAt(g))]
    ..sort((a, b) {
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
