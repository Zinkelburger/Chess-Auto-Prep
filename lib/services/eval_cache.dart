/// Persistent Stockfish eval cache.
///
/// Desktop-only (Linux / macOS / Windows) — uses `sqflite_common_ffi`.
/// Cache is keyed by the canonical 4-field FEN (see [canonicalizeFen4]) and
/// stores the deepest eval we've ever computed for that position.  Survives
/// app restarts so cancelling / resuming a tree build does not re-evaluate
/// positions.
///
/// Values are always stored as centipawns from White's perspective.
/// Callers translate to side-to-move.
///
/// Keying on the 4-field FEN is what makes transpositions hit: the same
/// position reached by a different move order routinely differs only in the
/// halfmove clock (1.Nf3 d5 2.d4 Nf6 → 1; 1.d4 Nf6 2.Nf3 d5 → 0), which is
/// exactly the case a tree build meets thousands of times.  Every other key
/// in the pipeline (`FenMap`, the master book, cdbdirect) is already 4-field.
///
/// Writes are coalesced: a MultiPV expansion produces a dozen child evals at
/// once, and one autocommit `INSERT` per eval meant one fsync per eval.  Puts
/// land in a pending map and are flushed in a single batch shortly after, or
/// when the map grows past [_flushThreshold].  The in-memory mirror is updated
/// synchronously, so a read that follows a write always sees it.
library;

import 'dart:async';
import 'dart:io' show Directory, Platform;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../utils/lru_map.dart';
import 'eval/eval_canonicalize.dart';
import 'storage/app_paths.dart';

class EvalCache {
  static final EvalCache instance = EvalCache._();
  EvalCache._();

  /// Schema versions:
  ///  1 — evals keyed by full FEN
  ///  2 — + maia_cache
  ///  3 — both tables re-keyed by canonical 4-field FEN
  static const int _schemaVersion = 3;

  /// Pending puts are flushed after this delay, or as soon as this many are
  /// waiting — whichever comes first.
  static const Duration _flushDelay = Duration(milliseconds: 500);
  static const int _flushThreshold = 200;

  Database? _db;
  Future<void>? _initFuture;

  /// Entries held in the L1 mirror before the least recently used is
  /// dropped.  A key is a canonical 4-field FEN (~55 bytes) and an [_Entry]
  /// is two ints, so 100k entries is on the order of 20 MB — bounded, and
  /// still far more than the working set of any one search.  The mirror
  /// exists only to save SQLite round-trips; every evicted entry is still on
  /// disk, so eviction costs a query, never a re-evaluation.
  ///
  /// It used to be uncapped, which meant a deep build that touched millions
  /// of distinct positions retained every one of them for the life of the
  /// process.
  static const int _memoryEntries = 100000;

  /// L1 mirror, canonical key → entry.  A miss is remembered as
  /// [_Entry.miss] so a position the database has never seen costs one
  /// query, not one per candidate that reaches it.
  final LruMap<String, _Entry> _mem = LruMap(maxEntries: _memoryEntries);

  final _WriteQueue _writes = _WriteQueue();

  /// Bumped by [clear] so a put that was waiting on [init] when the cache
  /// was cleared does not resurrect its entry afterwards.
  int _generation = 0;

  bool get _supported =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  /// Idempotent. Safe to call on every tree-build start.
  ///
  /// [getEvalCpWhite] / [putEvalCpWhite] (and [MaiaCache]) await this before
  /// touching SQLite, so a fire-and-forget warm-up in `main` cannot leave
  /// early writes memory-only.
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

      final db = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: _schemaVersion,
          onConfigure: _configure,
          onCreate: (db, _) async {
            await _createEvals(db);
            await _createMaia(db);
          },
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 2) await _createMaia(db);
            if (oldVersion < 3) await rekeyToCanonical(db);
          },
        ),
      );
      _db = db;
      _writes.attach(db);
    } catch (e) {
      if (kDebugMode) debugPrint('[EvalCache] init failed: $e');
      _db = null;
    }
  }

  /// WAL lets the build's reads proceed while a batch commits, and NORMAL
  /// sync trades a crash-window of unflushed evals (cheap to recompute) for
  /// one fsync per checkpoint instead of one per commit.  Same pragmas as
  /// the game store and master-games DB.
  static Future<void> _configure(Database db) async {
    await db.rawQuery('PRAGMA journal_mode = WAL');
    await db.execute('PRAGMA synchronous = NORMAL');
  }

  static Future<void> _createEvals(DatabaseExecutor db) => db.execute('''
    CREATE TABLE IF NOT EXISTS evals(
      fen TEXT PRIMARY KEY,
      eval_cp_white INTEGER NOT NULL,
      depth INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');

  static Future<void> _createMaia(DatabaseExecutor db) => db.execute('''
    CREATE TABLE IF NOT EXISTS maia_cache(
      fen TEXT NOT NULL,
      elo INTEGER NOT NULL,
      policy_json TEXT NOT NULL,
      win_prob REAL NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY (fen, elo)
    )
  ''');

  /// Rows migrated per batch.  Bounded on purpose: see [rekeyToCanonical].
  static const int _migrationPage = 5000;

  /// One-time migration to canonical keys (schema v2 → v3).
  ///
  /// Streams the old table into a fresh one a page at a time instead of
  /// building a Dart map of every row first: a warm cache is hundreds of
  /// thousands of evals, and materialising all of them merely to collapse
  /// duplicates froze the app on the first launch after the upgrade.
  ///
  /// The upserts do the collapsing, so nothing needs to be held in memory to
  /// do it: `evals` keeps the deeper of two rows through its own `WHERE`
  /// clause, and `maia_cache` keeps whichever was written last, so its rows
  /// are replayed oldest-first.
  ///
  /// The whole thing runs in one transaction — a crash part-way leaves the
  /// old tables untouched.
  @visibleForTesting
  static Future<void> rekeyToCanonical(Database db) async {
    await db.transaction((txn) async {
      await txn.execute('ALTER TABLE evals RENAME TO evals_v2');
      await _createEvals(txn);
      await _copyPaged(
        txn,
        from: 'evals_v2',
        orderBy: 'rowid',
        upsert: _WriteQueue.evalUpsert,
        args: (row) => [
          canonicalizeFen4(row['fen'] as String),
          row['eval_cp_white'],
          row['depth'],
          row['created_at'],
        ],
      );
      await txn.execute('DROP TABLE evals_v2');

      await txn.execute('ALTER TABLE maia_cache RENAME TO maia_cache_v2');
      await _createMaia(txn);
      await _copyPaged(
        txn,
        from: 'maia_cache_v2',
        // Oldest first, so the newest policy for a position is the one left
        // standing after the last unconditional overwrite.
        orderBy: 'created_at',
        upsert: _WriteQueue.maiaUpsert,
        args: (row) => [
          canonicalizeFen4(row['fen'] as String),
          row['elo'],
          row['policy_json'],
          row['win_prob'],
          row['created_at'],
        ],
      );
      await txn.execute('DROP TABLE maia_cache_v2');
    });
  }

  static Future<void> _copyPaged(
    DatabaseExecutor txn, {
    required String from,
    required String orderBy,
    required String upsert,
    required List<Object?> Function(Map<String, Object?> row) args,
  }) async {
    var offset = 0;
    while (true) {
      final rows = await txn.query(
        from,
        orderBy: orderBy,
        limit: _migrationPage,
        offset: offset,
      );
      if (rows.isEmpty) return;
      final batch = txn.batch();
      for (final row in rows) {
        batch.rawInsert(upsert, args(row));
      }
      await batch.commit(noResult: true);
      offset += rows.length;
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
    final key = canonicalizeFen4(fen);
    final hit = _mem[key];
    // A known miss answers any depth.  A real entry answers only when it is
    // deep enough: the disk row can be *deeper* than L1 (a shallow put keeps
    // its own entry in memory, while the upsert's `WHERE excluded.depth >=`
    // leaves the deeper row on disk), so a shallow hit must not mask it.
    if (hit != null && (hit.isMiss || hit.depth >= minDepth)) {
      return hit.isMiss ? null : hit.cpWhite;
    }

    await init();
    final db = _db;
    if (db == null) return null;
    try {
      final rows = await db.query(
        'evals',
        columns: ['eval_cp_white', 'depth'],
        where: 'fen = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) {
        // A put that raced this read already owns the slot; keep it.
        _mem.putIfAbsent(key, () => _Entry.miss);
        return null;
      }
      final cp = rows.first['eval_cp_white'] as int;
      final depth = rows.first['depth'] as int;
      final entry = _Entry(cp, depth);
      final current = _mem[key];
      if (current == null || current.isMiss || depth >= current.depth) {
        _mem[key] = entry;
      }
      return depth >= minDepth ? cp : null;
    } catch (e) {
      if (kDebugMode) debugPrint('[EvalCache] read failed: $e');
      return null;
    }
  }

  /// Store an eval.  Upserts only when [depth] is ≥ the stored depth so a
  /// shallower eval never overwrites a deeper one.
  ///
  /// Completes once the eval is durable — after the next batch flush.  Search
  /// pipelines should use [putEvalCpWhiteSoon] and not wait.
  Future<void> putEvalCpWhite(String fen, int cpWhite, int depth) async {
    final key = canonicalizeFen4(fen);
    final existing = _mem[key];
    if (existing != null && !existing.isMiss && depth < existing.depth) return;
    _mem[key] = _Entry(cpWhite, depth);

    final generation = _generation;
    await init();
    if (_db == null || generation != _generation) return;
    return _writes.enqueueEval(key, cpWhite, depth);
  }

  /// Fire-and-forget [putEvalCpWhite] for search pipelines that must not
  /// stall on SQLite.
  void putEvalCpWhiteSoon(String fen, int cpWhite, int depth) {
    unawaited(putEvalCpWhite(fen, cpWhite, depth));
  }

  /// Write every pending eval now.  Tests and shutdown paths call this;
  /// normal operation relies on the timed flush.
  Future<void> flush() => _writes.flush();

  /// Total cached entries (in the DB, not the L1 mirror).
  Future<int> count() async {
    await init();
    final db = _db;
    if (db == null) return _mem.values.where((e) => !e.isMiss).length;
    await _writes.flush();
    try {
      final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM evals');
      return (rows.first['n'] as int?) ?? 0;
    } catch (_) {
      return _mem.values.where((e) => !e.isMiss).length;
    }
  }

  /// Forget the L1 mirror, keeping every row on disk — the state a fresh
  /// process starts in against a warm cache file.  Tests use it to reach the
  /// case where the mirror and the disk disagree about depth.
  @visibleForTesting
  void forgetMemoryMirror() => _mem.clear();

  /// Drop every row (e.g. from a settings "clear cache" button).
  Future<void> clear() async {
    _generation++;
    _mem.clear();
    _writes.discardEvals();
    await init();
    final db = _db;
    if (db == null) return;
    try {
      // A batch already committing must land before the delete, not after.
      await _writes.settle();
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

  /// Remembered database miss: the position is known to be absent.
  static const _Entry miss = _Entry(0, -1);

  bool get isMiss => depth < 0;
}

/// Pending upserts for both tables, flushed together in one batch.
///
/// The queue exists before the database does: puts that arrive while
/// [EvalCache.init] is still opening the file are held and written once
/// [attach] runs.  Each flush drains everything queued so far into one
/// `batch.commit`, and every waiter that enqueued before that flush is
/// completed by it.
class _WriteQueue {
  static const String evalUpsert = '''
    INSERT INTO evals(fen, eval_cp_white, depth, created_at)
    VALUES(?, ?, ?, ?)
    ON CONFLICT(fen) DO UPDATE SET
      eval_cp_white = excluded.eval_cp_white,
      depth         = excluded.depth,
      created_at    = excluded.created_at
    WHERE excluded.depth >= evals.depth
  ''';

  static const String maiaUpsert = '''
    INSERT INTO maia_cache(fen, elo, policy_json, win_prob, created_at)
    VALUES(?, ?, ?, ?, ?)
    ON CONFLICT(fen, elo) DO UPDATE SET
      policy_json = excluded.policy_json,
      win_prob    = excluded.win_prob,
      created_at  = excluded.created_at
  ''';

  Database? _db;

  /// Canonical key → upsert args.  A later put for the same key replaces the
  /// earlier one; the SQL `WHERE` keeps the deeper of the two on disk.
  final Map<String, List<Object?>> _evals = {};
  final Map<String, List<Object?>> _maia = {};

  Timer? _timer;
  Completer<void>? _flushed;
  Future<void> _inFlight = Future.value();

  void attach(Database db) {
    _db = db;
    if (_evals.isNotEmpty || _maia.isNotEmpty) unawaited(_schedule());
  }

  Future<void> enqueueEval(String key, int cpWhite, int depth) {
    _evals[key] = [key, cpWhite, depth, DateTime.now().millisecondsSinceEpoch];
    return _schedule();
  }

  Future<void> enqueueMaia(
    String key,
    int elo,
    String policyJson,
    double winProb,
  ) {
    _maia['$key|$elo'] = [
      key,
      elo,
      policyJson,
      winProb,
      DateTime.now().millisecondsSinceEpoch,
    ];
    return _schedule();
  }

  void discardEvals() => _evals.clear();

  /// Completes when no batch is committing.
  Future<void> settle() => _inFlight;

  Future<void> _schedule() {
    final flushed = _flushed ??= Completer<void>();
    if (_db == null) return flushed.future;
    if (_evals.length + _maia.length >= EvalCache._flushThreshold) {
      unawaited(flush());
    } else {
      _timer ??= Timer(EvalCache._flushDelay, () => unawaited(flush()));
    }
    return flushed.future;
  }

  /// Drain the queue into one batch.  Serialised: a flush that starts while
  /// another is committing waits for it, so batches never interleave.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final db = _db;
    final waiter = _flushed;
    if (db == null || waiter == null) return _inFlight;

    final evals = List.of(_evals.values);
    final maia = List.of(_maia.values);
    _evals.clear();
    _maia.clear();
    _flushed = null;

    final previous = _inFlight;
    final run = () async {
      await previous;
      if (evals.isEmpty && maia.isEmpty) return;
      try {
        final batch = db.batch();
        for (final args in evals) {
          batch.rawInsert(evalUpsert, args);
        }
        for (final args in maia) {
          batch.rawInsert(maiaUpsert, args);
        }
        await batch.commit(noResult: true);
      } catch (e) {
        if (kDebugMode) debugPrint('[EvalCache] write failed: $e');
      }
    }();
    _inFlight = run;
    unawaited(run.whenComplete(waiter.complete));
    return run;
  }
}

// ── Maia policy cache ──────────────────────────────────────────────────

class MaiaCache {
  static final MaiaCache instance = MaiaCache._();
  MaiaCache._();

  /// Entries held in memory before the least recently used is dropped.  One
  /// entry is a policy over ~30 moves — a `Map<String, double>` of roughly
  /// 2.5 kB — so 20k entries is on the order of 50 MB.  Heavier per entry
  /// than the eval mirror, hence the smaller cap.
  ///
  /// Policy and win probability live in one entry so the two cannot evict
  /// independently.  They used to be two uncapped maps with nothing that ever
  /// removed from either and no [clear] at all, so every Maia inference the
  /// process performed was retained for its lifetime.
  static const int _memoryEntries = 20000;

  final LruMap<String, _MaiaEntry> _mem = LruMap(maxEntries: _memoryEntries);

  String _key(String fen, int elo) => '${canonicalizeFen4(fen)}|$elo';

  Future<({Map<String, double> policy, double winProb})?> get(
    String fen,
    int elo,
  ) async {
    final k = _key(fen, elo);
    final hit = _mem[k];
    if (hit != null) return (policy: hit.policy, winProb: hit.winProb);

    await EvalCache.instance.init();
    final db = EvalCache.instance._db;
    if (db == null) return null;
    try {
      final rows = await db.query(
        'maia_cache',
        columns: ['policy_json', 'win_prob'],
        where: 'fen = ? AND elo = ?',
        whereArgs: [canonicalizeFen4(fen), elo],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final json = rows.first['policy_json'] as String;
      final winProb = (rows.first['win_prob'] as num).toDouble();
      final map = _decodePolicyJson(json);
      _mem[k] = _MaiaEntry(map, winProb);
      return (policy: map, winProb: winProb);
    } catch (e) {
      if (kDebugMode) debugPrint('[MaiaCache] read failed: $e');
      return null;
    }
  }

  /// Store a policy.  Completes after the next batch flush; see
  /// [EvalCache.putEvalCpWhite].
  Future<void> put(
    String fen,
    int elo,
    Map<String, double> policy,
    double winProb,
  ) async {
    final k = _key(fen, elo);
    _mem[k] = _MaiaEntry(policy, winProb);

    await EvalCache.instance.init();
    if (EvalCache.instance._db == null) return;
    return EvalCache.instance._writes.enqueueMaia(
      canonicalizeFen4(fen),
      elo,
      _encodePolicyJson(policy),
      winProb,
    );
  }

  /// Fire-and-forget [put] for inference pipelines that must not stall on
  /// SQLite.  The in-memory mirror is updated synchronously, so the next
  /// [get] for the same position hits it whether or not the batch has
  /// committed; only durability is deferred.  Mirrors
  /// [EvalCache.putEvalCpWhiteSoon].
  void putSoon(
    String fen,
    int elo,
    Map<String, double> policy,
    double winProb,
  ) {
    unawaited(put(fen, elo, policy, winProb));
  }

  /// Drop every cached policy, in memory and on disk.  The eval side has had
  /// this since it shipped; this side did not, so a settings-level "clear
  /// cache" could not reach the Maia rows at all.
  Future<void> clear() async {
    _mem.clear();
    await EvalCache.instance.init();
    final db = EvalCache.instance._db;
    if (db == null) return;
    try {
      await EvalCache.instance._writes.settle();
      await db.delete('maia_cache');
    } catch (e) {
      if (kDebugMode) debugPrint('[MaiaCache] clear failed: $e');
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

class _MaiaEntry {
  final Map<String, double> policy;
  final double winProb;
  const _MaiaEntry(this.policy, this.winProb);
}
