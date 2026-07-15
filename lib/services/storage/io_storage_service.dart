import 'dart:io';
import 'package:path/path.dart' as p;
import '../../utils/atomic_file.dart';
import '../../utils/file_text_reader.dart';
import '../../models/repertoire_metadata.dart';
import '../../models/tactics_set_metadata.dart';
import '../pgn_parsing_service.dart' as pgn;
import 'app_paths.dart';
import 'storage_service.dart';
import 'package:chess_auto_prep/utils/log.dart';

StorageService getStorageService() => IOStorageService();

class IOStorageService implements StorageService {
  static const String _tacticsCsvFileName = 'tactics_positions.csv';
  static const String _analyzedGamesFileName = 'analyzed_games.txt';
  static const String _importedGamesFileName = 'imported_games.pgn';
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

  Future<File> _getFile(String filename) async {
    return AppPaths.documentsFile(filename);
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
    return AppPaths.documentsFile(path);
  }

  // ── Generic file I/O ─────────────────────────────────────────────────────

  @override
  Future<String?> readFile(String path) async {
    try {
      final file = await _resolveFile(path);
      if (await file.exists()) return await readTextFile(file);
    } catch (e, st) {
      log.e('Error reading file $path: $e\n$st');
    }
    return null;
  }

  @override
  Future<void> writeFile(String path, String content) async {
    await writeTextFileAtomically(await _resolveFile(path), content);
  }

  @override
  Future<bool> fileExists(String path) async {
    try {
      return await (await _resolveFile(path)).exists();
    } catch (e) {
      log.e('Error checking file $path: $e');
      return false;
    }
  }

  @override
  Future<void> deleteFile(String path) async {
    try {
      final file = await _resolveFile(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      log.e('Error deleting file $path: $e');
    }
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
    await (await _resolveFile(oldPath)).rename(newPath);
  }

  @override
  String parentPath(String filePath) => p.dirname(filePath);

  // ── Repertoire file management ────────────────────────────────────────────

  @override
  Future<List<RepertoireMetadata>> listRepertoireFiles() async {
    final dir = await AppPaths.repertoiresDirectory(create: true);
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
    final dir = await AppPaths.repertoiresDirectory(create: true);
    return p.join(dir.path, '$name.pgn');
  }

  // ── Study file management ────────────────────────────────────────────────

  @override
  Future<List<RepertoireMetadata>> listStudyFiles() async {
    final dir = await AppPaths.studiesDirectory(create: true);
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
    final dir = await AppPaths.studiesDirectory(create: true);
    return p.join(dir.path, '$name.pgn');
  }

  // ── Tactics set management ───────────────────────────────────────────────

  @override
  Future<List<TacticsSetMetadata>> listTacticsSets() async {
    final dir = await AppPaths.tacticsSetsDirectory(create: true);
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
    final dir = await AppPaths.tacticsSetsDirectory(create: true);
    return p.join(dir.path, '$name.pgn');
  }

  @override
  Future<void> deleteTacticsSet(String name) async {
    await deleteFile(await tacticsSetPath(name));
  }

  @override
  Future<List<({String name, String path})>> listLegacyTacticsCsvSets() async {
    final dir = await AppPaths.tacticsSetsDirectory(create: true);
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
      final dir = await AppPaths.tacticsSetsDirectory(create: true);
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

  @override
  Future<String?> readImportedPgns() async {
    try {
      final file = await _getFile(_importedGamesFileName);
      if (await file.exists()) {
        return await readTextFile(file);
      }
    } catch (e) {
      log.e('Error reading imported PGNs: $e');
    }
    return null;
  }

  @override
  Future<void> saveImportedPgns(String pgnContent) async {
    try {
      final file = await _getFile(_importedGamesFileName);
      await writeTextFileAtomically(file, pgnContent);
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
