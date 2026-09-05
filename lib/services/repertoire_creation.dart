/// Making a repertoire on disk: a folder, and the "Main" chapter inside it.
///
/// A repertoire is a directory of chapter `.pgn` files, and a brand new one is
/// not empty — it holds one chapter with the header that records which colour
/// it is for. That header is what every later reader keys off (the deviation
/// check, the trainer, the audit), so the two places that create repertoires —
/// the repertoire list's Create dialog and the My-repertoires designation
/// panel, which now creates one rather than sending you away to make it — must
/// write exactly the same thing. Hence one function instead of two copies.
library;

import 'repertoire_line_expansion.dart';
import 'storage/storage_factory.dart';
import 'storage/storage_service.dart';

/// Where a newly created repertoire landed.
class RepertoireCreationResult {
  const RepertoireCreationResult({
    required this.directoryPath,
    required this.chapterPath,
    required this.gameCount,
  });

  /// The repertoire folder — what [MyRepertoireSettings] designates.
  final String directoryPath;

  /// Its first (only) chapter — what an editor opens.
  final String chapterPath;

  /// Lines the chapter holds after import, every variation counted as its
  /// own line; 0 for an empty repertoire.
  final int gameCount;
}

/// Create the folder for [name] with one chapter marked for [color]
/// ('White' or 'Black'), optionally seeded with [pgnContent].
///
/// The PGN is written one game per line: a game with bracketed variations
/// becomes one game per variation ([expandVariationsIntoLines]), because
/// every reader of a chapter walks mainlines only. The result reports the
/// count after expansion; [gameCount] is the caller's own count, used only
/// when the content holds no game this app can count.
///
/// The chapter is called "Main" unless [chapterName] says otherwise — an
/// imported file is better off with a chapter named after itself, since that
/// name is what every book verdict on the games list then shows.
///
/// The caller checks for a name clash first — it has the list on screen and
/// can say so in the form, which is better than a thrown error.
Future<RepertoireCreationResult> createRepertoire({
  required String name,
  required String color,
  String? pgnContent,
  int gameCount = 0,
  String chapterName = 'Main',
  DateTime? createdAt,
  StorageService? storage,
}) async {
  final store = storage ?? StorageFactory.instance;
  final dirPath = await store.repertoireDirectoryPath(name);
  final chapterPath = store.chapterFilePath(dirPath, chapterName);
  final stamp = (createdAt ?? DateTime.now()).toString().split('.')[0];
  final header =
      '// $chapterName\n'
      '// Color: $color\n'
      '// Created on $stamp\n\n';

  if (pgnContent == null) {
    await store.writeFile(chapterPath, header, createOnly: true);
    return RepertoireCreationResult(
      directoryPath: dirPath,
      chapterPath: chapterPath,
      gameCount: 0,
    );
  }

  // On this isolate: the expansion only tokenizes (no game is replayed), and
  // the widget tests that drive an import pump fake time, which an isolate's
  // result would never arrive under.
  final expanded = expandVariationsIntoLines(pgnContent);
  await store.writeFile(
    chapterPath,
    '$header${expanded.pgn}\n',
    createOnly: true,
  );
  return RepertoireCreationResult(
    directoryPath: dirPath,
    chapterPath: chapterPath,
    gameCount: expanded.gameCount > 0 ? expanded.gameCount : gameCount,
  );
}
