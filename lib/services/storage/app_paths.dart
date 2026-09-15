import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Shared application directories and file-path helpers.
class AppPaths {
  static const String repertoiresDirectoryName = 'repertoires';
  static const String analysisGamesDirectoryName = 'analysis_games';
  static const String pgnCollectionsDirectoryName = 'pgn_collections';
  static const String gamesLibraryDirectoryName = 'games_library';
  static const String tacticsSetsDirectoryName = 'tactics_sets';
  static const String studiesDirectoryName = 'studies';
  static const String chessgamesCacheDirectoryName = 'chessgames_pgn_cache';
  static const String engineTournamentsDirectoryName = 'engine_tournaments';
  static const String opponentsDirectoryName = 'opponents';

  static Future<Directory> documentsDirectory() =>
      getApplicationDocumentsDirectory();

  static Future<Directory> supportDirectory() =>
      getApplicationSupportDirectory();

  /// Disposable downloads belong in local cache (not Windows roaming data).
  static Future<Directory> cacheDirectory() => getApplicationCacheDirectory();

  static Future<File> documentsFile(String relativePath) async {
    final docs = await documentsDirectory();
    return File(p.join(docs.path, relativePath));
  }

  /// `<base>/<name>`, created (with parents) when [create] is set.
  static Future<Directory> _subdirectory(
    Future<Directory> base,
    String name, {
    required bool create,
  }) async {
    final dir = Directory(p.join((await base).path, name));
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> repertoiresDirectory({bool create = false}) =>
      _subdirectory(
        documentsDirectory(),
        repertoiresDirectoryName,
        create: create,
      );

  /// Local studies (one multi-chapter PGN per study).
  static Future<Directory> studiesDirectory({bool create = false}) =>
      _subdirectory(documentsDirectory(), studiesDirectoryName, create: create);

  /// Named tactics puzzle sets (one PGN per set; legacy installs still hold
  /// `.csv` sets until the database converts them).
  static Future<Directory> tacticsSetsDirectory({bool create = false}) =>
      _subdirectory(
        documentsDirectory(),
        tacticsSetsDirectoryName,
        create: create,
      );

  /// The opponents directory and tournaments (`people.json`,
  /// `tournaments/*.json`) — see `features/opponents`.
  static Future<Directory> opponentsDirectory({bool create = false}) =>
      _subdirectory(
        documentsDirectory(),
        opponentsDirectoryName,
        create: create,
      );

  static Future<Directory> analysisGamesDirectory({bool create = false}) =>
      _subdirectory(
        documentsDirectory(),
        analysisGamesDirectoryName,
        create: create,
      );

  /// Shared raw-games cache used by the unified Games library (tactics,
  /// weakness finder, repertoire builder all read from here).
  static Future<Directory> gamesLibraryDirectory({bool create = false}) =>
      _subdirectory(
        documentsDirectory(),
        gamesLibraryDirectoryName,
        create: create,
      );

  /// Per-game PGN cache for chessgames.com collection downloads.
  ///
  /// Lives in the support directory because it is a cache, not user data: a
  /// collection is paced at ~22 s per game, so caching every game is what
  /// makes a cancelled or crashed download resumable instead of a restart
  /// from zero.
  static Future<Directory> chessgamesCacheDirectory({bool create = false}) =>
      _subdirectory(
        supportDirectory(),
        chessgamesCacheDirectoryName,
        create: create,
      );

  /// Engine-vs-engine tournaments: one sub-directory each, plus the
  /// registry of user-supplied UCI binaries (`engines.json`).
  static Future<Directory> engineTournamentsDirectory({bool create = false}) =>
      _subdirectory(
        documentsDirectory(),
        engineTournamentsDirectoryName,
        create: create,
      );

  static Future<Directory> pgnCollectionsDirectory({bool create = false}) =>
      _subdirectory(
        documentsDirectory(),
        pgnCollectionsDirectoryName,
        create: create,
      );
}
