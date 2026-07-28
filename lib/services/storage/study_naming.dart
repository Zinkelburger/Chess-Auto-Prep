/// Turning a proposed study title into a study file that doesn't exist yet.
///
/// Import sources name themselves — a Lichess study's own name, a
/// chessgames.com collection title — and those names contain characters a
/// filename cannot hold, and may collide with a study already on disk.
library;

import 'storage_factory.dart';

/// Strip the characters a filename cannot hold. Matches the sanitising the
/// Study screen's inline rename does, so typed and imported names agree.
String sanitizeStudyName(String name) {
  final safe = name
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .trim();
  return safe.isEmpty ? 'Imported study' : safe;
}

/// The path for a new study called [name], suffixed `(2)`, `(3)` … until it
/// names a file that does not exist.
///
/// Importing the same source twice never overwrites the earlier copy — the
/// second lands beside it.
Future<({String path, String name})> reserveStudyPath(String name) async {
  final storage = StorageFactory.instance;
  final base = sanitizeStudyName(name);

  var candidate = base;
  var suffix = 2;
  var path = await storage.studyFilePath(candidate);
  while (await storage.fileExists(path)) {
    candidate = '$base ($suffix)';
    suffix++;
    path = await storage.studyFilePath(candidate);
  }
  return (path: path, name: candidate);
}
