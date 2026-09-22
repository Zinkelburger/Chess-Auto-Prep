/// Reads a repertoire folder into an [OutlineFolder] and performs the
/// structural edits the outline panel offers: create, rename, move and delete
/// folders and chapters, and move lines between chapters.
///
/// Everything here is disk-first. The panel never mutates a node; it asks this
/// service, which edits the file system and returns, and the controller
/// rebuilds the outline. That keeps one source of truth (the folder) and makes
/// every operation observable from outside the app — a chapter renamed here
/// is a file renamed there.
///
/// Names are validated once, in [validateName], so a chapter and a folder
/// obey the same rules and the same messages.
library;

import 'package:path/path.dart' as p;

import '../../../models/repertoire_line.dart';
import '../../repertoires/models/repertoire_metadata.dart';
import '../../../services/repertoire_review_service.dart';
import '../../../services/repertoire_service.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../services/storage/storage_service.dart';
import '../../../utils/safe_file_name.dart';
import '../models/repertoire_outline.dart';
import 'chapter_splitter.dart';
import '../../repertoires/repositories/repertoire_catalog_repository.dart';
import '../../documents/models/pgn_document.dart';
import 'review_progress_repointer.dart';

/// Why a structural edit was refused, in words the user can act on.
class OutlineEditException implements Exception {
  final String message;
  const OutlineEditException(this.message, {this.splitFailure});
  final ChapterSplitException? splitFailure;
  @override
  String toString() => message;
}

/// The edit would create a chapter or folder whose name is already taken in
/// that folder. Callers that generate names catch this to try another.
class OutlineNameTakenException extends OutlineEditException {
  const OutlineNameTakenException(super.message);
}

/// A chapter's parsed lines, valid while the file's modification time —
/// read once by the chapter listing — is unchanged.
typedef _CachedLines = ({DateTime modified, List<OutlineLine> lines});

class RepertoireOutlineService {
  RepertoireOutlineService({
    StorageService? storage,
    RepertoireService? repertoire,
    required this._catalog,
    required this._splitter,
    ReviewProgressRepointer? repointer,
  }) : _storage = storage ?? StorageFactory.instance,
       _repertoire = repertoire ?? RepertoireService(storage: storage),
       _repointer =
           repointer ??
           ReviewProgressRepointer(
             review: RepertoireReviewService(storage: storage),
           );

  final StorageService _storage;
  final RepertoireService _repertoire;
  final RepertoireCatalogRepository _catalog;
  final ChapterSplitter _splitter;
  final ReviewProgressRepointer _repointer;

  /// Parsed lines per chapter path, so an unchanged chapter is never
  /// re-parsed on rebuild.
  final Map<String, _CachedLines> _lineCache = {};

  // ── Reading ────────────────────────────────────────────────────────────

  /// Builds the outline of the repertoire folder at [folderPath]. With
  /// [loadLines], every chapter's games are parsed (cached by mtime) so the
  /// outline can show lines; otherwise chapters carry only a line count.
  ///
  /// Sub-folders and chapters are independent, so each level reads them
  /// concurrently rather than awaiting one stat and one parse at a time; a
  /// refresh after every save was a chain of tens of serial syscalls.
  Future<OutlineFolder> build(
    String folderPath, {
    bool loadLines = true,
    String? trainingColor,
  }) async {
    final (subdirs, chapters) = await (
      _storage.listSubdirectories(folderPath),
      _catalog.listChapters(folderPath),
    ).wait;
    chapters.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

    final (folders, chapterNodes) = await (
      Future.wait([
        for (final dir in subdirs)
          // Native document recovery bytes are not user chapter folders.
          if (p.basename(dir) != '.cap-pgn-history')
            build(dir, loadLines: loadLines, trainingColor: trainingColor),
      ]),
      Future.wait([
        for (final chapter in chapters)
          _chapterNode(
            chapter,
            loadLines: loadLines,
            trainingColor: trainingColor,
          ),
      ]),
    ).wait;

    return OutlineFolder(
      path: folderPath,
      name: p.basename(folderPath),
      children: [...folders, ...chapterNodes],
    );
  }

  Future<OutlineChapter> _chapterNode(
    RepertoireMetadata chapter, {
    required bool loadLines,
    required String? trainingColor,
  }) async {
    final lines = loadLines
        ? await _linesOf(
            chapter.filePath,
            modified: chapter.lastModified,
            trainingColor: trainingColor,
          )
        : null;
    return OutlineChapter(
      path: chapter.filePath,
      name: chapter.name,
      lines: lines,
      knownLineCount: chapter.gameCount,
    );
  }

  /// Parsed lines of [chapterPath], reusing the cache while the file's
  /// modification time [modified] is unchanged.
  Future<List<OutlineLine>> _linesOf(
    String chapterPath, {
    required DateTime modified,
    required String? trainingColor,
  }) async {
    final cached = _lineCache[chapterPath];
    if (cached != null && cached.modified == modified) {
      return cached.lines;
    }
    List<RepertoireLine> parsed;
    try {
      parsed = await _repertoire.parseRepertoireFile(
        chapterPath,
        trainingColor: trainingColor,
      );
    } catch (_) {
      // An unreadable chapter is listed with no lines rather than hiding
      // the whole repertoire.
      parsed = const [];
    }
    final lines = [
      for (final l in parsed)
        OutlineLine(
          path: chapterPath,
          id: l.id,
          gameIndex: l.gameIndex,
          name: l.name,
          moves: l.moves,
          section: l.chapter,
          isModelGame: l.isModelGame,
        ),
    ];
    _lineCache[chapterPath] = (modified: modified, lines: lines);
    return lines;
  }

  /// Forget cached lines for [chapterPath] (or everything), so the next build
  /// re-reads it even if the mtime did not tick.
  void invalidate([String? chapterPath]) {
    if (chapterPath == null) {
      _lineCache.clear();
    } else {
      _lineCache.remove(chapterPath);
    }
  }

  // ── Names ──────────────────────────────────────────────────────────────

  /// Returns a problem with [name] as a chapter or folder name, or null when
  /// it is fine. The same rules for both: a chapter is a file and a folder is
  /// a folder, and neither can hold a path separator.
  static String? validateName(String name) => validateSafeFileName(name);

  /// [name] trimmed, or an [OutlineEditException] saying what is wrong.
  static String _validName(String name) {
    final problem = validateName(name);
    if (problem != null) throw OutlineEditException(problem);
    return name.trim();
  }

  // ── Chapters ───────────────────────────────────────────────────────────

  /// Creates an empty chapter file `<folderPath>/<name>.pgn`.
  Future<OutlineChapter> createChapter({
    required String folderPath,
    required String name,
    required bool isWhite,
  }) async {
    final result = await _catalog.createChapter(
      folderPath: folderPath,
      name: _validName(name),
      isWhite: isWhite,
    );
    return switch (result) {
      PgnSaved(:final after) => OutlineChapter(
        path: after.path,
        name: name,
        lines: const [],
      ),
      PgnNameCollision() => throw const OutlineNameTakenException(
        'That chapter already exists.',
      ),
      PgnWriteUncertain(:final recoveryPath) => throw OutlineEditException(
        'Chapter creation needs verification: ${p.join(folderPath, "$name.pgn")}.'
        '${recoveryPath == null ? "" : " Recovery: $recoveryPath."} Do not retry.',
      ),
      _ => throw const OutlineEditException('Could not create chapter.'),
    };
  }

  /// Renames the chapter file, keeping it in the same folder. Returns the new
  /// path.
  Future<String> renameChapter(String chapterPath, String newName) async {
    final folder = _storage.parentPath(chapterPath);
    final newPath = _storage.chapterFilePath(folder, _validName(newName));
    if (p.equals(newPath, chapterPath)) return chapterPath;
    if (await _storage.fileExists(newPath)) {
      throw const OutlineNameTakenException(
        'A chapter with that name already exists.',
      );
    }
    await _storage.renameFile(chapterPath, newPath);
    _lineCache.remove(chapterPath);
    return newPath;
  }

  /// Moves a chapter file into [targetFolderPath]. Returns the new path.
  Future<String> moveChapter(
    String chapterPath,
    String targetFolderPath,
  ) async {
    final name = p.basenameWithoutExtension(chapterPath);
    final newPath = _storage.chapterFilePath(targetFolderPath, name);
    if (p.equals(newPath, chapterPath)) return chapterPath;
    if (await _storage.fileExists(newPath)) {
      throw OutlineNameTakenException(
        '"$name" already exists in ${p.basename(targetFolderPath)}.',
      );
    }
    await _storage.renameFile(chapterPath, newPath);
    _lineCache.remove(chapterPath);
    return newPath;
  }

  /// Promotes the `[White]` course chapters inside [chapterPath] to real
  /// chapter files beside it — what an imported Chessable-style course needs
  /// before the builder's structure means anything.
  ///
  /// [isWhite] only supplies the new files' `// Color:` line when the source
  /// declares none. See [ChapterSplitter] for what it does with ids and
  /// training progress.
  Future<ChapterSplitResult> splitChapter(
    String chapterPath, {
    required bool isWhite,
  }) async {
    try {
      return await _splitter.split(chapterPath, isWhite: isWhite);
    } on ChapterSplitException catch (e) {
      throw OutlineEditException(e.message, splitFailure: e);
    } finally {
      // A partial split leaves its acknowledged destinations in this folder.
      _lineCache.removeWhere(
        (path, _) => p.equals(p.dirname(path), p.dirname(chapterPath)),
      );
    }
  }

  // ── Folders ────────────────────────────────────────────────────────────

  /// Creates `<parentPath>/<name>` and returns its path.
  Future<String> createFolder({
    required String parentPath,
    required String name,
  }) async {
    final path = p.join(parentPath, _validName(name));
    if (await _folderExists(path)) {
      throw const OutlineNameTakenException(
        'A folder with that name already exists.',
      );
    }
    await _storage.createDirectory(path);
    return path;
  }

  /// Renames the folder in place. Returns the new path.
  Future<String> renameFolder(String folderPath, String newName) async {
    final newPath = p.join(p.dirname(folderPath), _validName(newName));
    if (p.equals(newPath, folderPath)) return folderPath;
    if (await _folderExists(newPath)) {
      throw const OutlineNameTakenException(
        'A folder with that name already exists.',
      );
    }
    await _storage.moveDirectory(folderPath, newPath);
    _rekeyCache(folderPath, newPath);
    return newPath;
  }

  /// Moves a folder inside [targetFolderPath]. Refuses to move a folder into
  /// itself or one of its descendants. Returns the new path.
  Future<String> moveFolder(String folderPath, String targetFolderPath) async {
    if (p.equals(folderPath, targetFolderPath) ||
        p.isWithin(folderPath, targetFolderPath)) {
      throw const OutlineEditException('A folder cannot be moved into itself.');
    }
    final newPath = p.join(targetFolderPath, p.basename(folderPath));
    if (p.equals(newPath, folderPath)) return folderPath;
    if (await _folderExists(newPath)) {
      throw OutlineNameTakenException(
        '"${p.basename(folderPath)}" already exists in '
        '${p.basename(targetFolderPath)}.',
      );
    }
    await _storage.moveDirectory(folderPath, newPath);
    _rekeyCache(folderPath, newPath);
    return newPath;
  }

  Future<void> deleteFolder(String folderPath) async {
    await _storage.deleteRepertoireDirectory(folderPath);
    _lineCache.removeWhere((k, _) => p.isWithin(folderPath, k));
  }

  /// Whether [folderPath] is a sub-folder of its parent, as the storage
  /// lists it.
  Future<bool> _folderExists(String folderPath) async {
    final siblings = await _storage.listSubdirectories(p.dirname(folderPath));
    return siblings.any((d) => p.equals(d, folderPath));
  }

  /// Paths under a moved folder change; mtimes do not, so the cached lines
  /// stay valid under their new keys.
  void _rekeyCache(String oldFolder, String newFolder) {
    final moved = <String, _CachedLines>{};
    _lineCache.removeWhere((key, cached) {
      if (!p.isWithin(oldFolder, key)) return false;
      final newKey = p.join(newFolder, p.relative(key, from: oldFolder));
      moved[newKey] = (
        modified: cached.modified,
        lines: [for (final l in cached.lines) l.withPath(newKey)],
      );
      return true;
    });
    _lineCache.addAll(moved);
  }

  // ── Lines ──────────────────────────────────────────────────────────────

  /// Moves one line (the [gameIndex]-th game of its chapter) to the end of
  /// another chapter. Returns false when it was not found.
  Future<bool> moveLine({
    required String fromChapterPath,
    required int gameIndex,
    required String toChapterPath,
  }) async {
    final landed = await moveLines(
      fromChapterPath: fromChapterPath,
      gameIndexes: {gameIndex},
      toChapterPath: toChapterPath,
    );
    return landed.isNotEmpty;
  }

  /// Moves the lines at [gameIndexes] of one chapter into another — or,
  /// when both paths are the same file, reorders them — and returns the
  /// indexes they occupy afterwards (empty when none was found).
  ///
  /// They land as a block before the line now at [toIndex], at the end when
  /// it is null, or at exactly [toIndexes] (what undoing a move passes).
  ///
  /// A line that crosses files keeps its training progress: its id is
  /// pinned into the game first, so the position-based fallback id cannot
  /// change under it, and the review records keyed by the old chapter are
  /// re-pointed at the new one.
  Future<List<int>> moveLines({
    required String fromChapterPath,
    required Set<int> gameIndexes,
    required String toChapterPath,
    int? toIndex,
    List<int>? toIndexes,
  }) async {
    final sameFile = p.equals(fromChapterPath, toChapterPath);
    final idByIndex = sameFile
        ? const <int, String>{}
        : await _lineIdsAt(fromChapterPath, gameIndexes);
    final landed = await _repertoire.files.moveGamesTo(
      fromPath: fromChapterPath,
      gameIndexes: gameIndexes,
      toPath: toChapterPath,
      toIndex: toIndex,
      toIndexes: toIndexes,
      transform: sameFile
          ? null
          : (i, text) {
              final id = idByIndex[i];
              return id == null
                  ? text
                  : ReviewProgressRepointer.pinLineId(text, id);
            },
    );
    _lineCache.remove(fromChapterPath);
    _lineCache.remove(toChapterPath);
    if (landed.isNotEmpty && idByIndex.isNotEmpty) {
      await _repointer.repoint(
        from: fromChapterPath,
        movedIdsByPath: {toChapterPath: idByIndex.values.toSet()},
      );
    }
    return landed;
  }

  /// The line ids at [gameIndexes] of [chapterPath], by index.
  Future<Map<int, String>> _lineIdsAt(
    String chapterPath,
    Set<int> gameIndexes,
  ) async {
    final parsed = await _repertoire.parseRepertoireFile(chapterPath);
    return {
      for (final line in parsed)
        if (gameIndexes.contains(line.gameIndex)) line.gameIndex: line.id,
    };
  }

  /// Deletes the lines at [gameIndexes] and returns what went, as the
  /// `(index, text)` pairs [restoreLines] puts back.
  Future<List<({int index, String text})>> deleteLines(
    String chapterPath,
    Set<int> gameIndexes,
  ) async {
    final removed = await _repertoire.files.readGameTextsAt(
      chapterPath,
      gameIndexes,
    );
    if (removed == null || removed.isEmpty) return const [];
    await _repertoire.files.deleteLinesAt(chapterPath, gameIndexes);
    _lineCache.remove(chapterPath);
    return removed;
  }

  /// Puts lines back where [deleteLines] took them from.
  Future<void> restoreLines(
    String chapterPath,
    List<({int index, String text})> lines,
  ) async {
    await _repertoire.files.insertGameTextsAt(chapterPath, lines);
    _lineCache.remove(chapterPath);
  }

  Future<bool> renameLine(
    String chapterPath,
    int gameIndex,
    String newName,
  ) async {
    final ok = await _repertoire.files.updateGameTitleAt(
      chapterPath,
      gameIndex,
      newName,
    );
    _lineCache.remove(chapterPath);
    return ok;
  }
}
