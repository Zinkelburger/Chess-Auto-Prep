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

  static Future<Directory> documentsDirectory() async {
    return getApplicationDocumentsDirectory();
  }

  static Future<Directory> supportDirectory() async {
    return getApplicationSupportDirectory();
  }

  static Future<File> documentsFile(String relativePath) async {
    final docs = await documentsDirectory();
    return File(p.join(docs.path, relativePath));
  }

  static Future<Directory> repertoiresDirectory({bool create = false}) async {
    final docs = await documentsDirectory();
    final dir = Directory(p.join(docs.path, repertoiresDirectoryName));
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Local studies (one multi-chapter PGN per study).
  static Future<Directory> studiesDirectory({bool create = false}) async {
    final docs = await documentsDirectory();
    final dir = Directory(p.join(docs.path, studiesDirectoryName));
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Named tactics puzzle sets (one CSV per set).
  static Future<Directory> tacticsSetsDirectory({bool create = false}) async {
    final docs = await documentsDirectory();
    final dir = Directory(p.join(docs.path, tacticsSetsDirectoryName));
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> analysisGamesDirectory({bool create = false}) async {
    final docs = await documentsDirectory();
    final dir = Directory(p.join(docs.path, analysisGamesDirectoryName));
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Shared raw-games cache used by the unified Games library (tactics,
  /// weakness finder, repertoire builder all read from here).
  static Future<Directory> gamesLibraryDirectory({bool create = false}) async {
    final docs = await documentsDirectory();
    final dir = Directory(p.join(docs.path, gamesLibraryDirectoryName));
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> pgnCollectionsDirectory({
    bool create = false,
  }) async {
    final docs = await documentsDirectory();
    final dir = Directory(p.join(docs.path, pgnCollectionsDirectoryName));
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
