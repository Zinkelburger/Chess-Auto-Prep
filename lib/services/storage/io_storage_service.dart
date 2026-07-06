import 'dart:io';
import 'package:path/path.dart' as p;
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

  Future<File> _getFile(String filename) async {
    return AppPaths.documentsFile(filename);
  }

  Future<File> _resolveFile(String path) async {
    if (p.isAbsolute(path)) return File(path);
    return AppPaths.documentsFile(path);
  }

  /// Best-effort atomic replace: write to a temp file, then rename.
  Future<void> _writeAtomically(File target, String content) async {
    final parent = target.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }

    final tmp = File(
      p.join(
        parent.path,
        '.${p.basename(target.path)}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );

    await tmp.writeAsString(content, flush: true);

    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      if (await target.exists()) {
        await target.delete();
      }
      await tmp.rename(target.path);
    }
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
    await _writeAtomically(await _resolveFile(path), content);
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
    final entries = <RepertoireMetadata>[];
    await for (final entity in dir.list()) {
      if (!entity.path.toLowerCase().endsWith('.pgn')) continue;
      final base = p.basenameWithoutExtension(entity.path);
      if (base.endsWith('_raw_games')) continue;
      final stat = await entity.stat();
      final content = await readTextFile(File(entity.path));
      entries.add(RepertoireMetadata(
        filePath: entity.path,
        name: p.basenameWithoutExtension(entity.path),
        gameCount: pgn.countPgnGames(content),
        lastModified: stat.modified,
      ));
    }
    return entries;
  }

  @override
  Future<String> repertoireFilePath(String name) async {
    final dir = await AppPaths.repertoiresDirectory(create: true);
    return p.join(dir.path, '$name.pgn');
  }

  // ── Tactics set management ───────────────────────────────────────────────

  @override
  Future<List<TacticsSetMetadata>> listTacticsSets() async {
    final dir = await AppPaths.tacticsSetsDirectory(create: true);
    final entries = <TacticsSetMetadata>[];
    await for (final entity in dir.list()) {
      if (!entity.path.toLowerCase().endsWith('.csv')) continue;
      final stat = await entity.stat();
      entries.add(TacticsSetMetadata(
        filePath: entity.path,
        name: p.basenameWithoutExtension(entity.path),
        positionCount: await _countCsvDataRows(File(entity.path)),
        lastModified: stat.modified,
      ));
    }
    entries.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return entries;
  }

  /// Non-empty line count minus the header row.  Cheap approximation used
  /// for the set picker; the database parses rows properly on load.
  Future<int> _countCsvDataRows(File file) async {
    try {
      final content = await readTextFile(file);
      final lines =
          content.split('\n').where((l) => l.trim().isNotEmpty).length;
      return lines > 0 ? lines - 1 : 0;
    } catch (e) {
      log.e('Error counting rows in ${file.path}: $e');
      return 0;
    }
  }

  @override
  Future<String> tacticsSetPath(String name) async {
    final dir = await AppPaths.tacticsSetsDirectory(create: true);
    return p.join(dir.path, '$name.csv');
  }

  @override
  Future<void> deleteTacticsSet(String name) async {
    await deleteFile(await tacticsSetPath(name));
  }

  @override
  Future<bool> migrateLegacyTacticsCsv(String defaultSetName) async {
    try {
      final existingSets = await listTacticsSets();
      if (existingSets.isNotEmpty) return false;

      final legacyFile = await _getFile(_tacticsCsvFileName);
      if (!await legacyFile.exists()) return false;

      final content = await readTextFile(legacyFile);
      if (content.trim().isEmpty) return false;

      await writeFile(await tacticsSetPath(defaultSetName), content);
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
      await _writeAtomically(file, csvContent);
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
      await _writeAtomically(file, ids.join('\n'));
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
      await _writeAtomically(file, pgnContent);
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
      await _writeAtomically(file, content);
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
      await _writeAtomically(file, csvContent);
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
      await _writeAtomically(file, csvContent);
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
      await _writeAtomically(file, csvContent);
    } catch (e) {
      log.e('Error saving repertoire move progress CSV: $e');
    }
  }
}
