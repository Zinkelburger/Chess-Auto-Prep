/// End-to-end tests for [TrickHuntService.hunt] against a real opening tree
/// and a scripted engine.
///
/// A "trick" is a move for the TRICKSTER — the side opposite the tree's owner
/// — that is close enough to the engine best to be affordable, but that the
/// owner is expected to misplay against. The hunt is three stages: an
/// engine-free walk collecting trickster-to-move positions, MultiPV discovery
/// on the most reachable of them, and an expectimax probe per candidate.
///
/// Stages A and B are pinned here. Stage C builds a real expectimax tree
/// through a `TreeBuildService` the service constructs itself, so these runs
/// keep the probe budget at zero; see the note in the report accompanying
/// this file.
library;

import 'package:chess_auto_prep/features/tricks/services/trick_hunt_config.dart';
import 'package:chess_auto_prep/features/tricks/services/trick_hunt_service.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/eval_cache.dart';
import 'package:chess_auto_prep/services/opening_tree_builder.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/hunt_harness.dart';
import '../../support/scripted_engine.dart';

/// A White player's games: after 1.e4 e5 they play 2.Nf3 three times and
/// 2.Bc4 once, so their own branching attenuates reach and Black's does not.
const _games = [
  '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0',
  '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0',
  '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0',
  '[Result "0-1"]\n\n1. e4 e5 2. Bc4 Nf6 0-1',
];

Future<OpeningTree> _build(List<String> games) => OpeningTreeBuilder.buildTree(
  pgnList: games,
  username: '',
  userIsWhite: true,
  strictPlayerMatching: false,
  maxDepth: 12,
);

void main() {
  late OpeningTree tree;
  late ScriptedEngine engine;
  late TrickHuntService service;

  OpeningTreeNode at(List<String> path) {
    var node = tree.root;
    for (final san in path) {
      node = node.children[san]!;
    }
    return node;
  }

  void scriptDiscovery(OpeningTreeNode node, List<ScriptLine> lines) =>
      engine.discovery[normalizeFen(node.fen)] = lines;

  /// The positions discovery actually searched, in order, as tree nodes.
  List<String> searchedKeys() =>
      engine.discoverySearches.map(normalizeFen).toList();

  /// Probe budget zero keeps stage C — which needs a real tree build — out.
  TrickHuntConfig config({
    int maxPly = 30,
    double minReachProb = 0.0,
    int maxDiscoveryNodes = 10,
    int discoveryDepth = 14,
    int probeBudget = 0,
  }) => TrickHuntConfig(
    maxPly: maxPly,
    minReachProb: minReachProb,
    maxDiscoveryNodes: maxDiscoveryNodes,
    discoveryDepth: discoveryDepth,
    probeBudget: probeBudget,
  );

  setUpAll(() async {
    await initTestSqlite();
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await clearEvalCache();
    engine = ScriptedEngine();
    await installScriptedWorker(engine);
    service = TrickHuntService();
    useMaia(FakeMaia());
    tree = await _build(_games);
  });

  tearDown(() {
    useMaia(null);
    resetPool();
  });

  group('the Maia gate', () {
    test('a model that will not load spends no engine time at all', () async {
      final maia = FakeMaia(failInit: true);
      useMaia(maia);

      final result = await service.hunt(
        tree: tree,
        playerIsWhite: true,
        config: config(),
      );

      expect(service.probesSkipped, isTrue);
      expect(maia.initializeCalls, 1);
      expect(result.findings, isEmpty);
      // The walk itself never happened, so no counter moved…
      expect(result.nodesChecked, 0);
      expect(result.ourMoveNodesChecked, 0);
      // …and, the point of the gate, Stockfish was never asked anything.
      expect(engine.commands.where((c) => c.startsWith('go ')), isEmpty);
    });

    test('a model that loads lets the hunt proceed', () async {
      final maia = FakeMaia();
      useMaia(maia);

      final result = await service.hunt(
        tree: tree,
        playerIsWhite: true,
        config: config(),
      );

      expect(service.probesSkipped, isFalse);
      expect(maia.initializeCalls, 1);
      expect(result.nodesChecked, 7);
    });
  });

  group('which positions get discovery', () {
    test('only trickster-to-move positions, most reachable first', () async {
      final result = await service.hunt(
        tree: tree,
        playerIsWhite: true,
        config: config(),
      );

      // Black to move, in descending reach: after 1.e4 (1.0), after 2.Nf3
      // (0.75, three games of four), after 2.Bc4 (0.25).
      expect(searchedKeys(), [
        normalizeFen(at(['e4']).fen),
        normalizeFen(at(['e4', 'e5', 'Nf3']).fen),
        normalizeFen(at(['e4', 'e5', 'Bc4']).fen),
      ]);
      // The owner's own turns are never trick candidates.
      expect(searchedKeys(), isNot(contains(normalizeFen(tree.root.fen))));
      expect(
        searchedKeys(),
        isNot(contains(normalizeFen(at(['e4', 'e5']).fen))),
      );

      expect(result.nodesChecked, 7, reason: 'every node was walked');
      expect(result.ourMoveNodesChecked, 3, reason: 'three discovery searches');
      expect(result.evalCacheMisses, 3);
      expect(result.leafNodesChecked, 0, reason: 'no probes were budgeted');
    });

    test('the reach floor drops positions below it', () async {
      await service.hunt(
        tree: tree,
        playerIsWhite: true,
        config: config(minReachProb: 0.3),
      );

      // 0.25 for the 2.Bc4 branch is under the floor; 0.75 is not.
      expect(searchedKeys(), [
        normalizeFen(at(['e4']).fen),
        normalizeFen(at(['e4', 'e5', 'Nf3']).fen),
      ]);
    });

    test('the reach floor is inclusive at its edge', () async {
      await service.hunt(
        tree: tree,
        playerIsWhite: true,
        config: config(minReachProb: 0.25),
      );

      expect(searchedKeys(), hasLength(3));
    });

    test('the node cap keeps only the most reachable', () async {
      await service.hunt(
        tree: tree,
        playerIsWhite: true,
        config: config(maxDiscoveryNodes: 1),
      );

      expect(searchedKeys(), [
        normalizeFen(at(['e4']).fen),
      ]);
    });

    test('a Black player makes White the trickster', () async {
      await service.hunt(tree: tree, playerIsWhite: false, config: config());

      // Every White-to-move node, leaves included — the leaves are how the
      // hunt reaches past the recorded games.
      expect(searchedKeys(), [
        normalizeFen(tree.root.fen),
        normalizeFen(at(['e4', 'e5']).fen),
        normalizeFen(at(['e4', 'e5', 'Nf3', 'Nc6']).fen),
        normalizeFen(at(['e4', 'e5', 'Bc4', 'Nf6']).fen),
      ]);
    });

    test('maxPly stops the walk before the deeper targets', () async {
      final result = await service.hunt(
        tree: tree,
        playerIsWhite: true,
        config: config(maxPly: 1),
      );

      expect(
        result.nodesChecked,
        2,
        reason: 'root and the position after 1.e4',
      );
      expect(searchedKeys(), [
        normalizeFen(at(['e4']).fen),
      ]);
    });

    test('a tree with no games has nothing to trick', () async {
      tree = await _build(const []);

      final result = await service.hunt(
        tree: tree,
        playerIsWhite: true,
        config: config(),
      );

      expect(result.nodesChecked, 1);
      expect(result.ourMoveNodesChecked, 0);
      expect(result.findings, isEmpty);
      expect(service.probesSkipped, isFalse);
      expect(engine.discoverySearches, isEmpty);
    });
  });

  group('discovery results', () {
    test('the best line is cached White-normalised', () async {
      final e4 = at(['e4']);
      // Black is to move here, so +40 in the engine's own terms is -40 for
      // White. Passing the wrong side-to-move flag would store +40.
      scriptDiscovery(e4, const [
        ScriptLine.cp(40, pv: ['c7c5']),
        ScriptLine.cp(10, pv: ['e7e5']),
      ]);

      await service.hunt(
        tree: tree,
        playerIsWhite: true,
        config: config(maxDiscoveryNodes: 1, discoveryDepth: 14),
      );

      expect(
        await EvalCache.instance.getEvalCpWhite(e4.fen, minDepth: 14),
        -40,
      );
    });

    test('a White trickster\'s best line keeps its sign', () async {
      scriptDiscovery(tree.root, const [
        ScriptLine.cp(35, pv: ['e2e4']),
        ScriptLine.cp(20, pv: ['d2d4']),
      ]);

      await service.hunt(
        tree: tree,
        playerIsWhite: false,
        config: config(maxDiscoveryNodes: 1, discoveryDepth: 14),
      );

      expect(
        await EvalCache.instance.getEvalCpWhite(tree.root.fen, minDepth: 14),
        35,
      );
    });

    test(
      'a position the engine has nothing to say about is survivable',
      () async {
        // Nothing is scripted: every discovery comes back with no lines.
        final result = await service.hunt(
          tree: tree,
          playerIsWhite: true,
          config: config(),
        );

        expect(result.findings, isEmpty);
        expect(result.ourMoveNodesChecked, 3);
      },
    );
  });

  test('cancelling stops discovery at the next position', () async {
    final result = await service.hunt(
      tree: tree,
      playerIsWhite: true,
      config: config(),
      onProgress: (p) {
        if (p.phase == TrickHuntPhase.discovery && p.discoveryDone == 0) {
          service.cancel();
        }
      },
    );

    expect(searchedKeys(), hasLength(1));
    expect(result.ourMoveNodesChecked, 1);
  });

  group('TrickHuntProgress', () {
    test('the engine-free walk owns only the first 5%', () {
      expect(
        const TrickHuntProgress(
          phase: TrickHuntPhase.walking,
          walked: 1,
          walkTotal: 2,
        ).fraction,
        closeTo(0.025, 1e-9),
      );
      expect(
        const TrickHuntProgress(phase: TrickHuntPhase.walking).fraction,
        0.0,
      );
    });

    test('discovery owns 5%..55% and probing the rest', () {
      expect(
        const TrickHuntProgress(
          phase: TrickHuntPhase.discovery,
          discoveryDone: 1,
          discoveryTotal: 2,
        ).fraction,
        closeTo(0.30, 1e-9),
      );
      expect(
        const TrickHuntProgress(
          phase: TrickHuntPhase.probing,
          probesDone: 1,
          probesTotal: 2,
        ).fraction,
        closeTo(0.775, 1e-9),
      );
    });

    test('an empty stage reads as finished, not as stuck', () {
      expect(
        const TrickHuntProgress(phase: TrickHuntPhase.discovery).fraction,
        closeTo(0.55, 1e-9),
      );
      expect(
        const TrickHuntProgress(phase: TrickHuntPhase.probing).fraction,
        closeTo(1.0, 1e-9),
      );
    });

    test('messages name the phase and its counters', () {
      expect(
        const TrickHuntProgress(
          phase: TrickHuntPhase.discovery,
          discoveryDone: 2,
          discoveryTotal: 9,
        ).message,
        'Discovery 2 / 9 positions',
      );
      expect(
        const TrickHuntProgress(
          phase: TrickHuntPhase.probing,
          probesDone: 4,
          probesTotal: 4,
        ).message,
        'Probing 4 / 4 candidates',
      );
    });
  });
}
