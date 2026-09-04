/// End-to-end tests for [HoleHuntService.hunt] against a real repertoire tree
/// and a scripted engine.
///
/// A "hole" is something the ATTACKER (the side opposite the repertoire's
/// colour) can exploit. Two of the three kinds are reachable without a full
/// expectimax build and are pinned here:
///
///  - `uncoveredStrongMove`: an engine-strong attacker move the file has no
///    reply to — gated by a window below the engine best and by an absolute
///    advantage floor;
///  - `refutation`: a repertoire move that loses by more than the threshold,
///    confirmed by a deeper single-PV search.
///
/// The third (`practicalTrap`) needs a real `TreeBuildService` run, so only
/// its gates are covered.
library;

import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/holes/services/hole_hunt_config.dart';
import 'package:chess_auto_prep/features/holes/services/hole_hunt_service.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/opening_tree_builder.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/hunt_harness.dart';
import '../../support/scripted_engine.dart';

/// A White repertoire with one owner choice: after 1.e4 e5 the file plays
/// 2.Nf3 three times and 2.Bc4 once.
const _repertoire = [
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
  late EvalWorker worker;
  late HoleHuntService service;

  /// Node reached by walking [path] from the root.
  OpeningTreeNode at(List<String> path) {
    var node = tree.root;
    for (final san in path) {
      node = node.children[san]!;
    }
    return node;
  }

  void scriptDiscovery(OpeningTreeNode node, List<ScriptLine> lines) =>
      engine.discovery[normalizeFen(node.fen)] = lines;

  void scriptEval(OpeningTreeNode node, ScriptLine line) =>
      engine.evals[normalizeFen(node.fen)] = line;

  /// Defaults that keep the expectimax trap pass out of the way — it needs a
  /// real tree build, which a unit test cannot drive.
  HoleHuntConfig config({
    int maxPly = 30,
    int strongMoveWindowCp = 30,
    int uncoveredMinAdvantageCp = -25,
    int outOfBookBonusCp = 50,
    int refutationThresholdCp = 80,
    int trapLeafCount = 0,
  }) => HoleHuntConfig(
    maxPly: maxPly,
    strongMoveWindowCp: strongMoveWindowCp,
    uncoveredMinAdvantageCp: uncoveredMinAdvantageCp,
    outOfBookBonusCp: outOfBookBonusCp,
    refutationThresholdCp: refutationThresholdCp,
    trapLeafCount: trapLeafCount,
  );

  setUpAll(() async {
    await initTestSqlite();
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await clearEvalCache();
    engine = ScriptedEngine();
    worker = await installScriptedWorker(engine);
    service = HoleHuntService();
    tree = await _build(_repertoire);
  });

  tearDown(() {
    useMaia(null);
    resetPool();
  });

  Future<List<AuditFinding>> hunt({
    HoleHuntConfig? cfg,
    bool isWhiteRepertoire = true,
    void Function(AuditFinding)? onFinding,
  }) async {
    final result = await service.hunt(
      tree: tree,
      isWhiteRepertoire: isWhiteRepertoire,
      config: cfg ?? config(),
      onFinding: onFinding,
    );
    return result.findings;
  }

  group('walk shape', () {
    test('classifies every node by whose turn it is', () async {
      final result = await service.hunt(
        tree: tree,
        isWhiteRepertoire: true,
        config: config(),
      );

      // root, e4, e5, Nf3, Bc4, Nc6, Nf6.
      expect(result.nodesChecked, 7);
      // Attacker (Black) to move with children: e4, Nf3, Bc4.
      expect(result.ourMoveNodesChecked, 3);
      // Owner (White) to move with children: root, e5.
      expect(result.opponentNodesChecked, 2);
      // Childless: after 2.Nf3 Nc6 and after 2.Bc4 Nf6.
      expect(result.leafNodesChecked, 2);
    });

    test('maxPly stops the walk before the deeper nodes', () async {
      final result = await service.hunt(
        tree: tree,
        isWhiteRepertoire: true,
        config: config(maxPly: 1),
      );

      expect(
        result.nodesChecked,
        2,
        reason: 'root and the position after 1.e4',
      );
      expect(result.ourMoveNodesChecked, 1);
      expect(result.opponentNodesChecked, 1);
      expect(result.leafNodesChecked, 0);
    });

    test('a tree with no games is one leaf and no findings', () async {
      tree = await _build(const []);

      final result = await service.hunt(
        tree: tree,
        isWhiteRepertoire: true,
        config: config(),
      );

      expect(result.nodesChecked, 1);
      expect(result.leafNodesChecked, 1);
      expect(result.opponentNodesChecked, 0);
      expect(result.findings, isEmpty);
      expect(engine.discoverySearches, isEmpty);
    });
  });

  group('uncovered strong attacker moves', () {
    test('flags a move the file has no reply to, not one it does', () async {
      final e4 = at(['e4']);
      scriptDiscovery(e4, const [
        // Black to move: these are Black's own scores.
        ScriptLine.cp(20, pv: ['e7e5']), // in the tree — covered
        ScriptLine.cp(10, pv: ['c7c5']), // not in the tree — a hole
      ]);

      final findings = await hunt();

      expect(findings, hasLength(1));
      final f = findings.single;
      expect(f.type, AuditFindingType.uncoveredStrongMove);
      expect(f.missingMove, 'c5');
      expect(f.severity, AuditSeverity.warning);
      // Evals are stored White-normalised: Black +10 is White -10.
      expect(f.positionEvalCp, -10);
      expect(f.bestMoveEvalCp, -20);
      expect(f.cumulativeProbability, closeTo(1.0, 1e-9));
      // reach × (attacker cp + out-of-book bonus).
      expect(f.exploitScore, closeTo(60, 1e-9));
      expect(f.transposesIntoRepertoire, isFalse);
      expect(f.movePath, ['e4']);
    });

    test('the strong-move window is inclusive at its edge', () async {
      final e4 = at(['e4']);
      scriptDiscovery(e4, const [
        ScriptLine.cp(20, pv: ['e7e5']),
        ScriptLine.cp(-10, pv: ['c7c5']), // exactly 30 behind → kept
        ScriptLine.cp(-11, pv: ['e7e6']), // 31 behind → dropped
      ]);

      final findings = await hunt(cfg: config(strongMoveWindowCp: 30));

      expect(findings.map((f) => f.missingMove), ['c5']);
    });

    test('the advantage floor is inclusive at its edge', () async {
      final e4 = at(['e4']);
      scriptDiscovery(e4, const [
        ScriptLine.cp(500, pv: ['e7e5']),
        ScriptLine.cp(-25, pv: ['c7c5']), // exactly at the floor → kept
        ScriptLine.cp(-26, pv: ['e7e6']), // below it → dropped
      ]);

      final findings = await hunt(
        cfg: config(strongMoveWindowCp: 1000, uncoveredMinAdvantageCp: -25),
      );

      expect(findings.map((f) => f.missingMove), ['c5']);
    });

    test('severity steps at +1.00 and at equality', () async {
      final e4 = at(['e4']);
      scriptDiscovery(e4, const [
        ScriptLine.cp(200, pv: ['e7e5']),
        ScriptLine.cp(100, pv: ['c7c5']), // critical
        ScriptLine.cp(99, pv: ['e7e6']), // warning
        ScriptLine.cp(0, pv: ['g8f6']), // warning
        ScriptLine.cp(-1, pv: ['b8c6']), // info
      ]);

      final findings = await hunt(
        cfg: config(strongMoveWindowCp: 1000, uncoveredMinAdvantageCp: -1000),
      );

      final severityOf = {for (final f in findings) f.missingMove: f.severity};
      expect(severityOf, {
        'c5': AuditSeverity.critical,
        'e6': AuditSeverity.warning,
        'Nf6': AuditSeverity.warning,
        'Nc6': AuditSeverity.info,
      });
    });

    test('a losing attacker try still scores the out-of-book bonus', () async {
      final e4 = at(['e4']);
      scriptDiscovery(e4, const [
        ScriptLine.cp(20, pv: ['e7e5']),
        ScriptLine.cp(-10, pv: ['c7c5']),
      ]);

      final findings = await hunt(cfg: config(outOfBookBonusCp: 50));

      // Negative attacker eval clamps to zero gain, leaving just the bonus.
      expect(findings.single.exploitScore, closeTo(50, 1e-9));
      expect(findings.single.severity, AuditSeverity.info);
    });

    test('a Black repertoire makes White the attacker', () async {
      // Same tree, opposite owner: now the root is an attacker node.
      scriptDiscovery(tree.root, const [
        // White to move: these are White's own scores.
        ScriptLine.cp(150, pv: ['e2e4']), // in the tree — covered
        ScriptLine.cp(120, pv: ['d2d4']), // 30 behind → inside the window
      ]);

      final findings = await hunt(isWhiteRepertoire: false);

      expect(findings, hasLength(1));
      final f = findings.single;
      expect(f.missingMove, 'd4');
      // White is the attacker, so +120 for White is +120 for the attacker:
      // critical, and worth 120 + 50 of gain at full reach.
      expect(f.severity, AuditSeverity.critical);
      expect(f.positionEvalCp, 120);
      expect(f.exploitScore, closeTo(170, 1e-9));
    });
  });

  group('refutations of the owner\'s own moves', () {
    /// After 1.e4 e5 White chooses; 2.Bc4 is the move under suspicion.
    void scriptOwnerChoice({int bc4Cp = -60}) {
      scriptDiscovery(at(['e4', 'e5']), [
        const ScriptLine.cp(30, pv: ['g1f3']),
        ScriptLine.cp(bc4Cp, pv: const ['f1c4']),
      ]);
    }

    test('flags a repertoire move the deep search confirms loses', () async {
      scriptOwnerChoice();
      // Verification runs on the position after 2.Bc4 — Black to move, so
      // +55 there is -55 for White.
      scriptEval(
        at(['e4', 'e5', 'Bc4']),
        const ScriptLine.cp(55, pv: ['d8h4']),
      );

      final findings = await hunt();

      expect(findings, hasLength(1));
      final f = findings.single;
      expect(f.type, AuditFindingType.refutation);
      expect(f.severity, AuditSeverity.critical);
      expect(f.movePath, ['e4', 'e5', 'Bc4']);
      expect(f.ourMove, 'Bc4');
      expect(f.bestMove, 'Nf3');
      expect(f.evalLossCp, 85, reason: '+30 for White down to -55');
      expect(f.positionEvalCp, -55);
      expect(f.bestMoveEvalCp, 30);
      expect(f.exploitLine, ['Qh4']);
      expect(f.exploitScore, closeTo(85, 1e-9));
    });

    test('the engine-best move is never its own refutation', () async {
      scriptOwnerChoice(bc4Cp: 30); // both moves equal-best
      scriptEval(
        at(['e4', 'e5', 'Bc4']),
        const ScriptLine.cp(-30, pv: ['d8h4']),
      );

      expect(await hunt(), isEmpty);
    });

    test(
      'a forced mate against the repertoire counts as the loss it is',
      () async {
        scriptOwnerChoice();
        // Black mates in 3 after 2.Bc4. Reading the raw cp field here would
        // score this as 0.00 and throw the finding away.
        scriptEval(
          at(['e4', 'e5', 'Bc4']),
          const ScriptLine.mate(3, pv: ['d8h4']),
        );

        final findings = await hunt();

        expect(findings, hasLength(1));
        expect(findings.single.positionEvalCp, -9997);
        expect(findings.single.evalLossCp, 10027);
      },
    );

    test('the deep search must confirm half the claimed loss', () async {
      scriptOwnerChoice(); // shallow search claims a 90cp loss
      // Deep search says -5 for White: a 35cp loss, under the 40cp guard.
      scriptEval(at(['e4', 'e5', 'Bc4']), const ScriptLine.cp(5, pv: ['d8h4']));

      expect(await hunt(cfg: config(refutationThresholdCp: 80)), isEmpty);
    });

    test('half the threshold exactly is enough to keep the finding', () async {
      scriptOwnerChoice();
      // -10 for White: a 40cp loss, exactly the guard.
      scriptEval(
        at(['e4', 'e5', 'Bc4']),
        const ScriptLine.cp(10, pv: ['d8h4']),
      );

      final findings = await hunt(cfg: config(refutationThresholdCp: 80));

      expect(findings, hasLength(1));
      expect(findings.single.evalLossCp, 40);
    });

    test('a move outside the MultiPV lines is evaluated on its own', () async {
      // Only 2.Nf3 came back from discovery, so 2.Bc4 has to be scored by a
      // separate search of the position after it.
      scriptDiscovery(at(['e4', 'e5']), const [
        ScriptLine.cp(30, pv: ['g1f3']),
      ]);
      scriptEval(
        at(['e4', 'e5', 'Bc4']),
        const ScriptLine.cp(60, pv: ['d8h4']),
      );

      final result = await service.hunt(
        tree: tree,
        isWhiteRepertoire: true,
        config: config(),
      );

      expect(result.findings, hasLength(1));
      expect(result.findings.single.ourMove, 'Bc4');
      expect(result.findings.single.evalLossCp, 90);
      // Two discovery searches (root, e5) plus the one after-move eval.
      expect(result.evalCacheMisses, 3);
      expect(result.evalCacheHits, 0);
    });
  });

  group('ranking and reporting', () {
    test('findings come back ordered by exploit score', () async {
      // A cheap hole at the root of the attacker's choice…
      scriptDiscovery(at(['e4']), const [
        ScriptLine.cp(20, pv: ['e7e5']),
        ScriptLine.cp(10, pv: ['c7c5']),
      ]);
      // …and an expensive refutation deeper in.
      scriptDiscovery(at(['e4', 'e5']), const [
        ScriptLine.cp(30, pv: ['g1f3']),
        ScriptLine.cp(-60, pv: ['f1c4']),
      ]);
      scriptEval(
        at(['e4', 'e5', 'Bc4']),
        const ScriptLine.cp(55, pv: ['d8h4']),
      );

      final findings = await hunt();

      expect(findings.map((f) => f.type), [
        AuditFindingType.refutation, // 85
        AuditFindingType.uncoveredStrongMove, // 60
      ]);
    });

    test('cancelling from a finding callback stops the walk', () async {
      scriptDiscovery(at(['e4']), const [
        ScriptLine.cp(20, pv: ['e7e5']),
        ScriptLine.cp(10, pv: ['c7c5']),
      ]);

      final result = await service.hunt(
        tree: tree,
        isWhiteRepertoire: true,
        config: config(),
        onFinding: (_) => service.cancel(),
      );

      // Root and the position after 1.e4 — the rest of the tree is skipped.
      expect(result.nodesChecked, 2);
      expect(result.findings, hasLength(1));
      expect(result.leafNodesChecked, 0);
    });
  });

  group('trap pass gating', () {
    test('asking for no leaves is not a skipped trap pass', () async {
      useMaia(FakeMaia(failInit: true));

      await hunt(cfg: config(trapLeafCount: 0));

      expect(service.trapPassSkipped, isFalse);
    });

    test('a Maia that will not load skips the trap pass', () async {
      final maia = FakeMaia(failInit: true);
      useMaia(maia);

      final findings = await hunt(cfg: config(trapLeafCount: 4));

      expect(service.trapPassSkipped, isTrue);
      expect(maia.initializeCalls, 1);
      expect(findings, isEmpty);
    });

    test('a walk that reached no leaves never consults Maia', () async {
      final maia = FakeMaia(failInit: true);
      useMaia(maia);

      // maxPly 1 stops above every childless node, so there is nothing to
      // expectimax — and nothing to load a model for.
      await hunt(cfg: config(maxPly: 1, trapLeafCount: 4));

      expect(maia.initializeCalls, 0);
      expect(service.trapPassSkipped, isFalse);
    });
  });

  group('HoleHuntProgress', () {
    test('the walk owns the first 70% of the bar', () {
      expect(
        const HoleHuntProgress(
          phase: HoleHuntPhase.walking,
          nodesChecked: 5,
          totalNodes: 10,
        ).fraction,
        closeTo(0.35, 1e-9),
      );
      expect(
        const HoleHuntProgress(
          phase: HoleHuntPhase.walking,
          nodesChecked: 20,
          totalNodes: 10,
        ).fraction,
        closeTo(0.7, 1e-9),
        reason: 'clamped, never past the phase boundary',
      );
      expect(
        const HoleHuntProgress(
          phase: HoleHuntPhase.walking,
          totalNodes: 0,
        ).fraction,
        0.0,
        reason: 'an unknown total is no progress, not a division by zero',
      );
    });

    test('the trap pass owns the last 30%', () {
      expect(
        const HoleHuntProgress(
          phase: HoleHuntPhase.traps,
          leavesDone: 1,
          leavesTotal: 2,
        ).fraction,
        closeTo(0.85, 1e-9),
      );
      expect(
        const HoleHuntProgress(
          phase: HoleHuntPhase.traps,
          leavesTotal: 0,
        ).fraction,
        closeTo(1.0, 1e-9),
        reason: 'nothing to do reads as done, not as stuck at 70%',
      );
    });

    test('messages name the phase and its counters', () {
      expect(
        const HoleHuntProgress(
          phase: HoleHuntPhase.walking,
          nodesChecked: 3,
          totalNodes: 9,
        ).message,
        'Walking 3 / 9 positions',
      );
      expect(
        const HoleHuntProgress(
          phase: HoleHuntPhase.traps,
          leavesDone: 2,
          leavesTotal: 5,
        ).message,
        'Trap search 2 / 5 leaves',
      );
    });
  });

  test('the injected worker is the only engine that ran', () async {
    await hunt();
    expect(worker.isDead, isFalse);
    expect(engine.commands, isNotEmpty);
  });
}
