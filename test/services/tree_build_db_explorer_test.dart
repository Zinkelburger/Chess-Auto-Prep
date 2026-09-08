/// `TreeBuildService.buildFromPgnFreqMap` — the DB Explorer build, driven
/// end to end from a PGN file in a temp directory.
///
/// Headless by construction: no eval provider is enabled, Maia is a fake
/// with an empty policy (so no Dirichlet smoothing), the coverage sweep is
/// off, and [EngineLifecycle] is parked in `generating` under `testMode` so
/// the build does not try to spawn engine workers (under `flutter test` the
/// default target platform is Android, and the FFI Stockfish package it would
/// pick dies asynchronously into whichever test is running). What remains is
/// exactly the frequency-map expansion, the eval enrichment from the cache,
/// and the run's lifecycle.
library;

import 'dart:io';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/eval/eval_canonicalize.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';
import 'package:chess_auto_prep/services/eval_cache.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/jobs/generation_phase.dart';
import 'package:chess_auto_prep/services/maia/maia_factory.dart';
import 'package:chess_auto_prep/services/tree_build_service.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show playUciMove;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'generation/engine_fakes.dart';

String _game(String moves, String result) =>
    '[Event "t"]\n[White "W"]\n[Black "B"]\n[Result "$result"]\n\n'
    '$moves $result\n\n';

/// Ten games: 1.e4 nine times (six ...e5, three ...c5), 1.d4 once.
String _standardPgn() {
  final b = StringBuffer();
  for (var i = 0; i < 6; i++) {
    b.write(_game('1. e4 e5 2. Nf3 Nc6', '1-0'));
  }
  for (var i = 0; i < 3; i++) {
    b.write(_game('1. e4 c5 2. Nf3', '1-0'));
  }
  b.write(_game('1. d4 d5', '0-1'));
  return b.toString();
}

TreeBuildConfig _config(
  String pgnPath, {
  bool playAsWhite = true,
  int maxPly = 4,
  int dbMinGames = 1,
  int maxNodes = 0,
}) => TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: playAsWhite,
  buildMode: BuildMode.dbExplorer,
  relativeEval: false,
  pgnFilePaths: [pgnPath],
  maxPly: maxPly,
  dbMinGames: dbMinGames,
  dbMinProb: 0.0,
  coverMinProb: 0.0,
  minProbability: 0.0001,
  maxNodes: maxNodes,
);

BuildTreeNode _child(BuildTreeNode node, String san) =>
    node.children.firstWhere((c) => c.moveSan == san);

int _deepestPly(BuildTreeNode node) {
  var deepest = node.ply;
  for (final c in node.children) {
    final d = _deepestPly(c);
    if (d > deepest) deepest = d;
  }
  return deepest;
}

List<BuildTreeNode> _nodesAtPly(BuildTreeNode node, int ply) => [
  if (node.ply == ply) node,
  for (final c in node.children) ..._nodesAtPly(c, ply),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late String pgnPath;

  setUp(() async {
    // resetForTest clears testMode, so it must come first: with testMode
    // off, enterGeneration would spawn the real pool.
    EngineLifecycle.instance.resetForTest();
    EngineLifecycle.testMode = true;
    await EngineLifecycle.instance.enterGeneration(1);
    expect(EngineLifecycle.instance.state, EngineState.generating);
    tmp = Directory.systemTemp.createTempSync('db_explorer_test');
    pgnPath = p.join(tmp.path, 'games.pgn');
    File(pgnPath).writeAsStringSync(_standardPgn());
    // Deterministic: no smoothing prior, so opponent probabilities are the
    // raw frequencies.
    MaiaFactory.testOverride = FakeMaiaEvaluator(const {});
  });

  tearDown(() {
    MaiaFactory.testOverride = null;
    EngineLifecycle.instance.resetForTest();
    EngineLifecycle.testMode = false;
    tmp.deleteSync(recursive: true);
  });

  Future<BuildTree> build(
    TreeBuildConfig config, {
    bool Function()? isCancelled,
    bool Function()? finishNow,
    void Function(String, GenerationPhase)? onStatusChanged,
    TreeBuildService? service,
  }) => (service ?? TreeBuildService()).buildFromPgnFreqMap(
    config: config,
    isCancelled: isCancelled ?? () => false,
    onProgress: (_) {},
    finishNow: finishNow,
    onStatusChanged: onStatusChanged,
  );

  test('our moves are choices, opponent replies are chances', () async {
    final service = TreeBuildService();
    final tree = await build(_config(pgnPath), service: service);
    final root = tree.root;

    expect(tree.buildComplete, isTrue);
    expect(service.isBuilding, isFalse);
    expect(service.lastGameDatabase, isNotNull);
    expect(root.totalGames, 10, reason: 'games that reached the root');

    // Our move: every recorded move, undiscounted, ordered by frequency
    // share for best-first, carrying its own game count.
    expect(root.children.map((c) => c.moveSan), unorderedEquals(['e4', 'd4']));
    final e4 = _child(root, 'e4');
    final d4 = _child(root, 'd4');
    expect(e4.moveProbability, 1.0);
    expect(e4.cumulativeProbability, 1.0);
    expect(e4.searchPriority, closeTo(0.9, 1e-9));
    expect(e4.searchPriorityDiscount, closeTo(0.9, 1e-9));
    expect(e4.totalGames, 9);
    expect(e4.whiteWins, 9);
    expect(d4.searchPriority, closeTo(0.1, 1e-9));
    expect(d4.totalGames, 1);
    expect(d4.blackWins, 1);

    // Opponent replies: raw frequencies that sum to one, multiplied into
    // the reach probability and the search priority.
    expect(e4.totalGames, 9, reason: 'position total once expanded');
    final e5 = _child(e4, 'e5');
    final c5 = _child(e4, 'c5');
    expect(e5.moveProbability, closeTo(6 / 9, 1e-9));
    expect(c5.moveProbability, closeTo(3 / 9, 1e-9));
    expect(
      e4.children.fold(0.0, (s, c) => s + c.moveProbability),
      closeTo(1.0, 1e-9),
    );
    expect(e5.cumulativeProbability, closeTo(6 / 9, 1e-9));
    expect(e5.searchPriority, closeTo(0.9 * 6 / 9, 1e-9));
    expect(e5.totalGames, 6);

    // Our reply inherits the reach probability unchanged.
    final nf3 = _child(e5, 'Nf3');
    expect(nf3.cumulativeProbability, closeTo(6 / 9, 1e-9));
    expect(nf3.searchPriority, closeTo(0.9 * 6 / 9, 1e-9));

    // The branching cap: nodes at maxPly exist, are closed, and have no
    // children.
    expect(_deepestPly(root), 4);
    expect(tree.maxPlyReached, 4);
    for (final n in _nodesAtPly(root, 4)) {
      expect(n.explored, isTrue);
      expect(n.children, isEmpty);
    }
  });

  test(
    'the min-games floor drops a thin reply without renormalising',
    () async {
      final tree = await build(_config(pgnPath, dbMinGames: 4));
      final e4 = _child(tree.root, 'e4');

      expect(e4.children.map((c) => c.moveSan), ['e5']);
      // Σp ≤ 1: the dropped mass stays in the expectimax tail term.
      expect(e4.children.single.moveProbability, closeTo(6 / 9, 1e-9));
      // Our own thin move is a choice, not a chance, and is never floored.
      expect(tree.root.children.map((c) => c.moveSan), contains('d4'));
    },
  );

  test('for a Black repertoire the root fans out as chance', () async {
    final tree = await build(_config(pgnPath, playAsWhite: false));
    final root = tree.root;

    final e4 = _child(root, 'e4');
    final d4 = _child(root, 'd4');
    expect(e4.moveProbability, closeTo(0.9, 1e-9));
    expect(d4.moveProbability, closeTo(0.1, 1e-9));
    expect(e4.cumulativeProbability, closeTo(0.9, 1e-9));
    expect(e4.totalGames, 9);

    // Now it is our move: both answers, ordered by our own practice.
    final e5 = _child(e4, 'e5');
    final c5 = _child(e4, 'c5');
    expect(e5.moveProbability, 1.0);
    expect(e5.cumulativeProbability, closeTo(0.9, 1e-9));
    expect(e5.searchPriority, closeTo(0.9 * 6 / 9, 1e-9));
    expect(c5.searchPriority, closeTo(0.9 * 3 / 9, 1e-9));
  });

  test('the node budget stops the fan-out exactly at the cap', () async {
    final tree = await build(_config(pgnPath, maxNodes: 3));

    expect(tree.totalNodes, 3);
    expect(tree.root.children, hasLength(2));
    for (final c in tree.root.children) {
      expect(c.children, isEmpty);
      expect(c.explored, isTrue);
    }
    expect(tree.buildComplete, isTrue);
  });

  test('a position reached by two move orders is expanded once', () async {
    final b = StringBuffer();
    for (var i = 0; i < 4; i++) {
      b.write(_game('1. e4 e5 2. Nf3 Nc6 3. Bb5', '1-0'));
    }
    for (var i = 0; i < 2; i++) {
      b.write(_game('1. Nf3 Nc6 2. e4 e5 3. Bb5', '1-0'));
    }
    File(pgnPath).writeAsStringSync(b.toString());

    final tree = await build(_config(pgnPath, maxPly: 6));
    final twins = _nodesAtPly(tree.root, 4);

    expect(twins, hasLength(2));
    // Same position; the halfmove clocks differ, so compare canonical keys.
    expect(twins.map((n) => canonicalizeFen4(n.fen)).toSet(), hasLength(1));
    final expanded = twins.where((n) => n.children.isNotEmpty).toList();
    expect(expanded, hasLength(1));
    expect(expanded.single.children.single.moveSan, 'Bb5');
    final leaf = twins.firstWhere((n) => n.children.isEmpty);
    expect(leaf.explored, isTrue);
  });

  test('cached evals are copied onto nodes side-to-move relative', () async {
    final afterE4 = playUciMove(kStandardStartFen, 'e2e4')!;
    final afterE4C5 = playUciMove(afterE4, 'c7c5')!;
    await EvalCache.instance.putEvalCpWhite(kStandardStartFen, 30, 30);
    await EvalCache.instance.putEvalCpWhite(afterE4, 20, 30);
    await EvalCache.instance.putEvalCpWhite(afterE4C5, 45, 30);

    final tree = await build(_config(pgnPath));
    final root = tree.root;
    final e4 = _child(root, 'e4');

    expect(root.engineEvalCp, 30);
    // Black to move after 1.e4: White's +20 is Black's -20.
    expect(e4.engineEvalCp, -20);
    expect(_child(e4, 'c5').engineEvalCp, 45);
    // Nothing cached, no engine: honestly missing rather than 0.
    expect(_child(e4, 'e5').hasEngineEval, isFalse);
    expect(_child(root, 'd4').hasEngineEval, isFalse);
  });

  test('finish-now skips the expansion but not the eval enrichment', () async {
    await EvalCache.instance.putEvalCpWhite(kStandardStartFen, 30, 30);
    final phases = <GenerationPhase>[];

    final tree = await build(
      _config(pgnPath),
      finishNow: () => true,
      onStatusChanged: (_, phase) => phases.add(phase),
    );

    expect(tree.buildComplete, isFalse);
    expect(tree.root.children, isEmpty);
    expect(tree.root.engineEvalCp, 30);
    expect(phases, [
      GenerationPhase.parsingPgn,
      GenerationPhase.buildingTree,
      GenerationPhase.enrichingEvals,
    ]);
  });

  test(
    'a hard cancel during parsing throws and releases the service',
    () async {
      final service = TreeBuildService();

      await expectLater(
        build(_config(pgnPath), isCancelled: () => true, service: service),
        throwsA(isA<BuildCancelledException>()),
      );
      expect(service.isBuilding, isFalse);
    },
  );

  test('no PGN file is a configuration error, before any run state', () async {
    final service = TreeBuildService();

    await expectLater(
      build(
        _config(pgnPath).copyWith(pgnFilePaths: const []),
        service: service,
      ),
      throwsStateError,
    );
    expect(service.isBuilding, isFalse);
  });

  test('a file with no games fails with a diagnosis', () async {
    File(pgnPath).writeAsStringSync('');
    final service = TreeBuildService();

    await expectLater(
      build(_config(pgnPath), service: service),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('No games parsed'),
        ),
      ),
    );
    expect(service.isBuilding, isFalse);
  });
}
