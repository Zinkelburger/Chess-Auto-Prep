import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Shared application directories and file-path helpers.
class AppPaths {
  static const String repertoiresDirectoryName = 'repertoires';
  static const String analysisGamesDirectoryName = 'analysis_games';
  static const String pgnCollectionsDirectoryName = 'pgn_collections';

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

  static Future<Directory> analysisGamesDirectory({bool create = false}) async {
    final docs = await documentsDirectory();
    final dir = Directory(p.join(docs.path, analysisGamesDirectoryName));
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> pgnCollectionsDirectory({bool create = false}) async {
    final docs = await documentsDirectory();
    final dir = Directory(p.join(docs.path, pgnCollectionsDirectoryName));
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
