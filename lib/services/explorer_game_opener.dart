/// Opening a game the explorer listed, the way lila does when you click one:
/// the game lands in the viewer at the position you were looking at.
///
/// The three sources hand over their games differently — the local database
/// has the movetext on disk, Lichess serves a PGN per id from two endpoints —
/// so this fetches whichever it is and writes it into one ordinary PGN
/// collection, `explorer-games.pgn`, which the viewer opens like any other
/// file.  Games accumulate there rather than each getting a file of its own:
/// the collection becomes "what I looked at from the explorer", browsable
/// with the viewer's game bar, and a game opened twice is found rather than
/// appended again.
library;

import 'dart:io';

import 'package:dartchess/dartchess.dart' show Chess;
import 'package:path/path.dart' as p;

import '../models/explorer_response.dart';
import '../utils/atomic_file.dart';
import '../utils/chess_utils.dart' show plyReachingFen;
import 'lichess_api_client.dart';
import '../chess_core/pgn/mainline_lexer.dart' show mainlineSansOf;
import 'master_games/master_games_db.dart';
import 'master_games/master_games_service.dart';
import 'storage/app_paths.dart';

/// Where an explorer game ended up: the collection file, the game's index
/// in it, and the ply at which it reaches the position it was opened from
/// (null when it gets there by a route the mainline does not show).
class OpenedExplorerGame {
  const OpenedExplorerGame({
    required this.path,
    required this.index,
    required this.ply,
    required this.label,
  });

  final String path;
  final int index;
  final int? ply;

  /// "Carlsen – Nakamura", for the breadcrumb.
  final String label;
}

class ExplorerGameOpener {
  ExplorerGameOpener({
    LichessApiClient? client,
    MasterGamesDb? Function()? localDb,
    Future<Directory> Function()? collectionsDirectory,
  }) : _client = client ?? LichessApiClient.instance,
       _localDb = localDb ?? (() => MasterGamesService.instance.db),
       _collectionsDirectory =
           collectionsDirectory ??
           (() => AppPaths.pgnCollectionsDirectory(create: true));

  /// The collection every explorer game is written to.
  static const String collectionName = 'explorer-games.pgn';

  /// Games start at a `[Event` tag that follows a blank line (or the file
  /// start); splitting there keeps each game's headers and moves together.
  static final RegExp _gameBoundary = RegExp(r'\n\s*\n(?=\[Event )');

  final LichessApiClient _client;
  final MasterGamesDb? Function() _localDb;
  final Future<Directory> Function() _collectionsDirectory;

  /// Fetch [game]'s PGN, put it in the collection, and say where it is.
  /// Null when the source could not supply the game.
  ///
  /// [fen] is the position the game was listed for; the result's ply is
  /// where the game's mainline first reaches it.
  Future<OpenedExplorerGame?> open(
    ExplorerGame game, {
    required String fen,
  }) async {
    final pgn = await fetchPgn(game);
    if (pgn == null) return null;

    final dir = await _collectionsDirectory();
    final file = File(p.join(dir.path, collectionName));
    final index = await _indexInCollection(file, _normalize(pgn));

    final ply = plyReachingFen(
      mainlineSansOf(pgn),
      fen,
      startFen: Chess.initial.fen,
    );
    return OpenedExplorerGame(
      path: file.path,
      index: index,
      ply: ply < 0 ? null : ply,
      label: '${_surname(game.white)} – ${_surname(game.black)}',
    );
  }

  /// Fetch a reference PGN without adding it to a collection.
  Future<String?> fetchPgn(ExplorerGame game) async => switch (game.source) {
    ExplorerGameSource.twic => _localPgn(game.id),
    ExplorerGameSource.masters => _client.fetchGamePgn(game.id, masters: true),
    ExplorerGameSource.lichess => _client.fetchGamePgn(game.id, masters: false),
  };

  String? _localPgn(String gameId) {
    final id = int.tryParse(gameId);
    final db = _localDb();
    if (id == null || db == null) return null;
    return db.game(id)?.toPgn();
  }

  /// The game's index in [file], appending it when it is not there yet.
  Future<int> _indexInCollection(File file, String normalizedPgn) async {
    final existing = await file.exists() ? await file.readAsString() : '';
    final blocks = _splitGames(existing);
    final found = blocks.indexOf(normalizedPgn);
    if (found >= 0) return found;
    blocks.add(normalizedPgn);
    await writeTextFileAtomically(file, '${blocks.join('\n\n')}\n');
    return blocks.length - 1;
  }

  /// One game per block, as the file stores them, so an existing copy is
  /// recognised by its text.
  static List<String> _splitGames(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return [];
    return [for (final part in trimmed.split(_gameBoundary)) _normalize(part)];
  }

  static String _normalize(String pgn) => pgn.trim().replaceAll('\r\n', '\n');

  static String _surname(String name) {
    final comma = name.indexOf(',');
    return (comma <= 0 ? name : name.substring(0, comma)).trim();
  }
}
