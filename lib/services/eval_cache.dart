/// Persistent Stockfish eval cache.
///
/// Desktop-only (Linux / macOS / Windows) — uses `sqflite_common_ffi`.
/// Cache is keyed by FEN and stores the deepest eval we've ever computed
/// for that position.  Survives app restarts so cancelling / resuming a
/// tree build does not re-evaluate positions.
///
/// Values are always stored as centipawns from White's perspective.
/// Callers translate to side-to-move.
library;

import 'dart:async';
import 'dart:io' show Directory, Platform;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class EvalCache {
  static final EvalCache instance = EvalCache._();
  EvalCache._();

  Database? _db;
  Future<void>? _initFuture;

  final Map<String, _Entry> _mem = {};

  bool get _supported =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  /// Idempotent. Safe to call on every tree-build start.
  Future<void> init() {
    return _initFuture ??= _init();
  }

  Future<void> _init() async {
    if (!_supported) return;
    try {
      sqfliteFfiInit();
      final factory = databaseFactoryFfi;

      final base = await _dbDirectory();
      final path = p.join(base, 'eval_cache.db');

      _db = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE evals(
                fen TEXT PRIMARY KEY,
                eval_cp_white INTEGER NOT NULL,
                depth INTEGER NOT NULL,
                created_at INTEGER NOT NULL
              )
            ''');
          },
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[EvalCache] init failed: $e');
      _db = null;
    }
  }

  Future<String> _dbDirectory() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return dir.path;
    } catch (_) {
      final fallback = Directory.systemTemp.createTempSync('chess_auto_prep');
      return fallback.path;
    }
  }

  /// Returns cached eval (white-normalized cp) if we have one at ≥ [minDepth].
  /// L1 in-memory check runs synchronously-fast; L2 SQLite check is awaited.
  Future<int?> getEvalCpWhite(String fen, {int minDepth = 0}) async {
    final hit = _mem[fen];
    if (hit != null && hit.depth >= minDepth) return hit.cpWhite;

    final db = _db;
    if (db == null) return null;
    try {
      final rows = await db.query(
        'evals',
        columns: ['eval_cp_white', 'depth'],
        where: 'fen = ?',
        whereArgs: [fen],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final cp = rows.first['eval_cp_white'] as int;
      final depth = rows.first['depth'] as int;
      _mem[fen] = _Entry(cp, depth);
      return depth >= minDepth ? cp : null;
    } catch (e) {
      if (kDebugMode) debugPrint('[EvalCache] read failed: $e');
      return null;
    }
  }

  /// Store an eval.  Upserts only when [depth] is ≥ the stored depth so a
  /// shallower eval never overwrites a deeper one.
  Future<void> putEvalCpWhite(String fen, int cpWhite, int depth) async {
    final existing = _mem[fen];
    if (existing == null || depth >= existing.depth) {
      _mem[fen] = _Entry(cpWhite, depth);
    } else {
      return;
    }

    final db = _db;
    if (db == null) return;
    try {
      await db.execute('''
        INSERT INTO evals(fen, eval_cp_white, depth, created_at)
        VALUES(?, ?, ?, ?)
        ON CONFLICT(fen) DO UPDATE SET
          eval_cp_white = excluded.eval_cp_white,
          depth         = excluded.depth,
          created_at    = excluded.created_at
        WHERE excluded.depth >= evals.depth
      ''', [fen, cpWhite, depth, DateTime.now().millisecondsSinceEpoch]);
    } catch (e) {
      if (kDebugMode) debugPrint('[EvalCache] write failed: $e');
    }
  }

  /// Total cached entries (in the DB, not the L1 mirror).
  Future<int> count() async {
    final db = _db;
    if (db == null) return _mem.length;
    try {
      final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM evals');
      return (rows.first['n'] as int?) ?? 0;
    } catch (_) {
      return _mem.length;
    }
  }

  /// Drop every row (e.g. from a settings "clear cache" button).
  Future<void> clear() async {
    _mem.clear();
    final db = _db;
    if (db == null) return;
    try {
      await db.delete('evals');
    } catch (e) {
      if (kDebugMode) debugPrint('[EvalCache] clear failed: $e');
    }
  }
}

class _Entry {
  final int cpWhite;
  final int depth;
  const _Entry(this.cpWhite, this.depth);
}
