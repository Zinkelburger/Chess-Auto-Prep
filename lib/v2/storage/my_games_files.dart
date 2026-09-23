import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../chess/pgn/game_text.dart';
import '../chess/pgn/games_written.dart';
import '../chess/tactics/game_ids.dart';
import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'document_ref.dart';
import 'edit_scope.dart';
import 'file_lock.dart';
import 'pgn_document_store.dart';

/// The files the review of the user's games shares with the old app.

/// How many of an account's newest saved games the book check reads, and
/// how many a download asks for while fewer than that are saved: the old
/// app's `Games per site to check against my repertoires`.
const bookCheckWindow = 200;

/// A saved game and where it is in its file, counting from zero.
typedef CachedGame = ({int index, String text});

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
    final read = await _store.open(refFor(site, username));
    if (read is! Opened) return null;
    final games = [
      for (final game in splitChapterText(read.text).games) game.text,
    ];
    if (games.isEmpty) return null;
    // Stable, so games that do not say when they were played keep the
    // order the file has them in.
    final order = [for (final (i, g) in games.indexed) (i, playedAt(g))]
      ..sort((a, b) {
        final byTime = b.$2.compareTo(a.$2);
        return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
      });
    return [for (final (i, _) in order.take(max)) (index: i, text: games[i])];
  }

  /// Adds the games of [downloaded] the file does not have yet at its end,
  /// as the old app does, and notes when they came down. Never throws: the
  /// games are in hand either way, and the log says what went wrong.
  Future<void> keep(
    GameSite site,
    String username,
    List<String> downloaded,
    DateTime when,
  ) async {
    final ref = refFor(site, username);
    final read = await _store.open(ref);
    final String? outcome = switch (read) {
      Absent() => _created(
        await _store.create(ref, '${downloaded.join('\n\n')}\n'),
      ),
      Opened(readOnly: null, :final text, :final revision) => await _appended(
        ref,
        text,
        revision,
        downloaded,
      ),
      Opened(:final readOnly?) => readOnly,
      Unreadable(:final detail) => detail,
    };
    if (outcome != null) {
      log.w('keep the ${site.label} games of $username', outcome);
      return;
    }
    await _stamp(ref, when);
  }

  Future<String?> _appended(
    DocumentRef ref,
    String text,
    Revision revision,
    List<String> downloaded,
  ) async {
    final have = {
      for (final game in splitChapterText(text).games) gameIdIn(game.text),
    };
    final fresh = [
      for (final game in downloaded)
        if (have.add(gameIdIn(game))) game,
    ];
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
  Future<void> _stamp(DocumentRef ref, DateTime when) async {
    try {
      await withDirectoryLock(
        Directory(p.dirname(ref.path)),
        () => replaceFile(
          '${ref.path}.fetched',
          utf8.encode('${when.millisecondsSinceEpoch}'),
        ),
      );
    } on Object catch (error) {
      log.w('note when ${ref.path} came down', error);
    }
  }
}

/// The ids of games the old app reviewed before its sets carried their own
/// analysed-games line: `Documents/analyzed_games.txt`, one per line. It
/// goes on reading them beside the line, so both apps count them as done.
/// A missing file is none.
Future<Set<String>> readOlderAnalyzed(Directory documents) async {
  final file = File(p.join(documents.path, 'analyzed_games.txt'));
  try {
    if (!await file.exists()) return {};
    return {
      for (final id in const LineSplitter().convert(await file.readAsString()))
        if (id.trim().isNotEmpty) id.trim(),
    };
  } on Object catch (error) {
    log.w('read ${file.path}', error);
    return {};
  }
}
