import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
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

/// One repertoire: a folder under `repertoires/` and the chapters in it.
final class RepertoireFolder {
  const RepertoireFolder({
    required this.name,
    required this.path,
    required this.modified,
    required this.chapters,
  });

  /// The folder's name, which is what the user called the repertoire.
  final String name;

  /// The folder itself, absolute.
  final String path;

  /// The newest change to any chapter in the folder, or to the folder when it
  /// holds none. Editing a chapter leaves the folder's own timestamp alone, so
  /// the folder's date by itself would say a repertoire in daily use was last
  /// touched the day it was made.
  final DateTime modified;

  final List<ChapterRef> chapters;
}

sealed class RepertoireListing {
  const RepertoireListing();
}

final class Repertoires extends RepertoireListing {
  const Repertoires(this.folders);

  final List<RepertoireFolder> folders;
}

/// The repertoires folder exists but could not be read.
final class RepertoiresUnreadable extends RepertoireListing {
  const RepertoiresUnreadable(this.detail);

  /// The operating system's message, for the log; the UI writes the sentence.
  final String detail;
}

/// The repertoire folders under `Documents/repertoires/`. The filesystem is a
/// real boundary, so this is an interface: [ChapterDirectory] in the app, a
/// scripted one in tests.
///
/// Listing and the one folder the library removes. A chapter's text is read,
/// and written, through the document store, which is the one place that knows
/// its revision.
abstract interface class ChapterFiles {
  Future<RepertoireListing> list();

  /// Takes away a repertoire folder whose chapters have all been deleted, so
  /// deleting a repertoire leaves nothing behind in the user's Documents.
  ///
  /// A folder that still holds anything — a chapter this call did not expect,
  /// the recovery folder the deleted chapters went into — is left alone. It is
  /// then no longer a repertoire, because it has no chapters, and the list
  /// stops showing it either way.
  Future<void> removeIfEmpty(String folder);
}

/// One folder per repertoire, one `.pgn` per chapter, plus index files and
/// sidecars the app ignores.
final class ChapterDirectory implements ChapterFiles {
  ChapterDirectory(this.root);

  /// The `repertoires` directory itself.
  final Directory root;

  @override
  Future<RepertoireListing> list() async {
    if (!await root.exists()) return const Repertoires([]);
    try {
      final folders = await _scan();
      folders.sort(_byName);
      return Repertoires(List.unmodifiable(folders));
    } on FileSystemException catch (e) {
      return RepertoiresUnreadable(_detail(e));
    }
  }

  @override
  Future<void> removeIfEmpty(String folder) async {
    final directory = Directory(folder);
    try {
      if (await directory.list().isEmpty) await directory.delete();
    } on FileSystemException catch (error) {
      log.w('remove the empty folder $folder', error);
    }
  }

  Future<List<RepertoireFolder>> _scan() async {
    final folders = <RepertoireFolder>[];
    await for (final entry in root.list()) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (name.startsWith('.')) continue;
      final folder = await _read(entry, name);
      // A folder with no chapters is not a repertoire. It is what a deleted
      // one leaves behind — the recovery folder its chapters went into — and
      // showing "0 chapters" after a delete would say the delete failed.
      if (folder.chapters.isNotEmpty) folders.add(folder);
    }
    return folders;
  }

  Future<RepertoireFolder> _read(Directory folder, String name) async {
    final chapters = <ChapterRef>[];
    var modified = (await folder.stat()).modified;
    await for (final file in folder.list()) {
      if (file is! File || !_isChapter(file.path)) continue;
      chapters.add(
        ChapterRef(
          repertoire: name,
          name: p.basenameWithoutExtension(file.path),
          path: file.path,
        ),
      );
      final touched = (await file.stat()).modified;
      if (touched.isAfter(modified)) modified = touched;
    }
    chapters.sort(_byChapterName);
    return RepertoireFolder(
      name: name,
      path: folder.path,
      modified: modified,
      chapters: List.unmodifiable(chapters),
    );
  }
}

/// A chapter is a `.pgn` that is not one of the raw-game sidecars generation
/// writes beside a chapter; the old app hides those from its list too.
bool _isChapter(String path) =>
    p.extension(path) == '.pgn' && !path.endsWith('_raw_games.pgn');

String _detail(FileSystemException e) => e.osError?.message ?? e.message;

int _byName(RepertoireFolder a, RepertoireFolder b) =>
    a.name.toLowerCase().compareTo(b.name.toLowerCase());

int _byChapterName(ChapterRef a, ChapterRef b) =>
    a.name.toLowerCase().compareTo(b.name.toLowerCase());
