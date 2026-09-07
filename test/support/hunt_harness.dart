/// Shared wiring for unit tests that drive a hunt service end to end:
/// a scripted engine in the shared [StockfishPool], a Maia stand-in, and a
/// clean eval cache between tests.
library;

import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/eval_cache.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/maia/maia_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'scripted_engine.dart';

/// Put [connection] behind the shared pool as its only worker.
///
/// The hunts hold `StockfishPool.instance`, so injection is the only seam;
/// [StockfishPool.setTargetCountForTest] keeps `ensureWorkers()` (used by the
/// weakness finder) from deciding it should spawn a real Stockfish alongside.
Future<EvalWorker> installScriptedWorker(ScriptedEngine connection) async {
  final worker = EvalWorker(connection);
  await worker.init(hashMb: 16, threads: 1);
  StockfishPool.instance.addWorkerForTest(worker);
  StockfishPool.instance.setTargetCountForTest(1);
  return worker;
}

/// Drop every injected worker so the next test starts from an empty pool.
void resetPool() => StockfishPool.instance.dispose();

/// SQLite for the eval cache the hunts write their discovery evals into.
Future<void> initTestSqlite() async {
  sqfliteFfiInit();
  databaseFactory = createDatabaseFactoryFfi();
}

/// A Maia that is present and cheap. [failInit] reproduces the case the hunts
/// treat as "Maia unavailable": the model is there but will not load.
class FakeMaia implements MaiaEvaluator {
  FakeMaia({this.failInit = false});

  final bool failInit;
  int initializeCalls = 0;
  int evaluateCalls = 0;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (failInit) throw StateError('Maia model missing');
  }

  @override
  Future<MaiaResult> evaluate(String fen, int elo) async {
    evaluateCalls++;
    return const MaiaResult(policy: {}, winProbability: 0.5);
  }

  @override
  void dispose() {}
}

/// Install [maia] as the platform evaluator; pass null to restore.
void useMaia(MaiaEvaluator? maia) => MaiaFactory.testOverride = maia;

/// Forget every eval a previous test wrote, so a cache hit can never stand in
/// for an engine call the service was supposed to make.
Future<void> clearEvalCache() => EvalCache.instance.clear();
