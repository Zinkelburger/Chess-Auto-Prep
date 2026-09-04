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

  /// Its first chapter, "Main" — what an editor opens.
  final String chapterPath;

  /// Lines seeded from imported PGN; 0 for an empty repertoire.
  final int gameCount;
}

/// Create the folder for [name] with a "Main" chapter marked for [color]
/// ('White' or 'Black'), optionally seeded with [pgnContent].
///
/// The caller checks for a name clash first — it has the list on screen and
/// can say so in the form, which is better than a thrown error.
Future<RepertoireCreationResult> createRepertoire({
  required String name,
  required String color,
  String? pgnContent,
  int gameCount = 0,
  DateTime? createdAt,
  StorageService? storage,
}) async {
  final store = storage ?? StorageFactory.instance;
  final dirPath = await store.repertoireDirectoryPath(name);
  final chapterPath = store.chapterFilePath(dirPath, 'Main');
  final stamp = (createdAt ?? DateTime.now()).toString().split('.')[0];
  final header =
      '// Main\n'
      '// Color: $color\n'
      '// Created on $stamp\n\n';

  if (pgnContent != null) {
    await store.writeFile(
      chapterPath,
      '$header$pgnContent\n',
      createOnly: true,
    );
  } else {
    await store.writeFile(chapterPath, header, createOnly: true);
  }

  return RepertoireCreationResult(
    directoryPath: dirPath,
    chapterPath: chapterPath,
    gameCount: pgnContent != null ? gameCount : 0,
  );
}
