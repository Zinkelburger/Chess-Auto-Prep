import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/explorer_answer.dart';
import '../../chess/explorer_choice.dart';
import '../../chess/pgn/game_text.dart';
import '../../chess/pgn/pgn_reader.dart';
import '../../chess/pgn/tree_edit.dart';
import '../../diagnostics/log.dart';
import '../../storage/chapter_files.dart';
import '../../storage/pgn_document_store.dart' as store;
import 'explorer.dart';

sealed class GameKeep {
  const GameKeep();
}

/// The game is a file in the collections folder, to open at [ply].
final class GameKept extends GameKeep {
  const GameKept(this.ref, {required this.ply});

  final ChapterRef ref;
  final int ply;
}

final class GameNotKept extends GameKeep {
  const GameNotKept(this.sentence);

  final String sentence;
}

/// The games the explorer lists, fetched and kept as files of their own in
/// the collections folder so the viewer can open them and keep them.
///
/// Owns which game is being fetched, so its row can say so and the others
/// wait. A file already there is opened as it is.
final class GameFetcher extends ChangeNotifier {
  GameFetcher({
    required this._databases,
    required this._documents,
    required this._collections,
  });

  final ExplorerDatabases _databases;
  final store.PgnDocumentStore _documents;

  /// The `pgn_collections` folder, absolute: where fetched games go.
  final String _collections;

  String? _fetching;
  bool _disposed = false;

  /// The game being fetched, by id, while one is.
  String? get fetching => _fetching;

  /// Fetches [game] from [source], the database that listed it, and writes
  /// it into the collections folder, to be opened at [ply].
  Future<GameKeep> keep(
    ExplorerGame game, {
    required ExplorerSource source,
    required int ply,
  }) async {
    _fetching = game.id;
    notifyListeners();
    String? pgn;
    try {
      pgn = await _databases.gamePgn(game, source);
    } on Object catch (error) {
      // Fetching ends either way, or every row would wait on this one.
      log.w('fetch the explorer game ${game.id}', error);
    }
    if (_disposed) return const GameNotKept('');
    _fetching = null;
    notifyListeners();
    if (pgn == null) return const GameNotKept('Could not fetch that game.');
    final name = gameFileName(game, source);
    final ref = _kept(name);
    switch (await _documents.create(ref, pgn)) {
      case store.Created():
        return GameKept(ref, ply: ply);
      case store.IoFailure(:final detail):
        return GameNotKept('Could not keep that game: $detail');
      case store.Collision():
    }
    if (await _isThatGame(ref, pgn)) return GameKept(ref, ply: ply);
    // A database built again gives its ids out afresh, so the file kept
    // under this one can be another game: this one gets a file of its own,
    // named by its moves so opening it again finds the same file.
    final moves = sha256.convert(utf8.encode(_mainline(pgn).join(' ')));
    final other = _kept('$name ${moves.toString().substring(0, 8)}');
    return switch (await _documents.create(other, pgn)) {
      store.Created() || store.Collision() => GameKept(other, ply: ply),
      store.IoFailure(:final detail) => GameNotKept(
        'Could not keep that game: $detail',
      ),
    };
  }

  ChapterRef _kept(String name) =>
      ChapterRef.at(p.join(_collections, 'explorer games', '$name.pgn'));

  /// Whether the file at [ref] holds the game [pgn] is: the same moves as
  /// far as both go, so a kept game the user has played on from, or
  /// written in, is still that game. A file that cannot be read is opened
  /// as it is, where the viewer says what is wrong with it.
  Future<bool> _isThatGame(ChapterRef ref, String pgn) async {
    final String kept;
    switch (await _documents.open(ref)) {
      case store.Opened(:final text):
        kept = text;
      case store.Absent() || store.Unreadable():
        return true;
    }
    final (was, now) = (_mainline(kept), _mainline(pgn));
    final shared = was.length < now.length ? was.length : now.length;
    return listEquals(was.sublist(0, shared), now.sublist(0, shared));
  }

  static List<String> _mainline(String pgn) {
    final game = splitChapterText(pgn).games.firstOrNull?.text ?? pgn;
    return switch (readGame(game).tree) {
      final tree? => mainlineSans(tree),
      null => const [],
    };
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final _unsafeInAName = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

/// `Carlsen, M - Nakamura, H 2024 (masters abcd1234)`: a file name for a
/// fetched game that says who played and where it came from, and that two
/// different games cannot share.
String gameFileName(
  ExplorerGame game,
  ExplorerSource source, {
  String? sourceName,
}) {
  final origin = sourceName ?? source.name;
  final year = game.year == null ? '' : ' ${game.year}';
  final raw = '${game.white} - ${game.black}$year ($origin ${game.id})';
  final safe = raw.replaceAll(_unsafeInAName, '_').trim();
  if (safe.length <= 100) return safe;
  // Hash the unmodified identity: sanitising or truncating an id can collide.
  final identity = sha256.convert(utf8.encode('$origin:${game.id}'));
  return '${safe.substring(0, 33).trim()} ($identity)';
}
