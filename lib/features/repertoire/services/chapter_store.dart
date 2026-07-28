/// Reading and creating the chapters of a repertoire folder.
///
/// A repertoire is a directory of chapter PGNs; the active chapter's path is
/// `.../<repertoire>/<chapter>.pgn`. Creating one means picking a filename,
/// refusing a name already taken, and writing a header that records the
/// chapter's colour — three rules that lived inside a dialog callback in the
/// repertoire screen, next to the `TextField` that collected the name.
library;

import 'package:path/path.dart' as p;

import '../../../models/repertoire_metadata.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../services/storage/storage_service.dart';

/// Outcome of [ChapterStore.create]: the new chapter, or why there isn't one.
class ChapterCreationResult {
  const ChapterCreationResult.created(this.chapter) : error = null;
  const ChapterCreationResult.failed(this.error) : chapter = null;

  final RepertoireMetadata? chapter;

  /// User-facing message. Null when [chapter] is set.
  final String? error;

  bool get succeeded => chapter != null;
}

class ChapterStore {
  ChapterStore({StorageService? storage})
    : _storage = storage ?? StorageFactory.instance;

  final StorageService _storage;

  /// The repertoire folder that holds [chapterFilePath].
  String folderOf(String chapterFilePath) =>
      _storage.parentPath(chapterFilePath);

  /// Chapters sharing a folder with [chapterFilePath], for the breadcrumb's
  /// chapter dropdown.
  Future<List<RepertoireMetadata>> listSiblings(String chapterFilePath) =>
      _storage.listChapters(folderOf(chapterFilePath));

  /// Creates `<folderPath>/<name>.pgn` with a colour header and returns it.
  ///
  /// [now] is injectable only so the header is checkable; callers pass
  /// nothing.
  Future<ChapterCreationResult> create({
    required String folderPath,
    required String name,
    required bool isWhite,
    DateTime? now,
  }) async {
    final path = _storage.chapterFilePath(folderPath, name);
    if (await _storage.fileExists(path)) {
      return const ChapterCreationResult.failed('That chapter already exists.');
    }
    try {
      await _storage.writeFile(
        path,
        chapterHeader(
          name: name,
          isWhite: isWhite,
          createdAt: now ?? DateTime.now(),
        ),
      );
    } catch (e) {
      return const ChapterCreationResult.failed('Could not create chapter.');
    }
    return ChapterCreationResult.created(
      RepertoireMetadata(
        filePath: path,
        name: name,
        gameCount: 0,
        lastModified: now ?? DateTime.now(),
      ),
    );
  }

  /// Comment header written above an empty chapter. The colour line is the
  /// one part that matters — it is what tells a later load which side the
  /// chapter is for, so it must survive a chapter created before any moves.
  static String chapterHeader({
    required String name,
    required bool isWhite,
    required DateTime createdAt,
  }) {
    return '// $name\n'
        '// Color: ${isWhite ? 'White' : 'Black'}\n'
        '// Created on ${createdAt.toString().split('.')[0]}\n\n';
  }

  /// Metadata for the folder itself, as the chapter-list screen wants it.
  RepertoireMetadata folderMetadata(String chapterFilePath) {
    final folderPath = folderOf(chapterFilePath);
    return RepertoireMetadata(
      filePath: folderPath,
      name: p.basename(folderPath),
      lastModified: DateTime.now(),
    );
  }
}
