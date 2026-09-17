/// The hole hunt's probe pass, driven without an engine.
///
/// A probe's verdict is arithmetic over one number: the practical value the
/// mini expectimax build reports for the position after the candidate move.
/// [TrickProbe] takes that build from an injectable [ProbeTreeBuilder], so a
/// stub that returns a scored tree pins the gate, the budget and the shape of
/// the finding without running Stockfish or Maia.
library;

import 'package:chess_auto_prep/features/audit/models/audit_finding.dart';
import 'package:chess_auto_prep/features/holes/services/hole_hunt_config.dart';
import 'package:chess_auto_prep/features/holes/services/hole_scoring.dart';
import 'package:chess_auto_prep/features/holes/services/trick_probe.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/run_control.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show playUciMove;
import 'package:chess_auto_prep/constants/chess_constants.dart'
    show kStandardStartFen;
import 'package:flutter_test/flutter_test.dart';

/// White (the attacker) is to move at the start; 1.e4 is the candidate and
/// 1.d4 the engine's best move, so the probe tree starts after 1.e4.
const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

void main() {
  late RunControl control;
  late List<TreeBuildConfig> builds;

  setUp(() {
    control = RunControl()..reset();
    builds = [];
  });

  TrickTarget target({double reach = 0.5}) => TrickTarget(
    node: OpeningTreeNode(move: '', fen: kStandardStartFen),
    movePath: const [],
    reach: reach,
  );

  /// A candidate costing [costCp] against the engine's best move.
  TrickCandidate candidate({int costCp = 20, double reach = 0.5}) =>
      TrickCandidate(
        target: target(reach: reach),
        san: 'e4',
        uci: 'e2e4',
        bestSan: 'd4',
        metrics: TrickCandidateMetrics(
          candidateRawCp: 50 - costCp,
          bestRawCp: 50,
        ),
        isNovelty: true,
      );

  /// A scored one-reply tree: the owner's single reply carries all the
  /// policy mass and an engine eval, so the root backs up to a practical
  /// value of about [practicalCp] from the attacker's side.
  BuildTree scoredTree(int practicalCp) {
    final root = BuildTreeNode(
      fen: _afterE4,
      moveSan: '',
      moveUci: '',
      ply: 0,
      isWhiteToMove: false,
      nodeId: 0,
    );
    final reply = BuildTreeNode(
      fen: playUciMove(_afterE4, 'e7e5')!,
      moveSan: 'e5',
      moveUci: 'e7e5',
      ply: 1,
      isWhiteToMove: true,
      nodeId: 1,
      parent: root,
    )..engineEvalCp = practicalCp;
    root.children.add(reply);
    return BuildTree(root: root, totalNodes: 2, maxPlyReached: 1);
  }

  /// A probe whose builds all return [tree], recording each config asked for.
  TrickProbe probeReturning(
    BuildTree Function() tree, {
    HoleHuntConfig? config,
  }) => TrickProbe(
    tree: OpeningTree(),
    config: config ?? const HoleHuntConfig(),
    attackerIsWhite: true,
    control: control,
    buildTree:
        ({
          required TreeBuildConfig config,
          required bool Function() isCancelled,
          required void Function(BuildProgress) onProgress,
        }) async {
          builds.add(config);
          return tree();
        },
  );

  group('the practical-value gate', () {
    test(
      'reports a trick when the probe beats the best move outright',
      () async {
        // Practical +300 against a best move worth +50 is a net gain of 250.
        final finding = await probeReturning(
          () => scoredTree(300),
        ).probe(candidate(costCp: 20));

        expect(finding, isNotNull);
        expect(finding!.type, AuditFindingType.trickyMove);
        expect(finding.ourMove, 'e4');
        expect(finding.bestMove, 'd4');
        expect(finding.netGainCp, closeTo(250, 2));
        // The candidate concedes its objective cost whatever the probe says.
        expect(finding.evalLossCp, 20);
        expect(finding.severity, AuditSeverity.critical);
        expect(finding.isNovelty, isTrue);
        // A novelty carries missingMove so the report can preview the move.
        expect(finding.missingMove, 'e4');
      },
    );

    test(
      'stays silent when the practical value only matches the best move',
      () async {
        final finding = await probeReturning(
          () => scoredTree(50),
        ).probe(candidate(costCp: 20));

        expect(finding, isNull, reason: 'net gain 0 is below the 40cp floor');
      },
    );

    test('a warning below twice the floor, critical at or above it', () async {
      const config = HoleHuntConfig(minNetGainCp: 100);

      final warning = await probeReturning(
        () => scoredTree(200),
        config: config,
      ).probe(candidate());
      final critical = await probeReturning(
        () => scoredTree(260),
        config: config,
      ).probe(candidate());

      expect(warning!.severity, AuditSeverity.warning);
      expect(critical!.severity, AuditSeverity.critical);
    });

    test('a build with no replies is not a trick', () async {
      final empty = BuildTree(
        root: BuildTreeNode(
          fen: _afterE4,
          moveSan: '',
          moveUci: '',
          ply: 0,
          isWhiteToMove: false,
          nodeId: 0,
        ),
      );

      expect(await probeReturning(() => empty).probe(candidate()), isNull);
    });

    test('an unplayable candidate move never reaches the builder', () async {
      final probe = probeReturning(() => scoredTree(300));
      final illegal = TrickCandidate(
        target: target(),
        san: 'e5',
        uci: 'e2e5',
        bestSan: 'd4',
        metrics: const TrickCandidateMetrics(candidateRawCp: 0, bestRawCp: 0),
        isNovelty: true,
      );

      expect(await probe.probe(illegal), isNull);
      expect(builds, isEmpty);
    });
  });

  group('the build a probe asks for', () {
    test('starts after the candidate move, playing the attacker', () async {
      await probeReturning(
        () => scoredTree(300),
        config: const HoleHuntConfig(
          probePly: 6,
          probeEvalDepth: 10,
          maiaElo: 1700,
        ),
      ).probe(candidate());

      expect(builds, hasLength(1));
      final config = builds.single;
      expect(config.startFen, _afterE4);
      expect(config.playAsWhite, isTrue, reason: 'the attacker is White');
      expect(config.maxPly, 6);
      expect(config.evalDepth, 10);
      expect(config.maiaElo, 1700);
      expect(config.buildMode, BuildMode.stockfishExpectimax);
      // One UCI thread per worker: parallelism is the pool's job.
      expect(config.engineThreads, 1);
    });

    test('widens the eval window past the generation defaults', () {
      final config = TrickProbe.buildConfigFor(
        _afterE4,
        attackerIsWhite: true,
        config: const HoleHuntConfig(),
      );

      expect(config.minEvalCp, lessThan(0));
      expect(
        config.maxEvalCp,
        greaterThan(200),
        reason: 'a trick\'s punishment lives outside the default window',
      );
      expect(config.openingWidthPlies, 0);
      expect(config.verifyFinal, isFalse);
    });
  });

  group('the pass over a candidate pool', () {
    test(
      'probes the budget, most reachable first, and reports progress',
      () async {
        final probe = probeReturning(
          () => scoredTree(300),
          config: const HoleHuntConfig(probeBudget: 2),
        );
        final emitted = <AuditFinding>[];
        final progress = <(int, int)>[];

        await probe.run(
          [candidate(reach: 0.1), candidate(reach: 0.9), candidate(reach: 0.5)],
          emit: emitted.add,
          onProgress: (done, total) => progress.add((done, total)),
        );

        expect(builds, hasLength(2), reason: 'the budget is two probes');
        expect(emitted, hasLength(2));
        expect(emitted.map((f) => f.cumulativeProbability), [
          0.9,
          0.5,
        ], reason: 'highest reach is probed first');
        expect(progress, [(0, 2), (1, 2), (2, 2)]);
      },
    );

    test('an empty pool builds nothing and reports nothing', () async {
      final probe = probeReturning(() => scoredTree(300));
      final progress = <(int, int)>[];

      await probe.run(
        const [],
        emit: (_) => fail('no candidate should be emitted'),
        onProgress: (done, total) => progress.add((done, total)),
      );

      expect(builds, isEmpty);
      expect(progress, isEmpty);
    });

    test('cancelling stops the pass before the next build', () async {
      final probe = probeReturning(() {
        control.cancel();
        return scoredTree(300);
      }, config: const HoleHuntConfig(probeBudget: 3));
      final emitted = <AuditFinding>[];

      await probe.run(
        [candidate(), candidate(), candidate()],
        emit: emitted.add,
        onProgress: (_, _) {},
      );

      expect(builds, hasLength(1));
      expect(
        emitted,
        isEmpty,
        reason: 'a cancelled build\'s result is discarded',
      );
    });

    test('a failing build costs its candidate, not the pass', () async {
      var calls = 0;
      final probe = probeReturning(() {
        if (++calls == 1) throw StateError('build exploded');
        return scoredTree(300);
      }, config: const HoleHuntConfig(probeBudget: 2));
      final emitted = <AuditFinding>[];

      await probe.run(
        [candidate(reach: 0.9), candidate(reach: 0.5)],
        emit: emitted.add,
        onProgress: (_, _) {},
      );

      expect(emitted, hasLength(1));
      expect(emitted.single.cumulativeProbability, 0.5);
    });
  });
}
