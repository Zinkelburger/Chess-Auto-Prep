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
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'storage/app_paths.dart';

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
          version: 2,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE evals(
                fen TEXT PRIMARY KEY,
                eval_cp_white INTEGER NOT NULL,
                depth INTEGER NOT NULL,
                created_at INTEGER NOT NULL
              )
            ''');
            await db.execute('''
              CREATE TABLE maia_cache(
                fen TEXT NOT NULL,
                elo INTEGER NOT NULL,
                policy_json TEXT NOT NULL,
                win_prob REAL NOT NULL,
                created_at INTEGER NOT NULL,
                PRIMARY KEY (fen, elo)
              )
            ''');
          },
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 2) {
              await db.execute('''
                CREATE TABLE IF NOT EXISTS maia_cache(
                  fen TEXT NOT NULL,
                  elo INTEGER NOT NULL,
                  policy_json TEXT NOT NULL,
                  win_prob REAL NOT NULL,
                  created_at INTEGER NOT NULL,
                  PRIMARY KEY (fen, elo)
                )
              ''');
            }
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
      final dir = await AppPaths.supportDirectory();
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

// ── Maia policy cache ──────────────────────────────────────────────────

class MaiaCache {
  static final MaiaCache instance = MaiaCache._();
  MaiaCache._();

  final Map<String, Map<String, double>> _mem = {};
  final Map<String, double> _winMem = {};

  String _key(String fen, int elo) => '$fen|$elo';

  Future<({Map<String, double> policy, double winProb})?> get(
      String fen, int elo) async {
    final k = _key(fen, elo);
    if (_mem.containsKey(k)) {
      return (policy: _mem[k]!, winProb: _winMem[k] ?? 0.0);
    }

    final db = EvalCache.instance._db;
    if (db == null) return null;
    try {
      final rows = await db.query(
        'maia_cache',
        columns: ['policy_json', 'win_prob'],
        where: 'fen = ? AND elo = ?',
        whereArgs: [fen, elo],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final json = rows.first['policy_json'] as String;
      final winProb = (rows.first['win_prob'] as num).toDouble();
      final map = _decodePolicyJson(json);
      _mem[k] = map;
      _winMem[k] = winProb;
      return (policy: map, winProb: winProb);
    } catch (e) {
      if (kDebugMode) debugPrint('[MaiaCache] read failed: $e');
      return null;
    }
  }

  Future<void> put(
      String fen, int elo, Map<String, double> policy, double winProb) async {
    final k = _key(fen, elo);
    _mem[k] = policy;
    _winMem[k] = winProb;

    final db = EvalCache.instance._db;
    if (db == null) return;
    try {
      final json = _encodePolicyJson(policy);
      await db.execute('''
        INSERT INTO maia_cache(fen, elo, policy_json, win_prob, created_at)
        VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(fen, elo) DO UPDATE SET
          policy_json = excluded.policy_json,
          win_prob    = excluded.win_prob,
          created_at  = excluded.created_at
      ''', [fen, elo, json, winProb, DateTime.now().millisecondsSinceEpoch]);
    } catch (e) {
      if (kDebugMode) debugPrint('[MaiaCache] write failed: $e');
    }
  }

  static String _encodePolicyJson(Map<String, double> policy) {
    final sb = StringBuffer('{');
    var first = true;
    for (final e in policy.entries) {
      if (!first) sb.write(',');
      sb.write('"${e.key}":${e.value}');
      first = false;
    }
    sb.write('}');
    return sb.toString();
  }

  static Map<String, double> _decodePolicyJson(String json) {
    final map = <String, double>{};
    final stripped = json.substring(1, json.length - 1);
    if (stripped.isEmpty) return map;
    for (final pair in stripped.split(',')) {
      final colon = pair.indexOf(':');
      if (colon < 0) continue;
      final key = pair.substring(1, colon - 1);
      final val = double.tryParse(pair.substring(colon + 1));
      if (val != null) map[key] = val;
    }
    return map;
  }
}
