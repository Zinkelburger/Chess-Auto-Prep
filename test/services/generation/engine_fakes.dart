/// Deterministic engine and Maia fakes for generation-pipeline tests.
///
/// [FakeStockfishPool] subclasses the real pool through the
/// `@visibleForTesting` [StockfishPool.fresh] constructor and overrides only
/// the evaluation entry points the generation code calls ([evaluateFen],
/// [discoverMoves]) — the inherited [StockfishPool.evaluateMany] batching
/// glue runs for real on top of the fake.  Evals are scripted per FEN; an
/// unscripted FEN throws so a test can never silently pass on a default.
///
/// [FakeMaiaEvaluator] is installed via `MaiaFactory.testOverride` (remember
/// to reset it to null in tearDown).
library;

import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/maia_factory.dart';
import 'package:chess_auto_prep/services/maia_service.dart';

class FakeStockfishPool extends StockfishPool {
  FakeStockfishPool({this.workers = 1}) : super.fresh();

  /// Reported [workerCount]; 0 simulates "engine unavailable".
  int workers;

  /// STM-relative cp returned by [evaluateFen], keyed by FEN.
  final Map<String, int> stmCpByFen = {};

  /// MultiPV discovery results keyed by FEN.
  final Map<String, DiscoveryResult> discoveryByFen = {};

  /// Every FEN handed to [evaluateFen], in call order.
  final List<String> evalCalls = [];

  /// MultiPV width of each [discoverMoves] call, in call order.
  final List<int> discoverMultiPvCalls = [];

  @override
  int get workerCount => workers;

  @override
  Future<EvalResult> evaluateFen(String fen, int depth) async {
    evalCalls.add(fen);
    final cp = stmCpByFen[fen];
    if (cp == null) {
      throw StateError('FakeStockfishPool: no scripted eval for $fen');
    }
    return EvalResult(scoreCp: cp, depth: depth);
  }

  @override
  Future<DiscoveryResult> discoverMoves({
    required String fen,
    required int depth,
    required int multiPv,
    required bool isWhiteToMove,
    void Function(DiscoveryResult)? onProgress,
  }) async {
    discoverMultiPvCalls.add(multiPv);
    final result = discoveryByFen[fen];
    if (result == null) {
      throw StateError('FakeStockfishPool: no scripted discovery for $fen');
    }
    return result;
  }
}

/// White-POV MultiPV line; [pv] starts with the move itself.
DiscoveryLine discoveryLine({
  required int pvNumber,
  required int cpWhite,
  required List<String> pv,
}) => DiscoveryLine(pvNumber: pvNumber, depth: 14, scoreCp: cpWhite, pv: pv);

class FakeMaiaEvaluator implements MaiaEvaluator {
  FakeMaiaEvaluator(this.policyByFen);

  /// Move policy per FEN; FENs not present return an empty policy.
  final Map<String, Map<String, double>> policyByFen;

  /// FENs evaluated, in call order.
  final List<String> calls = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<MaiaResult> evaluate(String fen, int elo) async {
    calls.add(fen);
    return MaiaResult(
      policy: policyByFen[fen] ?? const {},
      winProbability: 0.5,
    );
  }

  @override
  void dispose() {}
}
