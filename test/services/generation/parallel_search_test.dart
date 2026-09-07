import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/generation/build_run.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/pure_tree_builder.dart';
import 'package:chess_auto_prep/services/generation/pure_position.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/maia/maia_service.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';
import 'engine_fakes.dart';
import 'pure_tree_builder_test.dart' as harness;

class _Engine extends FakeStockfishPool {
  _Engine(int workers, {this.limit, this.fail = false, this.onStart})
    : super(workers: workers);
  final int? limit;
  final bool fail;
  final void Function()? onStart;
  int active = 0, peak = 0, whiteActive = 0, whitePeak = 0;
  final finished = <String>[];
  @override
  int get concurrencyLimit => limit ?? workers;
  @override
  Future<EvalResult> evaluateFen(String fen, int depth) async {
    final index = evalCalls.length;
    evalCalls.add(fen);
    active++;
    peak = active > peak ? active : peak;
    final white = fen.split(' ')[1] == 'w';
    if (white) whiteActive++;
    whitePeak = whiteActive > whitePeak ? whiteActive : whitePeak;
    try {
      onStart?.call();
      // Deliberately complete later submissions first.
      await Future<void>.delayed(Duration(milliseconds: index.isEven ? 3 : 1));
      if (fail && index == 0) throw StateError('engine failed');
      finished.add(fen);
      final score = fen.codeUnits.fold(0, (a, b) => a + b) % 101 - 50;
      return EvalResult(scoreCp: score, depth: depth, pv: const []);
    } finally {
      active--;
      if (white) whiteActive--;
    }
  }
}

class _Maia implements MaiaEvaluator {
  @override
  Future<void> initialize() async {}
  @override
  void dispose() {}
  @override
  Future<MaiaResult> evaluate(String fen, int elo) async {
    final legal = pureLegalMoves(tryParseFen(fen)!).take(2).toList();
    return MaiaResult(
      policy: {for (final move in legal) move: 1 / legal.length},
      winProbability: .5,
    );
  }
}

const _pawn = '8/8/8/8/8/4k3/P7/4K3 w - - 0 1';

void main() {
  setUp(() => MaiaFactory.testOverride = _Maia());
  tearDown(() => MaiaFactory.testOverride = null);
  for (final method in [SearchAlgorithm.pure, SearchAlgorithm.rolling]) {
    test(
      '$method: parallel completion order preserves the full tree and decisions',
      () async {
        Object? reference;
        for (final workers in [1, 4]) {
          final config = harness.base.copyWith(
            startFen: _pawn,
            maxPly: 5,
            maxEvalLossCp: 40,
            searchAlgorithm: method,
            engineThreads: workers,
          );
          final tree = harness.treeAt(_pawn);
          final pool = _Engine(workers);
          await PureTreeBuilder(harness.runFor(config, tree, pool)).build();
          ExpectimaxCalculator(config: config).calculate(tree);
          expect(tree.buildComplete, isTrue);
          expect(pool.active, 0);
          expect(pool.peak, workers);
          final result = serializeTreeJson(tree)['tree'];
          if (workers == 1) {
            reference = result;
          } else {
            expect(result, reference);
            expect(pool.finished, isNot(pool.evalCalls));
          }
        }
      },
    );
    test('$method: old inference policies cannot silently resume', () async {
      final config = harness.base.copyWith(searchAlgorithm: method);
      final tree = harness.treeAt(config.startFen);
      await PureTreeBuilder(harness.runFor(config, tree, _Engine(1))).build();
      tree.configSnapshot.remove('maia_policy_version');
      await expectLater(
        PureTreeBuilder(harness.runFor(config, tree, _Engine(4))).build(),
        throwsStateError,
      );
    });
    test(
      '$method: horizon leaves use workers and respect the active pool limit',
      () async {
        final config = harness.base.copyWith(
          maxPly: 2,
          searchAlgorithm: method,
          engineThreads: 8,
        );
        final pool = _Engine(8, limit: 2);
        final tree = harness.treeAt(config.startFen);
        await PureTreeBuilder(harness.runFor(config, tree, pool)).build();
        expect(tree.buildComplete, isTrue);
        expect(pool.peak, 2);
        // At H2 the root candidates are Black-to-move; White-to-move
        // evaluations can only be leaves below the Maia reply nodes.
        expect(pool.whitePeak, 2);
      },
    );
    test(
      '$method: cancellation drains workers, leaves no partial action set, and resumes',
      () async {
        final cancel = BuildCancellation();
        final config = harness.base.copyWith(
          searchAlgorithm: method,
          engineThreads: 4,
        );
        final tree = harness.treeAt(config.startFen);
        late _Engine pool;
        pool = _Engine(
          4,
          onStart: () {
            if (pool.active == 4) cancel.requestStop();
          },
        );
        await PureTreeBuilder(
          harness.runFor(config, tree, pool, cancel: cancel),
        ).build();
        expect(pool.active, 0);
        expect(pool.evalCalls, hasLength(4));
        expect(tree.root.children, isEmpty);
        expect(tree.root.committedMoveUci, isEmpty);
        expect(tree.buildComplete, isFalse);
        final resumed = _Engine(4);
        await PureTreeBuilder(harness.runFor(config, tree, resumed)).build();
        final fresh = harness.treeAt(config.startFen);
        await PureTreeBuilder(
          harness.runFor(config, fresh, _Engine(1)),
        ).build();
        ExpectimaxCalculator(config: config).calculate(tree);
        ExpectimaxCalculator(config: config).calculate(fresh);
        // Cancelled detached candidates consume IDs, but cannot change the policy.
        expect(tree.root.expectimaxValue, fresh.root.expectimaxValue);
        expect(tree.root.committedMoveUci, fresh.root.committedMoveUci);
        expect(
          tree.root.children.map((n) => n.moveUci),
          fresh.root.children.map((n) => n.moveUci),
        );
        expect(tree.buildComplete, isTrue);
      },
    );
    test(
      '$method: failed evaluation drains other workers before throwing',
      () async {
        final config = harness.base.copyWith(
          searchAlgorithm: method,
          engineThreads: 4,
        );
        final tree = harness.treeAt(config.startFen);
        final pool = _Engine(4, fail: true);
        await expectLater(
          PureTreeBuilder(harness.runFor(config, tree, pool)).build(),
          throwsStateError,
        );
        expect(pool.active, 0);
        expect(pool.evalCalls.length, lessThan(20));
        expect(tree.root.children, isEmpty);
        expect(tree.buildComplete, isFalse);
        expect(tree.root.committedMoveUci, isEmpty);
      },
    );
  }
}
