/// Read-only ChessDB local SQLite eval lookup.
///
/// Schema: `chessdb_evals(fen TEXT PK, cp INT, mate INT, depth INT, move TEXT)`
library;

import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../utils/fen_utils.dart';
import 'eval_canonicalize.dart';
import 'external_eval_provider.dart';

typedef SqliteEvalDatabaseFactory = Future<Database> Function(String path);

/// Opens [path] read-only and validates the expected schema.
Future<Database?> openChessDbEvalDatabase(String path) async {
  if (path.trim().isEmpty) return null;
  if (!await File(path).exists()) return null;

  try {
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      sqfliteFfiInit();
    }
    final factory = (Platform.isLinux || Platform.isMacOS || Platform.isWindows)
        ? databaseFactoryFfi
        : databaseFactory;

    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='chessdb_evals'",
    );
    if (tables.isEmpty) {
      await db.close();
      return null;
    }
    return db;
  } catch (e) {
    if (kDebugMode) debugPrint('[SqliteEvalProvider] open failed: $e');
    return null;
  }
}

/// Returns true when [path] points to a readable DB with `chessdb_evals`.
Future<bool> validateChessDbEvalFile(String path) async {
  if (path.trim().isEmpty) return false;
  final db = await openChessDbEvalDatabase(path);
  if (db == null) return false;
  await db.close();
  return true;
}

class SqliteEvalProvider implements ExternalEvalProvider {
  Database? _db;
  final String path;
  final SqliteEvalDatabaseFactory? _openOverride;

  SqliteEvalProvider({required this.path, this._openOverride});

  /// Opens the database lazily. Safe to call multiple times.
  Future<bool> init() async {
    if (_db != null) return true;
    if (path.isEmpty) return false;
    _db = _openOverride != null
        ? await _openOverride(path)
        : await openChessDbEvalDatabase(path);
    return _db != null;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  @override
  Future<EvalLookupResult> lookup(String fen, {required int minDepth}) async {
    final db = _db;
    if (db == null) return const EvalLookupResult.miss();

    final key = canonicalizeFen4(fen);
    final isWhiteStm = isWhiteToMove(key);

    try {
      final rows = await db.query(
        'chessdb_evals',
        columns: ['cp', 'mate', 'depth', 'move'],
        where: 'fen = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) return const EvalLookupResult.hardMiss();

      final row = rows.first;
      final cpRaw = row['cp'];
      final mateRaw = row['mate'];
      final depth = (row['depth'] as num?)?.toInt() ?? 0;
      final move = row['move'] as String?;

      final cp = cpRaw == null ? null : (cpRaw as num).toInt();
      final mate = mateRaw == null ? null : (mateRaw as num).toInt();

      final whiteCp = mapSqliteScoreToWhiteCp(
        cp: cp,
        mate: mate,
        isWhiteToMove: isWhiteStm,
      );
      if (whiteCp == null) return const EvalLookupResult.hardMiss();

      if (depth < minDepth) return const EvalLookupResult.shallow();

      return EvalLookupResult.found(
        EvalHit(
          cp: whiteCp,
          mate: mate,
          depth: depth,
          bestMove: move?.isNotEmpty == true ? move : null,
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[SqliteEvalProvider] lookup failed: $e');
      return const EvalLookupResult.miss();
    }
  }
}
