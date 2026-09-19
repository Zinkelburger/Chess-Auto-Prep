import 'dart:io';

import 'package:path/path.dart' as p;

/// One chapter file on disk.
final class ChapterRef {
  const ChapterRef({
    required this.repertoire,
    required this.name,
    required this.path,
  });

  /// The folder name under `repertoires/`.
  final String repertoire;

  /// The file name without `.pgn`.
  final String name;

  final String path;

  @override
  bool operator ==(Object other) => other is ChapterRef && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// The chapter PGNs under `Documents/repertoires/`: one folder per
/// repertoire, one `.pgn` per chapter, plus index files the app ignores.
///
/// Read-only. Writes arrive with the document store and its lock, so nothing
/// here may ever create or replace a file.
final class ChapterFiles {
  ChapterFiles(this.root);

  /// The `repertoires` directory itself.
  final Directory root;

  Future<List<ChapterRef>> list() async {
    if (!await root.exists()) return const [];
    final refs = <ChapterRef>[];
    await for (final folder in root.list()) {
      if (folder is! Directory) continue;
      await for (final file in folder.list()) {
        if (file is File && p.extension(file.path) == '.pgn') {
          refs.add(
            ChapterRef(
              repertoire: p.basename(folder.path),
              name: p.basenameWithoutExtension(file.path),
              path: file.path,
            ),
          );
        }
      }
    }
    refs.sort(_byRepertoireThenName);
    return List.unmodifiable(refs);
  }

  Future<String> read(ChapterRef ref) => File(ref.path).readAsString();
}

int _byRepertoireThenName(ChapterRef a, ChapterRef b) {
  final byRepertoire = a.repertoire.toLowerCase().compareTo(
    b.repertoire.toLowerCase(),
  );
  if (byRepertoire != 0) return byRepertoire;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
