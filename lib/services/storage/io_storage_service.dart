import 'dart:io';
import 'package:path/path.dart' as p;
import '../../utils/atomic_file.dart';
import '../../utils/file_text_reader.dart';
import '../../utils/safe_file_name.dart';
import '../../models/repertoire_metadata.dart';
import '../../models/tactics_set_metadata.dart';
import '../pgn_parsing_service.dart' as pgn;
import '../game_store/game_store.dart';
import '../game_store/game_store_service.dart';
import 'app_paths.dart';
import 'file_mutation_service.dart';
import 'storage_service.dart';
import 'package:chess_auto_prep/utils/log.dart';

StorageService getStorageService() => IOStorageService();

class IOStorageService implements StorageService {
  IOStorageService({
    Directory? documentsRoot,
    Directory? supportRoot,
    Directory? repertoiresRoot,
  }) : _documentsRootOverride = documentsRoot,
       _supportRootOverride = supportRoot,
       _repertoiresRootOverride = repertoiresRoot;

  final Directory? _documentsRootOverride;
  final Directory? _supportRootOverride;
  final Directory? _repertoiresRootOverride;
  static const String _tacticsCsvFileName = 'tactics_positions.csv';
  static const String _analyzedGamesFileName = 'analyzed_games.txt';
  static const String _repertoireReviewsFileName = 'repertoire_reviews.csv';
  static const String _repertoireReviewHistoryFileName =
      'repertoire_review_history.csv';
  static const String _repertoireMoveProgressFileName =
      'repertoire_move_progress.csv';

  /// Per-file game-count cache for the list/picker screens, validated by the
  /// file's `(size, modified)` stat. Reading + counting every PGN on every
  /// navigation is what made the pickers feel slow; caching the count lets a
  /// re-entry skip the read entirely while a stat mismatch (including writes
  /// made outside this service) still forces a fresh count.
  final Map<String, ({int size, int modifiedMs, int count})> _countCache = {};
  final FileMutationService _mutations = FileMutationService.instance;

  Future<Directory> _documentsRoot() async =>
      _documentsRootOverride ?? await AppPaths.documentsDirectory();

  Future<Directory> _supportRoot() async =>
      _supportRootOverride ?? await AppPaths.supportDirectory();

  Future<Directory> _repertoiresRoot() async =>
      _repertoiresRootOverride ??
      await AppPaths.repertoiresDirectory(create: true);

  Future<Directory> _documentsSubdirectory(String name) async {
    final directory = Directory(p.join((await _documentsRoot()).path, name));
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<Directory> _studiesRoot() =>
      _documentsSubdirectory(AppPaths.studiesDirectoryName);

  Future<Directory> _tacticsSetsRoot() =>
      _documentsSubdirectory(AppPaths.tacticsSetsDirectoryName);

  Future<File> _getFile(String filename) async {
    return File(p.join((await _documentsRoot()).path, filename));
  }

  /// Returns the game count for [file], reusing the cached value when the
  /// file's size and modified time are unchanged since it was last counted.
  Future<int> _cachedGameCount(File file, FileStat stat) async {
    final modifiedMs = stat.modified.millisecondsSinceEpoch;
    final cached = _countCache[file.path];
    if (cached != null &&
        cached.size == stat.size &&
        cached.modifiedMs == modifiedMs) {
      return cached.count;
    }

    final content = await readTextFile(file);
    final count = content.trim().isEmpty ? 0 : pgn.countPgnGamesFast(content);
    _countCache[file.path] = (
      size: stat.size,
      modifiedMs: modifiedMs,
      count: count,
    );
    return count;
  }

  Future<File> _resolveFile(String path) async {
    if (p.isAbsolute(path)) return File(path);
    return File(p.join((await _documentsRoot()).path, path));
  }

  Future<Directory> _trashDirectory([String? category]) async {
    final docs = await _documentsRoot();
    final trashRoot = p.join(docs.path, '.chess_auto_prep_trash');
    return Directory(
      category == null ? trashRoot : p.join(trashRoot, category),
    );
  }

  bool _isInside(Directory root, String path) {
    final normalizedRoot = p.normalize(p.absolute(root.path));
    final normalizedPath = p.normalize(p.absolute(path));
    return p.isWithin(normalizedRoot, normalizedPath);
  }

  Future<Directory> _rootForMove(String oldPath, String newPath) async {
    final docs = await _documentsRoot();
    if (_isInside(docs, oldPath) && _isInside(docs, newPath)) return docs;
    final support = await _supportRoot();
    if (_isInside(support, oldPath) && _isInside(support, newPath)) {
      return support;
    }
    final oldParent = Directory(p.dirname(p.normalize(p.absolute(oldPath))));
    final newParent = p.normalize(p.absolute(p.dirname(newPath)));
    if (p.equals(oldParent.path, newParent)) return oldParent;
    throw const UnsafeFileMutation(
      'External files may only be renamed within their existing directory.',
    );
  }

  // ── Generic file I/O ─────────────────────────────────────────────────────

  @override
  Future<String?> readFile(String path) async {
    try {
      final file = await _resolveFile(path);
      await recoverAtomicWritesInDirectory(file.parent);
      if (await file.exists()) return await readTextFile(file);
    } catch (e, st) {
      log.e('Error reading file $path: $e\n$st');
    }
    return null;
  }

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    await writeTextFileAtomically(
      await _resolveFile(path),
      content,
      createOnly: createOnly,
      expectedContent: expectedContent,
    );
  }

  @override
  Future<bool> fileExists(String path) async {
    try {
      final file = await _resolveFile(path);
      await recoverAtomicWritesInDirectory(file.parent);
      return await file.exists();
    } catch (e) {
      log.e('Error checking file $path: $e');
      return false;
    }
  }

  @override
  Future<void> deleteFile(String path) async {
    final file = await _resolveFile(path);
    if (!await file.exists()) return;
    final docs = await _documentsRoot();
    if (_isInside(docs, file.path)) {
      await _mutations.quarantineFile(
        file,
        allowedRoot: docs,
        quarantineRoot: await _trashDirectory('files'),
      );
      return;
    }
    final support = await _supportRoot();
    if (_isInside(support, file.path)) {
      await _mutations.deleteDisposableFile(file, allowedRoot: support);
      return;
    }
    throw UnsafeFileMutation(
      'Refusing to delete ${file.path}: it is not managed app data.',
    );
  }

  @override
  Future<({int size, DateTime modified})?> fileStat(String path) async {
    try {
      final file = await _resolveFile(path);
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      return (size: stat.size, modified: stat.modified);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> renameFile(String oldPath, String newPath) async {
    final source = await _resolveFile(oldPath);
    final destination = await _resolveFile(newPath);
    await _mutations.moveFileNoReplace(
      source,
      destination,
      allowedRoot: await _rootForMove(source.path, destination.path),
    );
  }

  @override
  String parentPath(String filePath) => p.dirname(filePath);

  // ── Repertoire file management ────────────────────────────────────────────

  @override
  Future<List<RepertoireMetadata>> listRepertoireFiles() async {
    final dir = await _repertoiresRoot();
    final files = <File>[
      await for (final entity in dir.list())
        if (entity is File &&
            entity.path.toLowerCase().endsWith('.pgn') &&
            !p.basenameWithoutExtension(entity.path).endsWith('_raw_games'))
          entity,
    ];

    return Future.wait(
      files.map((file) async {
        final stat = await file.stat();
        return RepertoireMetadata(
          filePath: file.path,
          name: p.basenameWithoutExtension(file.path),
          gameCount: await _cachedGameCount(file, stat),
          lastModified: stat.modified,
        );
      }),
    );
  }

  @override
  Future<String> repertoireFilePath(String name) async {
    final dir = await _repertoiresRoot();
    return p.join(dir.path, '${requireSafeFileName(name)}.pgn');
  }

  // ── Repertoire folders + chapters ─────────────────────────────────────────

  /// A `.pgn` under the repertoires tree that is a real chapter (not the
  /// raw-games sidecar written by the build-from-games flow).
  static bool _isChapterFile(String path) =>
      path.toLowerCase().endsWith('.pgn') &&
      !p.basenameWithoutExtension(path).endsWith('_raw_games');

  /// One-time fold of legacy flat `repertoires/<name>.pgn` files into
  /// `repertoires/<name>/Main.pgn` so every repertoire is a folder. Each move
  /// is best-effort and isolated: a failure or name collision leaves that file
  /// untouched rather than aborting the whole listing.
  Future<void> _migrateFlatRepertoires(Directory dir) async {
    await for (final entity in dir.list()) {
      if (entity is! File || !_isChapterFile(entity.path)) continue;
      try {
        final base = p.basenameWithoutExtension(entity.path);
        final targetDir = Directory(p.join(dir.path, base));
        if (await targetDir.exists()) continue;
        await targetDir.create();
        await entity.rename(p.join(targetDir.path, 'Main.pgn'));
      } catch (e) {
        log.e('Repertoire migration skipped ${entity.path}: $e');
      }
    }
  }

  @override
  Future<List<RepertoireMetadata>> listRepertoires() async {
    final dir = await _repertoiresRoot();
    await _migrateFlatRepertoires(dir);

    final folders = <Directory>[
      await for (final entity in dir.list())
        if (entity is Directory) entity,
    ];

    return Future.wait(
      folders.map((folder) async {
        var chapterCount = 0;
        DateTime lastModified = (await folder.stat()).modified;
        await for (final entity in folder.list()) {
          if (entity is File && _isChapterFile(entity.path)) {
            chapterCount++;
            final modified = (await entity.stat()).modified;
            if (modified.isAfter(lastModified)) lastModified = modified;
          }
        }
        return RepertoireMetadata(
          filePath: folder.path,
          name: p.basename(folder.path),
          gameCount: chapterCount,
          lastModified: lastModified,
        );
      }),
    );
  }

  @override
  Future<List<RepertoireMetadata>> listChapters(
    String repertoireDirPath,
  ) async {
    final dir = Directory(repertoireDirPath);
    if (!await dir.exists()) return [];

    final files = <File>[
      await for (final entity in dir.list())
        if (entity is File && _isChapterFile(entity.path)) entity,
    ];

    final entries = await Future.wait(
      files.map((file) async {
        final stat = await file.stat();
        return RepertoireMetadata(
          filePath: file.path,
          name: p.basenameWithoutExtension(file.path),
          gameCount: await _cachedGameCount(file, stat),
          lastModified: stat.modified,
        );
      }),
    );

    entries.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return entries;
  }

  @override
  Future<String> repertoireDirectoryPath(String name) async {
    final dir = await _repertoiresRoot();
    return p.join(dir.path, requireSafeFileName(name));
  }

  @override
  String chapterFilePath(String repertoireDirPath, String chapterName) =>
      p.join(repertoireDirPath, '${requireSafeFileName(chapterName)}.pgn');

  @override
  Future<String> renameRepertoireDirectory(
    String oldDirPath,
    String newName,
  ) async {
    final safeName = requireSafeFileName(newName);
    final root = await _repertoiresRoot();
    final parent = p.dirname(oldDirPath);
    final newPath = p.join(parent, safeName);
    await _mutations.moveDirectoryNoReplace(
      Directory(oldDirPath),
      Directory(newPath),
      allowedRoot: root,
    );
    return newPath;
  }

  @override
  Future<void> deleteRepertoireDirectory(String dirPath) async {
    final root = await _repertoiresRoot();
    final documents = await _documentsRoot();
    await _mutations.quarantineDirectory(
      Directory(dirPath),
      allowedRoot: root,
      quarantineRoot: await _trashDirectory('repertoires'),
      quarantineAllowedRoot: documents,
    );
  }

  @override
  Future<List<String>> listSubdirectories(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];
    final out = <String>[
      await for (final entity in dir.list())
        if (entity is Directory) entity.path,
    ];
    out.sort(
      (a, b) =>
          p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()),
    );
    return out;
  }

  @override
  Future<void> createDirectory(String path) async {
    final root = await _repertoiresRoot();
    await _mutations.createDirectoryNoReplace(
      Directory(path),
      allowedRoot: root,
    );
  }

  @override
  Future<void> moveDirectory(String oldPath, String newPath) async {
    final root = await _repertoiresRoot();
    await _mutations.moveDirectoryNoReplace(
      Directory(oldPath),
      Directory(newPath),
      allowedRoot: root,
    );
  }

  // ── Study file management ────────────────────────────────────────────────

  @override
  Future<List<RepertoireMetadata>> listStudyFiles() async {
    final dir = await _studiesRoot();
    final files = <File>[
      await for (final entity in dir.list())
        if (entity is File && entity.path.toLowerCase().endsWith('.pgn'))
          entity,
    ];

    final entries = await Future.wait(
      files.map((file) async {
        final stat = await file.stat();
        return RepertoireMetadata(
          filePath: file.path,
          name: p.basenameWithoutExtension(file.path),
          gameCount: await _cachedGameCount(file, stat),
          lastModified: stat.modified,
        );
      }),
    );

    entries.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return entries;
  }

  @override
  Future<String> studyFilePath(String name) async {
    final dir = await _studiesRoot();
    return p.join(dir.path, '${requireSafeFileName(name)}.pgn');
  }

  // ── Tactics set management ───────────────────────────────────────────────

  @override
  Future<List<TacticsSetMetadata>> listTacticsSets() async {
    final dir = await _tacticsSetsRoot();
    final files = <File>[
      await for (final entity in dir.list())
        if (entity is File && entity.path.toLowerCase().endsWith('.pgn'))
          entity,
    ];

    final entries = await Future.wait(
      files.map((file) async {
        final stat = await file.stat();
        return TacticsSetMetadata(
          filePath: file.path,
          name: p.basenameWithoutExtension(file.path),
          positionCount: await _cachedGameCount(file, stat),
          lastModified: stat.modified,
        );
      }),
    );

    entries.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return entries;
  }

  @override
  Future<String> tacticsSetPath(String name) async {
    final dir = await _tacticsSetsRoot();
    return p.join(dir.path, '${requireSafeFileName(name)}.pgn');
  }

  @override
  Future<void> deleteTacticsSet(String name) async {
    await deleteFile(await tacticsSetPath(name));
  }

  @override
  Future<List<({String name, String path})>> listLegacyTacticsCsvSets() async {
    final dir = await _tacticsSetsRoot();
    final entries = <({String name, String path})>[];
    await for (final entity in dir.list()) {
      if (!entity.path.toLowerCase().endsWith('.csv')) continue;
      entries.add((
        name: p.basenameWithoutExtension(entity.path),
        path: entity.path,
      ));
    }
    return entries;
  }

  @override
  Future<bool> migrateLegacyTacticsCsv(String defaultSetName) async {
    try {
      if ((await listTacticsSets()).isNotEmpty) return false;
      if ((await listLegacyTacticsCsvSets()).isNotEmpty) return false;

      final legacyFile = await _getFile(_tacticsCsvFileName);
      if (!await legacyFile.exists()) return false;

      final content = await readTextFile(legacyFile);
      if (content.trim().isEmpty) return false;

      // Land it as a .csv set; the database's CSV→PGN migration converts it.
      final dir = await _tacticsSetsRoot();
      await writeFile(p.join(dir.path, '$defaultSetName.csv'), content);
      await legacyFile.rename('${legacyFile.path}.bak');
      log.i('Migrated legacy tactics CSV into set "$defaultSetName"');
      return true;
    } catch (e) {
      log.e('Error migrating legacy tactics CSV: $e');
      return false;
    }
  }

  @override
  Future<String?> readTacticsCsv() async {
    try {
      final file = await _getFile(_tacticsCsvFileName);
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e) {
      log.e('Error reading tactics CSV: $e');
    }
    return null;
  }

  @override
  Future<void> saveTacticsCsv(String csvContent) async {
    try {
      final file = await _getFile(_tacticsCsvFileName);
      await writeTextFileAtomically(file, csvContent);
    } catch (e) {
      log.e('Error saving tactics CSV: $e');
    }
  }

  @override
  Future<List<String>> readAnalyzedGameIds() async {
    try {
      final file = await _getFile(_analyzedGamesFileName);
      if (await file.exists()) {
        final content = await file.readAsString();
        return content.split('\n').where((id) => id.trim().isNotEmpty).toList();
      }
    } catch (e) {
      log.e('Error reading analyzed game IDs: $e');
    }
    return [];
  }

  @override
  Future<void> saveAnalyzedGameIds(List<String> ids) async {
    try {
      final file = await _getFile(_analyzedGamesFileName);
      await writeTextFileAtomically(file, ids.join('\n'));
    } catch (e) {
      log.e('Error saving analyzed game IDs: $e');
    }
  }

  /// The tactics archive lives in the games database now (collection
  /// `tactics`); these two keep the whole-archive-as-text contract for the
  /// callers that still want it.  Hot paths (lookup by GameId, counts,
  /// pruning, appends) go to [GameStore] directly.
  @override
  Future<String?> readImportedPgns() async {
    try {
      final store = await GameStoreService.instance.open();
      if (store.count(GameCollections.tactics) == 0) return null;
      return store.exportPgn(GameCollections.tactics);
    } catch (e) {
      log.e('Error reading imported PGNs: $e');
    }
    return null;
  }

  /// Replace the archive with [pgnContent] (empty = clear).
  @override
  Future<void> saveImportedPgns(String pgnContent) async {
    try {
      final store = await GameStoreService.instance.open();
      store.importPgn(
        pgnContent,
        collection: GameCollections.tactics,
        replace: true,
      );
    } catch (e) {
      log.e('Error saving imported PGNs: $e');
    }
  }

  @override
  Future<String?> readRepertoirePgn(String filename) async {
    try {
      File file;
      if (p.isAbsolute(filename)) {
        file = File(filename);
      } else {
        file = await _getFile(filename);
      }

      if (await file.exists()) {
        return await readTextFile(file);
      }
    } catch (e) {
      log.e('Error reading repertoire PGN: $e');
    }
    return null;
  }

  @override
  Future<void> saveRepertoirePgn(String filename, String content) async {
    try {
      final file = await _getFile(filename);
      await writeTextFileAtomically(file, content);
    } catch (e) {
      log.e('Error saving repertoire PGN: $e');
    }
  }

  @override
  Future<String?> readRepertoireReviewsCsv() async {
    try {
      final file = await _getFile(_repertoireReviewsFileName);
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e) {
      log.e('Error reading repertoire reviews CSV: $e');
    }
    return null;
  }

  @override
  Future<void> saveRepertoireReviewsCsv(String csvContent) async {
    try {
      final file = await _getFile(_repertoireReviewsFileName);
      await writeTextFileAtomically(file, csvContent);
    } catch (e) {
      log.e('Error saving repertoire reviews CSV: $e');
    }
  }

  @override
  Future<String?> readRepertoireReviewHistoryCsv() async {
    try {
      final file = await _getFile(_repertoireReviewHistoryFileName);
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e) {
      log.e('Error reading repertoire review history CSV: $e');
    }
    return null;
  }

  @override
  Future<void> saveRepertoireReviewHistoryCsv(String csvContent) async {
    try {
      final file = await _getFile(_repertoireReviewHistoryFileName);
      await writeTextFileAtomically(file, csvContent);
    } catch (e) {
      log.e('Error saving repertoire review history CSV: $e');
    }
  }

  @override
  Future<String?> readRepertoireMoveProgressCsv() async {
    try {
      final file = await _getFile(_repertoireMoveProgressFileName);
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e) {
      log.e('Error reading repertoire move progress CSV: $e');
    }
    return null;
  }

  @override
  Future<void> saveRepertoireMoveProgressCsv(String csvContent) async {
    try {
      final file = await _getFile(_repertoireMoveProgressFileName);
      await writeTextFileAtomically(file, csvContent);
    } catch (e) {
      log.e('Error saving repertoire move progress CSV: $e');
    }
  }
}
