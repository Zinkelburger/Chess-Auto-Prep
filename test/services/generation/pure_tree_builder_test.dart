import 'package:flutter_test/flutter_test.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/build_run.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/pure_tree_builder.dart';
import 'package:chess_auto_prep/services/generation/pure_position.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/services/generation/run_debug_dump.dart';
import 'package:chess_auto_prep/services/generation/tree_build_progress.dart';
import 'package:chess_auto_prep/services/generation/tree_eval_resolver.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart';
import 'engine_fakes.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';

BuildTree treeAt(String fen) => BuildTree(
  root: BuildTreeNode(
    fen: fen,
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: tryParseFen(fen)!.turn == Side.white,
    nodeId: 1,
  ),
  totalNodes: 1,
);
BuildRun runFor(
  TreeBuildConfig config,
  BuildTree tree,
  FakeStockfishPool pool, {
  BookLookup? book,
  BuildCancellation? cancel,
}) {
  final stats = BuildStats();
  var nextId = 1;
  void scan(BuildTreeNode n) {
    if (n.nodeId >= nextId) nextId = n.nodeId + 1;
    for (final c in n.children) {
      scan(c);
    }
  }

  scan(tree.root);
  return BuildRun(
    config: config,
    tree: tree,
    fenMap: FenMap(),
    pool: pool,
    evalResolver: TreeEvalResolver()..stats = stats,
    stats: stats,
    runLog: RunDebugLog(),
    progress: TreeBuildProgressTracker(),
    onProgress: (_) {},
    cancel: cancel ?? BuildCancellation(),
    finishNow: () => false,
    waitIfPaused: () async {},
    nextNodeId: nextId,
    masterBook: book,
  );
}

const base = TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  maxPly: 1,
  maxEvalLossCp: 1000,
);
BookMove bookMove(String uci, int n) => BookMove(
  uci: uci,
  games: n,
  whiteWins: n,
  draws: 0,
  blackWins: 0,
  averageElo: 2400,
  maxElo: 2500,
  lastYear: 2026,
  topGameId: 1,
  recentGameId: 1,
);
void main() {
  tearDown(() => MaiaFactory.testOverride = null);
  test(
    'bounded database unions four engine candidates with likely Maia moves',
    () async {
      final tree = treeAt(kStandardStartFen);
      final pool = FakeStockfishPool();
      const selected = ['e2e4', 'd2d4', 'c2c4', 'g1f3'];
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        tree.root.fen: {'b1c3': .6, 'e2e4': .4},
      });
      pool.discoveryByFen[tree.root.fen] = DiscoveryResult(
        lines: [
          for (var i = 0; i < selected.length; i++)
            discoveryLine(pvNumber: i + 1, cpWhite: 10 - i, pv: [selected[i]]),
        ],
        depth: 14,
      );
      for (final move in [...selected, 'b1c3']) {
        pool.stmCpByFen[playUciMove(tree.root.fen, move)!] = 0;
      }
      final config = base.copyWith(
        boundedDatabase: true,
        ourMultipv: 4,
        oppMassTarget: .6,
      );
      await PureTreeBuilder(runFor(config, tree, pool)).build();
      expect(pool.discoverMultiPvCalls, [4]);
      expect(pool.evalCalls, hasLength(5));
      expect(
        tree.root.children.map((n) => n.moveUci),
        unorderedEquals([...selected, 'b1c3']),
      );
      expect(
        TreeBuildConfig.fromJson(
          config.toJson(),
          startFen: config.startFen,
        ).boundedDatabase,
        isTrue,
      );
    },
  );

  test(
    'bounded Maia replies reach coverage and retain omitted probability bounds',
    () async {
      final fen = playUciMove(kStandardStartFen, 'e2e4')!;
      final tree = treeAt(fen);
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        fen: {'e7e5': .4, 'c7c5': .3, 'e7e6': .2, 'c7c6': .1},
      });
      final pool = FakeStockfishPool();
      pool.discoveryByFen[fen] = DiscoveryResult(
        lines: [
          discoveryLine(pvNumber: 1, cpWhite: 0, pv: ['e7e6']),
        ],
        depth: 14,
      );
      for (final move in ['e7e5', 'c7c5', 'e7e6']) {
        pool.stmCpByFen[playUciMove(fen, move)!] = 0;
      }
      final config = base.copyWith(
        startFen: fen,
        boundedDatabase: true,
        oppMassTarget: .6,
      );
      await PureTreeBuilder(runFor(config, tree, pool)).build();
      expect(
        tree.root.children.map((n) => n.moveUci),
        unorderedEquals(['e7e5', 'c7c5', 'e7e6']),
      );
      expect(
        tree.root.children.fold<double>(0, (a, n) => a + n.moveProbability),
        closeTo(.9, 1e-8),
      );
      ExpectimaxCalculator(config: config).calculate(tree);
      expect(tree.root.valueUpper - tree.root.valueLower, closeTo(.1, 1e-8));
    },
  );

  test('the safety limit is measured against every legal move', () async {
    final tree = treeAt(kStandardStartFen);
    final pool = FakeStockfishPool();
    for (final move in pureLegalMoves(Chess.initial)) {
      pool.stmCpByFen[playUciMove(tree.root.fen, move)!] = move == 'e2e4'
          ? -100
          : 0;
    }
    final config = base.copyWith(maxEvalLossCp: 30);
    await PureTreeBuilder(runFor(config, tree, pool)).build();
    expect(pool.evalCalls, hasLength(20));
    expect(tree.root.children.single.moveUci, 'e2e4');
    expect(tree.root.children.single.engineEvalCp, -100);
    ExpectimaxCalculator(config: config).calculate(tree);
    expect(tree.root.expectimaxValue, greaterThan(.5));
  });
  test(
    'enumerates every legal root move, fixed depth, no MultiPV cap',
    () async {
      final tree = treeAt(kStandardStartFen);
      final pool = FakeStockfishPool();
      for (final m in pureLegalMoves(Chess.initial)) {
        pool.stmCpByFen[playUciMove(tree.root.fen, m)!] = 0;
      }
      await PureTreeBuilder(
        runFor(
          base.copyWith(ourMultipv: 1, setupMoves: 'e4', noveltyWeight: 100),
          tree,
          pool,
        ),
      ).build();
      expect(tree.buildComplete, isTrue);
      expect(tree.root.children, hasLength(20));
      expect(pool.evalCalls, hasLength(20));
      final calc = ExpectimaxCalculator(config: base);
      calc.calculate(tree);
      RepertoireSelector(config: base, ecaCalc: calc).select(tree);
      expect(
        tree.root.children.singleWhere((c) => c.isRepertoireMove).moveUci,
        'a2a3',
      );
      expect(tree.root.valueLower, .5);
      expect(tree.root.valueUpper, .5);
    },
  );
  test(
    'atomic budget leaves unresolved bounds and resumes to the same answer',
    () async {
      final tree = treeAt(kStandardStartFen);
      final pool = FakeStockfishPool();
      for (final m in pureLegalMoves(Chess.initial)) {
        pool.stmCpByFen[playUciMove(tree.root.fen, m)!] = 0;
      }
      await PureTreeBuilder(
        runFor(base.copyWith(maxNodes: 10), tree, pool),
      ).build();
      expect(tree.root.children, isEmpty);
      expect(tree.buildComplete, isFalse);
      expect(pool.evalCalls, isEmpty);
      ExpectimaxCalculator(config: base).calculate(tree);
      expect(tree.root.valueLower, 0);
      expect(tree.root.valueUpper, 1);
      await PureTreeBuilder(runFor(base, tree, pool)).build();
      expect(tree.buildComplete, isTrue);
      expect(tree.root.children, hasLength(20));
      await expectLater(
        PureTreeBuilder(
          runFor(base.copyWith(evalDepth: 25), tree, pool),
        ).build(),
        throwsStateError,
      );
    },
  );
  test('legacy master targeting cannot alter the Maia policy', () async {
    final fen = playUciMove(kStandardStartFen, 'e2e4')!;
    final tree = treeAt(fen);
    final pool = FakeStockfishPool();
    final maia = FakeMaiaEvaluator({
      fen: {'e7e5': .9, 'c7c5': .1},
    });
    MaiaFactory.testOverride = maia;
    for (final m in ['e7e5', 'c7c5']) {
      pool.stmCpByFen[playUciMove(fen, m)!] = 0;
    }
    final config = base.copyWith(
      startFen: fen,
      oppMaxChildren: 1,
      oppMassTarget: .5,
      maiaMinProb: .99,
      minProbability: .99,
    );
    await PureTreeBuilder(
      runFor(
        config,
        tree,
        pool,
        book: (_) => [bookMove('e7e5', 999999), bookMove('c7c5', 1)],
      ),
    ).build();
    expect(tree.buildComplete, isTrue);
    expect(maia.calls, isNotEmpty);
    expect(tree.root.children, hasLength(2));
    expect(
      tree.root.children.firstWhere((c) => c.moveUci == 'c7c5').moveProbability,
      closeTo(.1, 1e-15),
    );
    ExpectimaxCalculator(config: config).calculate(tree);
    expect(tree.root.expectimaxValue, .5);
    expect(tree.configSnapshot['use_master_games'], isFalse);
    tree.configSnapshot['opponent_book_source'] = 'local-master-book';
    await expectLater(
      PureTreeBuilder(runFor(config, tree, pool)).build(),
      throwsStateError,
    );
  });
  test(
    'Maia is normalized over legal support without querying the database',
    () async {
      final fen = playUciMove(kStandardStartFen, 'e2e4')!;
      final tree = treeAt(fen);
      final pool = FakeStockfishPool();
      MaiaFactory.testOverride = FakeMaiaEvaluator({
        fen: {'e7e5': 2, 'c7c5': 1, 'a1a8': 100},
      });
      for (final m in ['e7e5', 'c7c5']) {
        pool.stmCpByFen[playUciMove(fen, m)!] = 0;
      }
      await PureTreeBuilder(
        runFor(
          base.copyWith(startFen: fen, useMasterGames: true),
          tree,
          pool,
          book: (_) => throw StateError('must not query'),
        ),
      ).build();
      expect(
        tree.root.children
            .firstWhere((c) => c.moveUci == 'e7e5')
            .moveProbability,
        closeTo(2 / 3, 1e-15),
      );
    },
  );
  test(
    'rejects malformed positions and unavailable policy instead of silently substituting',
    () async {
      final tree = treeAt(playUciMove(kStandardStartFen, 'e2e4')!);
      MaiaFactory.testOverride = FakeMaiaEvaluator({});
      await expectLater(
        PureTreeBuilder(
          runFor(
            base.copyWith(startFen: tree.root.fen, useMasterGames: false),
            tree,
            FakeStockfishPool(),
          ),
        ).build(),
        throwsStateError,
      );
      expect(tree.buildComplete, isFalse);
      expect(tree.root.children, isEmpty);
    },
  );
  test(
    'legal promotions, terminal precedence, en passant and repetition histories',
    () {
      final promotion = tryParseFen('4k3/P7/8/8/8/8/8/4K3 w - - 0 1')!;
      expect(
        pureLegalMoves(promotion).where((m) => m.startsWith('a7a8')),
        hasLength(4),
      );
      final mate = treeAt('7k/6Q1/5K2/8/8/8/8/8 b - - 100 1').root;
      expect(pureTerminal(mate, tryParseFen(mate.fen)!, true), 1);
      final a = tryParseFen('4k3/8/8/8/4P3/8/8/4K3 b - e3 0 1')!;
      final b = tryParseFen('4k3/8/8/8/4P3/8/8/4K3 b - - 0 1')!;
      expect(pureRepetitionKey(a), pureRepetitionKey(b));
      var node = treeAt(kStandardStartFen).root;
      for (final uci in [
        'g1f3',
        'g8f6',
        'f3g1',
        'f6g8',
        'g1f3',
        'g8f6',
        'f3g1',
        'f6g8',
      ]) {
        final fen = playUciMove(node.fen, uci)!;
        node = BuildTreeNode(
          fen: fen,
          moveSan: '',
          moveUci: uci,
          ply: node.ply + 1,
          isWhiteToMove: !node.isWhiteToMove,
          nodeId: node.nodeId + 1,
          parent: node,
        );
      }
      expect(pureTerminal(node, tryParseFen(node.fen)!, true), .5);
      final isolated = treeAt(node.fen).root;
      expect(pureTerminal(isolated, tryParseFen(isolated.fen)!, true), isNull);
    },
  );
  test('rejects excess probability and incomplete normalized chance nodes', () {
    final tree = treeAt(playUciMove(kStandardStartFen, 'e2e4')!);
    tree.root.historyAware = true;
    tree.root.explored = true;
    for (final uci in ['e7e5', 'c7c5']) {
      tree.root.children.add(
        BuildTreeNode(
          fen: playUciMove(tree.root.fen, uci)!,
          moveSan: '',
          moveUci: uci,
          ply: 1,
          isWhiteToMove: true,
          nodeId: tree.root.children.length + 2,
          parent: tree.root,
          moveProbability: .75,
        )..engineEvalCp = 0,
      );
    }
    expect(
      () => ExpectimaxCalculator(config: base).calculate(tree),
      throwsStateError,
    );
    for (final c in tree.root.children) {
      c.moveProbability = .25;
    }
    expect(
      () => ExpectimaxCalculator(config: base).calculate(tree),
      throwsStateError,
    );
  });
}
