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
import '../../../models/repertoire_metadata.dart';
import '../../../services/repertoire_service.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../services/storage/storage_service.dart';
import '../models/repertoire_outline.dart';
import 'chapter_splitter.dart';
import 'chapter_store.dart';

/// Why a structural edit was refused, in words the user can act on.
class OutlineEditException implements Exception {
  final String message;
  const OutlineEditException(this.message);
  @override
  String toString() => message;
}

class RepertoireOutlineService {
  RepertoireOutlineService({
    StorageService? storage,
    RepertoireService? repertoire,
    ChapterStore? chapters,
    ChapterSplitter? splitter,
  }) : _storage = storage ?? StorageFactory.instance,
       _repertoire = repertoire ?? RepertoireService(),
       _chapters = chapters ?? ChapterStore(storage: storage),
       _splitter =
           splitter ??
           ChapterSplitter(storage: storage, repertoire: repertoire);

  final StorageService _storage;
  final RepertoireService _repertoire;
  final ChapterStore _chapters;
  final ChapterSplitter _splitter;

  /// Parsed lines per chapter path, keyed by the file's modification time so
  /// an unchanged chapter is never re-parsed on rebuild.
  final Map<String, ({DateTime modified, List<OutlineLine> lines})> _lineCache =
      {};

  // ── Reading ────────────────────────────────────────────────────────────

  /// Builds the outline of the repertoire folder at [folderPath]. With
  /// [loadLines], every chapter's games are parsed (cached by mtime) so the
  /// outline can show lines; otherwise chapters carry only a line count.
  Future<OutlineFolder> build(
    String folderPath, {
    bool loadLines = true,
    String? trainingColor,
  }) async {
    return _buildFolder(
      folderPath,
      loadLines: loadLines,
      trainingColor: trainingColor,
    );
  }

  /// Sub-folders and chapters are independent, so each level reads them
  /// concurrently rather than awaiting one stat and one parse at a time; a
  /// refresh after every save was a chain of tens of serial syscalls.
  Future<OutlineFolder> _buildFolder(
    String folderPath, {
    required bool loadLines,
    required String? trainingColor,
  }) async {
    final (subdirs, chapters) = await (
      _storage.listSubdirectories(folderPath),
      _storage.listChapters(folderPath),
    ).wait;
    chapters.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

    final (folders, chapterNodes) = await (
      Future.wait([
        for (final dir in subdirs)
          _buildFolder(dir, loadLines: loadLines, trainingColor: trainingColor),
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
  /// modification time — [modified], already read by the chapter listing —
  /// is unchanged.
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

  static final _illegal = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

  /// Returns a problem with [name] as a chapter or folder name, or null when
  /// it is fine. The same rules for both: a chapter is a file and a folder is
  /// a folder, and neither can hold a path separator.
  static String? validateName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Enter a name.';
    if (_illegal.hasMatch(trimmed)) {
      return r'Names cannot contain < > : " / \ | ? *';
    }
    if (trimmed == '.' || trimmed == '..') return 'That name is reserved.';
    if (trimmed.endsWith('.')) return 'Names cannot end with a dot.';
    return null;
  }

  static String _clean(String name) => name.trim();

  // ── Chapters ───────────────────────────────────────────────────────────

  /// Creates an empty chapter file `<folderPath>/<name>.pgn`.
  Future<OutlineChapter> createChapter({
    required String folderPath,
    required String name,
    required bool isWhite,
  }) async {
    final problem = validateName(name);
    if (problem != null) throw OutlineEditException(problem);
    final result = await _chapters.create(
      folderPath: folderPath,
      name: _clean(name),
      isWhite: isWhite,
    );
    if (!result.succeeded) throw OutlineEditException(result.error!);
    return OutlineChapter(
      path: result.chapter!.filePath,
      name: result.chapter!.name,
      lines: const [],
    );
  }

  /// Renames the chapter file, keeping it in the same folder. Returns the new
  /// path.
  Future<String> renameChapter(String chapterPath, String newName) async {
    final problem = validateName(newName);
    if (problem != null) throw OutlineEditException(problem);
    final folder = _storage.parentPath(chapterPath);
    final newPath = _storage.chapterFilePath(folder, _clean(newName));
    if (p.equals(newPath, chapterPath)) return chapterPath;
    if (await _storage.fileExists(newPath)) {
      throw const OutlineEditException(
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
      throw OutlineEditException(
        '"$name" already exists in ${p.basename(targetFolderPath)}.',
      );
    }
    await _storage.renameFile(chapterPath, newPath);
    _lineCache.remove(chapterPath);
    return newPath;
  }

  Future<void> deleteChapter(String chapterPath) async {
    await _storage.deleteFile(chapterPath);
    _lineCache.remove(chapterPath);
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
    final ChapterSplitResult result;
    try {
      result = await _splitter.split(chapterPath, isWhite: isWhite);
    } on ChapterSplitException catch (e) {
      throw OutlineEditException(e.message);
    }
    _lineCache.remove(chapterPath);
    for (final path in result.createdPaths) {
      _lineCache.remove(path);
    }
    return result;
  }

  // ── Folders ────────────────────────────────────────────────────────────

  /// Creates `<parentPath>/<name>` and returns its path.
  Future<String> createFolder({
    required String parentPath,
    required String name,
  }) async {
    final problem = validateName(name);
    if (problem != null) throw OutlineEditException(problem);
    final path = p.join(parentPath, _clean(name));
    if ((await _storage.listSubdirectories(
      parentPath,
    )).any((d) => p.equals(d, path))) {
      throw const OutlineEditException(
        'A folder with that name already exists.',
      );
    }
    await _storage.createDirectory(path);
    return path;
  }

  /// Renames the folder in place. Returns the new path.
  Future<String> renameFolder(String folderPath, String newName) async {
    final problem = validateName(newName);
    if (problem != null) throw OutlineEditException(problem);
    final newPath = p.join(p.dirname(folderPath), _clean(newName));
    if (p.equals(newPath, folderPath)) return folderPath;
    if ((await _storage.listSubdirectories(
      p.dirname(folderPath),
    )).any((d) => p.equals(d, newPath))) {
      throw const OutlineEditException(
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
    if ((await _storage.listSubdirectories(
      targetFolderPath,
    )).any((d) => p.equals(d, newPath))) {
      throw OutlineEditException(
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

  void _rekeyCache(String oldFolder, String newFolder) {
    // Paths under a moved folder change; mtimes do not, so the entries stay
    // valid under their new keys.
    final moved = <String, ({DateTime modified, List<OutlineLine> lines})>{};
    _lineCache.removeWhere((k, v) {
      if (!p.isWithin(oldFolder, k)) return false;
      final rel = p.relative(k, from: oldFolder);
      final nk = p.join(newFolder, rel);
      moved[nk] = (
        modified: v.modified,
        lines: [
          for (final l in v.lines)
            OutlineLine(
              path: nk,
              id: l.id,
              gameIndex: l.gameIndex,
              name: l.name,
              moves: l.moves,
              section: l.section,
              isModelGame: l.isModelGame,
            ),
        ],
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
    final ok = await _repertoire.moveGame(
      fromPath: fromChapterPath,
      gameIndex: gameIndex,
      toPath: toChapterPath,
    );
    _lineCache.remove(fromChapterPath);
    _lineCache.remove(toChapterPath);
    return ok;
  }

  Future<bool> renameLine(
    String chapterPath,
    int gameIndex,
    String newName,
  ) async {
    final ok = await _repertoire.updateGameTitleAt(
      chapterPath,
      gameIndex,
      newName,
    );
    _lineCache.remove(chapterPath);
    return ok;
  }

  Future<bool> deleteLine(String chapterPath, int gameIndex) async {
    final ok = await _repertoire.deleteGameAt(chapterPath, gameIndex);
    _lineCache.remove(chapterPath);
    return ok;
  }
}
