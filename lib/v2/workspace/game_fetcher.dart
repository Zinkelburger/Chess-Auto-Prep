import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chess/explorer_answer.dart';
import '../chess/explorer_choice.dart';
import '../storage/chapter_files.dart';
import '../storage/pgn_document_store.dart' as store;
import 'explorer_databases.dart';

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
    required ExplorerDatabases databases,
    required store.PgnDocumentStore documents,
    required String collections,
  }) : _databases = databases,
       _documents = documents,
       _collections = collections;

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
    final pgn = await _databases.gamePgn(game, source);
    if (_disposed) return const GameNotKept('');
    _fetching = null;
    notifyListeners();
    if (pgn == null) return const GameNotKept('Could not fetch that game.');
    final ref = ChapterRef.at(
      p.join(
        _collections,
        'explorer games',
        '${gameFileName(game, source)}.pgn',
      ),
    );
    return switch (await _documents.create(ref, pgn)) {
      store.Created() || store.Collision() => GameKept(ref, ply: ply),
      store.IoFailure(:final detail) => GameNotKept(
        'Could not keep that game: $detail',
      ),
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
String gameFileName(ExplorerGame game, ExplorerSource source) {
  final year = game.year == null ? '' : ' ${game.year}';
  final raw = '${game.white} - ${game.black}$year (${source.name} ${game.id})';
  final safe = raw.replaceAll(_unsafeInAName, '_').trim();
  return safe.length > 100 ? safe.substring(0, 100).trim() : safe;
}
