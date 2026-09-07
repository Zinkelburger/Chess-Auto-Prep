/// A Stockfish pool whose searches are scripted per FEN, for driving the
/// tactics mining pass offline.
///
/// The generation pipeline's [FakeStockfishPool] (test/services/generation/
/// engine_fakes.dart) scripts the *pool-level* entry points, which is what
/// that pipeline calls. The tactics pass instead fans work out with
/// [StockfishPool.forEachParallel] and searches on the [EvalWorker] it is
/// handed, so it needs a worker — hence this second fake rather than a
/// widening of that one.
///
/// One lane, in order: the real pass distributes a game's positions across
/// every worker, and a single sequential lane makes that fan-out
/// deterministic without changing any decision it takes.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:chess_auto_prep/features/tactics/models/tactics_note.dart'
    show lichessWinChanceMultiplier;
import 'package:chess_auto_prep/services/engine/engine_connection.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:dartchess/dartchess.dart';

/// One scripted search result, in the engine's own side-to-move perspective.
typedef Eval = ({int? cp, int? mate, List<String> pv});

/// A centipawn score for the side to move, with the line it would play.
Eval cp(int score, {List<String> pv = const []}) =>
    (cp: score, mate: null, pv: pv);

/// A forced mate in [moves] for the side to move — `scoreMate` set and
/// `scoreCp` null, the way Stockfish announces one. The case that separates
/// code reading `effectiveCp` from code reading `scoreCp` raw.
Eval mateIn(int moves, {List<String> pv = const []}) =>
    (cp: null, mate: moves, pv: pv);

/// An engine that never says anything and never dies.
class SilentEngine implements EngineConnection {
  final _out = StreamController<String>.broadcast();
  final _never = Completer<void>();

  @override
  Stream<String> get stdout => _out.stream;

  @override
  Future<void> waitForReady() async {}

  @override
  void sendCommand(String command) {}

  @override
  void dispose() {
    unawaited(_out.close());
  }

  @override
  Future<void> get done => _never.future;
}

/// An [EvalWorker] whose every search is looked up in [script].
///
/// An unscripted FEN throws, so a test can never quietly pass on a default —
/// and, just as usefully, a search the pass was supposed to *skip* fails loudly
/// instead of silently succeeding.
class ScriptedWorker extends EvalWorker {
  ScriptedWorker() : super(SilentEngine());

  final Map<String, Eval> script = {};

  /// Every FEN searched, in order.
  final List<String> searched = [];

  /// Called with each FEN as the search starts — a hook for raising a cancel
  /// in the middle of a game.
  void Function(String fen)? onSearch;

  int stops = 0;

  @override
  Future<EvalResult> evaluateFen(String fen, int depth) async {
    searched.add(fen);
    onSearch?.call(fen);
    final eval = script[fen];
    if (eval == null) {
      throw StateError('ScriptedWorker: no scripted eval for $fen');
    }
    return EvalResult(
      scoreCp: eval.cp,
      scoreMate: eval.mate,
      pv: eval.pv,
      depth: depth,
    );
  }

  @override
  void stop() => stops++;

  @override
  Future<void> setThreads(int threads) async {}
}

class ScriptedPool extends StockfishPool {
  ScriptedPool(this.worker) : super.fresh();

  final ScriptedWorker worker;
  int stopAllCalls = 0;

  @override
  int get workerCount => 1;

  @override
  int get concurrencyLimit => 1;

  @override
  Future<void> ensureWorkers([int? count, int? threadsPerWorker]) async {}

  @override
  Future<void> reconfigureAllWorkers(int threads) async {}

  @override
  void stopAll() => stopAllCalls++;

  @override
  Future<void> forEachParallel<T>(
    List<T> items,
    Future<void> Function(EvalWorker worker, T item) task, {
    bool Function()? stopWhen,
  }) async {
    for (final item in items) {
      if (stopWhen?.call() ?? false) return;
      await task(worker, item);
    }
  }
}

// ── Winning chances, the miner's own scale ─────────────────────────────────

/// The Lichess winning chance of [centipawns], as the miner computes it —
/// the same clamp and the same multiplier as `_winningChances`.
double winningChance(int centipawns) {
  final capped = centipawns.clamp(-1000, 1000);
  return 2 / (1 + math.exp(lichessWinChanceMultiplier * capped)) - 1;
}

/// The winning chances one move gave away, when the position before it was
/// dead level: [cpAfterFromUser] is the post-move score from the *user's*
/// point of view, and the pre-move score is a scripted `cp(0)`, whose winning
/// chance is exactly 0.0.
///
/// Written as the subtraction the miner performs, not as an equivalent of it,
/// so the two agree to the last bit at a threshold.
double lostChances(int cpAfterFromUser) => 0.0 - winningChance(cpAfterFromUser);

/// The two adjacent post-move scores that straddle a loss of [target] winning
/// chances: on [keeps] the move falls just short of the threshold, on [loses]
/// it just reaches it.
///
/// One centipawn moves the winning chance by well under a thousandth, so a
/// classification threshold that shifted at all lands between this pair —
/// which is what makes a test built on them a boundary test rather than a
/// test of some comfortable value near the boundary.
({int keeps, int loses}) straddleLoss(double target) {
  for (var cp = 0; cp >= -1000; cp--) {
    if (lostChances(cp) >= target) return (keeps: cp + 1, loses: cp);
  }
  throw ArgumentError('no score loses $target winning chances');
}

/// The FEN reached by playing [sanMoves] from the standard start.
String fenAfter(List<String> sanMoves) {
  Position pos = Chess.initial;
  for (final san in sanMoves) {
    final move = pos.parseSan(san);
    if (move == null) throw ArgumentError('illegal move $san in $sanMoves');
    pos = pos.play(move);
  }
  return pos.fen;
}
