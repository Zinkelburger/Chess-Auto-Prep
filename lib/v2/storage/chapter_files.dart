import 'dart:io';

import 'package:path/path.dart' as p;

import 'document_ref.dart';

/// One chapter file on disk: a document, plus the two labels the library list
/// shows. The store takes it as the [DocumentRef] it is.
final class ChapterRef extends DocumentRef {
  const ChapterRef({
    required this.repertoire,
    required this.name,
    required String path,
  }) : super(path);

  /// The folder name under `repertoires/`.
  final String repertoire;

  /// The file name without `.pgn`.
  final String name;
}

sealed class ChapterListing {
  const ChapterListing();
}

final class Chapters extends ChapterListing {
  const Chapters(this.refs);

  final List<ChapterRef> refs;
}

/// The repertoires folder exists but could not be read.
final class ChaptersUnreadable extends ChapterListing {
  const ChaptersUnreadable(this.detail);

  /// The operating system's message, for the log; the UI writes the sentence.
  final String detail;
}

/// The chapter PGNs under `Documents/repertoires/`. The filesystem is a real
/// boundary, so this is an interface: [ChapterDirectory] in the app, a
/// scripted one in tests.
///
/// Listing only: a chapter's text is read, and written, through the
/// document store, which is the one place that knows its revision.
abstract interface class ChapterFiles {
  Future<ChapterListing> list();
}

/// One folder per repertoire, one `.pgn` per chapter, plus index files the
/// app ignores.
final class ChapterDirectory implements ChapterFiles {
  ChapterDirectory(this.root);

  /// The `repertoires` directory itself.
  final Directory root;

  @override
  Future<ChapterListing> list() async {
    if (!await root.exists()) return const Chapters([]);
    try {
      final refs = await _scan();
      refs.sort(_byRepertoireThenName);
      return Chapters(List.unmodifiable(refs));
    } on FileSystemException catch (e) {
      return ChaptersUnreadable(_detail(e));
    }
  }

  Future<List<ChapterRef>> _scan() async {
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
    return refs;
  }
}

String _detail(FileSystemException e) => e.osError?.message ?? e.message;

int _byRepertoireThenName(ChapterRef a, ChapterRef b) {
  final byRepertoire = a.repertoire.toLowerCase().compareTo(
    b.repertoire.toLowerCase(),
  );
  if (byRepertoire != 0) return byRepertoire;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
