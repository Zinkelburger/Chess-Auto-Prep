import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/pure_tree_builder.dart';
import 'package:chess_auto_prep/services/generation/pure_position.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';
import 'engine_fakes.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/maia/maia_service.dart';
import 'pure_tree_builder_test.dart' as harness;

class _ZeroEngine extends FakeStockfishPool {
  @override
  Future<EvalResult> evaluateFen(String fen, int depth) async {
    evalCalls.add(fen);
    return EvalResult(scoreCp: 0, depth: depth, pv: const []);
  }
}

class _TwoReplyMaia implements MaiaEvaluator {
  @override
  Future<void> initialize() async {}
  @override
  void dispose() {}
  @override
  Future<MaiaResult> evaluate(String fen, int elo) async => MaiaResult(
    policy: {
      for (final move in pureLegalMoves(tryParseFen(fen)!).take(2)) move: .5,
    },
    winProbability: .5,
  );
}

void main() {
  setUp(() => MaiaFactory.testOverride = _TwoReplyMaia());
  tearDown(() => MaiaFactory.testOverride = null);
  test(
    'independent eight-ply oracle: committed choices and policy value, not full optimum',
    () {
      final cases =
          jsonDecode(
                File(
                  'test/fixtures/rolling_expectimax_oracles.json',
                ).readAsStringSync(),
              )
              as List;
      var worse = 0;
      for (final raw in cases) {
        final data = Map<String, dynamic>.from(raw as Map);
        final tree = deserializeTreeJson(data);
        final config = TreeBuildConfig.fromJson(
          Map<String, dynamic>.from(data['config'] as Map),
          startFen: tree.root.fen,
        );
        expect(config.isRollingSearch, isTrue);
        final calc = ExpectimaxCalculator(config: config);
        final nodes = <int, BuildTreeNode>{};
        void collect(BuildTreeNode n) {
          nodes[n.nodeId] = n;
          for (final c in n.children) {
            collect(c);
          }
        }

        collect(tree.root);
        for (final d in data['decisions'] as List) {
          final node = nodes[d['id']]!;
          calc.commitWindow(node, d['horizon'] as int);
          expect(node.committedMoveUci, d['uci']);
          expect(node.decisionValue, closeTo(d['value'] as num, 1e-12));
        }
        calc.calculate(tree);
        final count = RepertoireSelector(
          config: config,
          ecaCalc: calc,
        ).select(tree);
        expect(count, (data['decisions'] as List).length);
        expect(
          tree.root.expectimaxValue,
          closeTo(data['policy_value'] as num, 1e-12),
        );
        expect(tree.root.valueLower, tree.root.valueUpper);
        if ((data['full_value'] as num) >
            (data['policy_value'] as num) + 1e-6) {
          worse++;
        }
        final restored = deserializeTreeJson(serializeTreeJson(tree));
        calc.calculate(restored);
        expect(
          restored.root.expectimaxValue,
          closeTo(tree.root.expectimaxValue, 1e-12),
        );
      }
      expect(
        worse,
        greaterThan(0),
        reason:
            'The suite must expose horizon failures, not just friendly examples.',
      );
    },
  );

  test(
    'extending a short horizon reopens the truncated local decision',
    () async {
      const fen = '8/8/8/8/8/4k3/P7/4K3 w - - 0 1';
      final config = harness.base.copyWith(
        startFen: fen,
        maxPly: 2,
        evalDepth: 2,
        searchAlgorithm: SearchAlgorithm.rolling,
        maxEvalLossCp: 20000,
        useMasterGames: true,
      );
      final tree = harness.treeAt(fen);
      final engine = _ZeroEngine();
      Never book(String f) =>
          throw StateError('Fast must not query master data');
      await PureTreeBuilder(
        harness.runFor(config, tree, engine, book: book),
      ).build();
      expect(tree.root.decisionHorizon, 2);
      await PureTreeBuilder(
        harness.runFor(config.copyWith(maxPly: 4), tree, engine, book: book),
      ).build();
      expect(tree.buildComplete, isTrue);
      expect(tree.root.decisionHorizon, 4);
      final calc = ExpectimaxCalculator(config: config.copyWith(maxPly: 4));
      calc.calculate(tree);
      expect(tree.root.valueLower, tree.root.valueUpper);
      expect(
        () => ExpectimaxCalculator(
          config: config.copyWith(
            maxPly: 4,
            searchAlgorithm: SearchAlgorithm.pure,
          ),
        ).calculate(tree),
        throwsStateError,
      );
    },
  );

  test(
    'real legal builder extends all Maia replies, resumes without early commitments',
    () async {
      const fen = '8/8/8/8/8/4k3/P7/4K3 w - - 0 1';
      final config = harness.base.copyWith(
        startFen: fen,
        maxPly: 6,
        evalDepth: 2,
        searchAlgorithm: SearchAlgorithm.rolling,
        maxEvalLossCp: 20000,
        useMasterGames: true,
      );
      final tree = harness.treeAt(fen);
      final engine = _ZeroEngine();
      Never book(String f) =>
          throw StateError('Fast must not query master data');
      await PureTreeBuilder(
        harness.runFor(config.copyWith(maxNodes: 10), tree, engine, book: book),
      ).build();
      expect(tree.buildComplete, isFalse);
      expect(tree.root.committedMoveUci, isEmpty);
      final partial = ExpectimaxCalculator(config: config);
      partial.calculate(tree);
      expect(
        RepertoireSelector(config: config, ecaCalc: partial).select(tree),
        0,
      );
      expect(tree.root.valueLower, 0);
      expect(tree.root.valueUpper, 1);
      await PureTreeBuilder(
        harness.runFor(config, tree, engine, book: book),
      ).build();
      expect(tree.buildComplete, isTrue);
      partial.calculate(tree);
      RepertoireSelector(config: config, ecaCalc: partial).select(tree);
      void check(BuildTreeNode n) {
        if (n.terminalValue != null || n.ply >= config.maxPly) return;
        if (n.isWhiteToMove == config.playAsWhite) {
          expect(n.committedMoveUci, isNotEmpty);
          expect(n.decisionHorizon, (n.ply + 4).clamp(0, config.maxPly));
          check(n.children.singleWhere((c) => c.isRepertoireMove));
        } else {
          expect(
            n.children.length,
            pureLegalMoves(tryParseFen(n.fen)!).take(2).length,
          );
          for (final c in n.children) {
            expect(c.totalGames, 0);
            check(c);
          }
        }
      }

      check(tree.root);
      expect(LineExtractor(config: config).extract(tree), isNotEmpty);
      final frozen = tree.root.committedMoveUci;
      final restored = deserializeTreeJson(serializeTreeJson(tree));
      await PureTreeBuilder(
        harness.runFor(config, restored, engine, book: book),
      ).build();
      expect(restored.root.committedMoveUci, frozen);
      await expectLater(
        PureTreeBuilder(
          harness.runFor(
            config.copyWith(searchAlgorithm: SearchAlgorithm.pure),
            restored,
            engine,
            book: book,
          ),
        ).build(),
        throwsStateError,
      );
    },
  );
}
