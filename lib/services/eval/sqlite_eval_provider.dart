/// Read-only ChessDB local SQLite eval lookup.
///
/// Schema: `chessdb_evals(fen TEXT PK, cp INT, mate INT, depth INT, move TEXT)`
library;

import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../utils/eval_constants.dart';
import '../../utils/fen_utils.dart';
import '../../chess_core/position/eval_canonicalize.dart';
import 'external_eval_provider.dart';

typedef SqliteEvalDatabaseFactory = Future<Database> Function(String path);

const String _kTable = 'chessdb_evals';

bool get _usesFfiDatabase =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows;

/// Opens [path] read-only and validates the expected schema.
Future<Database?> openChessDbEvalDatabase(String path) async {
  if (path.trim().isEmpty) return null;
  if (!await File(path).exists()) return null;

  try {
    final DatabaseFactory factory;
    if (_usesFfiDatabase) {
      sqfliteFfiInit();
      factory = databaseFactoryFfi;
    } else {
      factory = databaseFactory;
    }

    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='$_kTable'",
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

/// White-normalized centipawns from a row's raw `cp` / `mate` columns, both
/// stored from the side to move's point of view. Null when the row has
/// neither.
int? _whiteCpFromRow({
  required int? cp,
  required int? mate,
  required bool isWhiteToMove,
}) {
  final stmCp = mate != null ? mateToCp(mate) : cp;
  if (stmCp == null) return null;
  return isWhiteToMove ? stmCp : -stmCp;
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
    final open = _openOverride;
    _db = open != null ? await open(path) : await openChessDbEvalDatabase(path);
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

    try {
      final rows = await db.query(
        _kTable,
        columns: ['cp', 'mate', 'depth', 'move'],
        where: 'fen = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) return const EvalLookupResult.hardMiss();

      final row = rows.first;
      final cp = (row['cp'] as num?)?.toInt();
      final mate = (row['mate'] as num?)?.toInt();
      final depth = (row['depth'] as num?)?.toInt() ?? 0;
      final move = row['move'] as String?;

      final whiteCp = _whiteCpFromRow(
        cp: cp,
        mate: mate,
        isWhiteToMove: isWhiteToMove(key),
      );
      if (whiteCp == null) return const EvalLookupResult.hardMiss();

      if (depth < minDepth) return const EvalLookupResult.shallow();

      return EvalLookupResult.found(
        EvalHit(
          cp: whiteCp,
          mate: mate,
          depth: depth,
          bestMove: (move == null || move.isEmpty) ? null : move,
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[SqliteEvalProvider] lookup failed: $e');
      return const EvalLookupResult.miss();
    }
  }
}
