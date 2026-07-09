import 'dart:async';

import '../../models/repertoire_metadata.dart';
import '../../models/tactics_set_metadata.dart';

/// Abstract interface for storage operations.
///
/// Domain-specific helpers (tactics CSV, repertoire PGN, etc.) build on top of
/// the generic [readFile] / [writeFile] / [fileExists] / [deleteFile] methods
/// so that controllers and widgets never depend on `dart:io` directly.
abstract class StorageService {
  // ── Generic file I/O ─────────────────────────────────────────────────────

  /// Read a file at [path] (absolute or relative to the app documents root).
  /// Returns `null` if the file does not exist or cannot be read.
  Future<String?> readFile(String path);

  /// Write [content] to the file at [path], creating parent directories as
  /// needed.  Uses an atomic temp-file rename when possible.
  Future<void> writeFile(String path, String content);

  /// Whether a file exists at the given [path].
  Future<bool> fileExists(String path);

  /// Delete the file at [path].  No-op if it does not exist.
  Future<void> deleteFile(String path);

  /// Return the file size (bytes) and last-modified time for [path].
  /// Returns `null` if the file does not exist or cannot be stat'd.
  Future<({int size, DateTime modified})?> fileStat(String path);

  /// Rename / move a file from [oldPath] to [newPath].
  Future<void> renameFile(String oldPath, String newPath);

  /// Return the parent directory path for [filePath].
  String parentPath(String filePath);

  // ── Repertoire file management ────────────────────────────────────────────

  /// Lists all `.pgn` files in the repertoires directory.
  ///
  /// Each entry contains the file path, display name, game count, and last-
  /// modified timestamp.
  Future<List<RepertoireMetadata>> listRepertoireFiles();

  /// Returns the absolute path for a repertoire file with the given [name].
  Future<String> repertoireFilePath(String name);

  // ── Study file management ────────────────────────────────────────────────

  /// Lists all `.pgn` files in the studies directory ([RepertoireMetadata]
  /// is reused: `gameCount` is the chapter count).
  Future<List<RepertoireMetadata>> listStudyFiles();

  /// Returns the absolute path for a study file with the given [name].
  Future<String> studyFilePath(String name);

  // ── Tactics set management ───────────────────────────────────────────────

  /// Lists all `.pgn` set files in the tactics-sets directory.
  ///
  /// Each entry contains the file path, display name, position (game) count,
  /// and last-modified timestamp.
  Future<List<TacticsSetMetadata>> listTacticsSets();

  /// Returns the absolute path for a tactics-set file with the given [name].
  Future<String> tacticsSetPath(String name);

  /// Deletes the tactics-set file with the given [name].  No-op if missing.
  Future<void> deleteTacticsSet(String name);

  /// Lists legacy `.csv` set files still in the tactics-sets directory
  /// (pre-PGN installs).  The database converts these to `.pgn` on load.
  Future<List<({String name, String path})>> listLegacyTacticsCsvSets();

  /// One-time migration: if no set files exist yet (neither `.pgn` nor
  /// legacy `.csv`) and the legacy root-level `tactics_positions.csv` does,
  /// move its content into a `.csv` set file named [defaultSetName] and
  /// rename the legacy file to `.bak` (kept as a rollback).  The database's
  /// CSV→PGN set migration then converts it.  Returns `true` if a migration
  /// ran.
  Future<bool> migrateLegacyTacticsCsv(String defaultSetName);

  // ── Domain-specific helpers ──────────────────────────────────────────────

  /// Legacy single-file tactics CSV at the documents root.  Superseded by
  /// named sets ([listTacticsSets] / [tacticsSetPath]); retained only for
  /// [migrateLegacyTacticsCsv].
  Future<String?> readTacticsCsv();
  Future<void> saveTacticsCsv(String csvContent);

  Future<List<String>> readAnalyzedGameIds();
  Future<void> saveAnalyzedGameIds(List<String> ids);

  Future<String?> readImportedPgns();
  Future<void> saveImportedPgns(String pgnContent);

  Future<String?> readRepertoirePgn(String filename);
  Future<void> saveRepertoirePgn(String filename, String content);

  Future<String?> readRepertoireReviewsCsv();
  Future<void> saveRepertoireReviewsCsv(String csvContent);

  Future<String?> readRepertoireReviewHistoryCsv();
  Future<void> saveRepertoireReviewHistoryCsv(String csvContent);

  Future<String?> readRepertoireMoveProgressCsv();
  Future<void> saveRepertoireMoveProgressCsv(String csvContent);
}
