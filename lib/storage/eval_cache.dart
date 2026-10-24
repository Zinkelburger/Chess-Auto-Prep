import 'dart:io';

import 'package:dartchess/dartchess.dart' show Position, Side;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../chess/fen.dart';
import '../chess/generation/eval.dart';
import '../chess/generation/sources.dart';
import '../diagnostics/log.dart';

/// The engine's fixed-depth verdicts, kept between runs: `eval_cache.db` in
/// the support folder, so a position already scored, by this run or an
/// earlier one, is not scored again.
///
/// One table is read and written: `evals(fen, eval_cp_white, depth,
/// created_at)` keyed by the four-field FEN, the score from White's side, and
/// the deeper of two verdicts winning. Anything else a file holds is left
/// alone.
///
/// A file that will not open is logged once and the cache answers nothing:
/// a build runs without it, slower, rather than not at all.
final class EvalCache {
  EvalCache._(this._db);

  /// Opens or creates the cache under [support]. Never throws.
  factory EvalCache.open(Directory support) {
    final path = p.join(support.path, 'eval_cache.db');
    Database? opened;
    try {
      support.createSync(recursive: true);
      final db = opened = sqlite3.open(path);
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA synchronous = NORMAL');
      db.execute(_createEvals);
      return EvalCache._(db);
    } on Object catch (error) {
      opened?.close();
      log.w('open $path', error);
      return EvalCache._(null);
    }
  }

  /// A cache that remembers nothing past this process: what a test wants.
  factory EvalCache.inMemory() {
    final db = sqlite3.openInMemory();
    db.execute(_createEvals);
    return EvalCache._(db);
  }

  static const _createEvals = '''
    CREATE TABLE IF NOT EXISTS evals(
      fen TEXT PRIMARY KEY,
      eval_cp_white INTEGER NOT NULL,
      depth INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''';

  final Database? _db;

  /// Whether the file opened. A cache that did not still answers, with
  /// nothing.
  bool get available => _db != null;

  /// The score from White's side kept for [fen4], the four-field FEN, when
  /// it was scored at least [minDepth] deep; null otherwise.
  int? read(String fen4, {required int minDepth}) =>
      readVerdict(fen4, minDepth: minDepth)?.cpWhite;

  /// Keep the stored depth alongside the score for result inspection.
  ({int cpWhite, int depth})? readVerdict(
    String fen4, {
    required int minDepth,
  }) {
    final db = _db;
    if (db == null) return null;
    try {
      final rows = db.select(
        'SELECT eval_cp_white, depth FROM evals WHERE fen = ? AND depth >= ?',
        [fen4, minDepth],
      );
      return rows.isEmpty
          ? null
          : (
              cpWhite: rows.first.columnAt(0) as int,
              depth: rows.first.columnAt(1) as int,
            );
    } on Object catch (error) {
      log.w('read the eval cache', error);
      return null;
    }
  }

  /// Keeps [cpWhite] for [fen4] unless a deeper verdict is already there.
  void write(String fen4, {required int cpWhite, required int depth}) {
    final db = _db;
    if (db == null) return;
    try {
      db.execute(_upsert, [
        fen4,
        cpWhite,
        depth,
        DateTime.now().millisecondsSinceEpoch,
      ]);
    } on Object catch (error) {
      log.w('write the eval cache', error);
    }
  }

  static const _upsert = '''
    INSERT INTO evals(fen, eval_cp_white, depth, created_at)
    VALUES(?, ?, ?, ?)
    ON CONFLICT(fen) DO UPDATE SET
      eval_cp_white = excluded.eval_cp_white,
      depth         = excluded.depth,
      created_at    = excluded.created_at
    WHERE excluded.depth >= evals.depth
  ''';

  void close() => _db?.close();
}

/// The cache under [support], opened the first time [cache] is asked for.
///
/// Most runs never fill, and opening the file creates it, switches it to
/// WAL and stamps its schema version on it, so a run that never needed
/// it — or a close on the way out — must not open it. [close] closes only
/// a cache that was opened.
final class EvalCacheOnDemand {
  EvalCacheOnDemand(this.support);

  final Directory support;
  EvalCache? _opened;

  EvalCache get cache => _opened ??= EvalCache.open(support);

  void close() {
    _opened?.close();
    _opened = null;
  }
}

/// The engine with the cache in front of it: a position the cache holds at
/// the depth asked for is answered from there, and every verdict the engine
/// gives is written back, from White's side, so a later run finds it.
///
/// The engine answers from the side to move and the cache keeps White's
/// view, so one negation each way when it is Black's move.
final class CachedEvaluator implements PositionEvaluator {
  const CachedEvaluator(this.engine, this.cache, {required this.depth});

  final PositionEvaluator engine;
  final EvalCache cache;
  final int depth;

  @override
  Future<EvaluationResult> evaluate(Position position) async {
    final fen = Fen(position.fen);
    final white = position.turn == Side.white;
    final kept = cache.readVerdict(fen.position, minDepth: depth);
    if (kept != null) {
      return Evaluated(
        Eval(white ? kept.cpWhite : -kept.cpWhite),
        depth: kept.depth,
      );
    }
    final answer = await evaluationOf(engine, position);
    if (answer case Evaluated(:final eval)) {
      cache.write(
        fen.position,
        cpWhite: white ? eval.cp : -eval.cp,
        depth: answer.depth ?? depth,
      );
    }
    return answer;
  }
}
