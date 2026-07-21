/// Tests for the deep-verification pass ([RepertoireVerifier]) with a
/// scripted engine pool — previously the only phase with no coverage.
///
/// Sign conventions matter here: [FakeStockfishPool.stmCpByFen] is
/// side-to-move relative, and every child of a White our-move node is a
/// Black-to-move position, so "deep eval +X for us" is scripted as -X.
library;

import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/repertoire_verifier.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine_fakes.dart';
import 'generation_test_helpers.dart';

const _config = TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  relativeEval: false,
  // Wide window so selection guards never interfere with what these tests
  // target (demotion mechanics, not eval-window pruning).
  minEvalCp: -9999,
  maxEvalCp: 9999,
);

/// root (our move)
/// ├── e4  (selected, shallow +50 for us)
/// │   └── e5 (p=0.55)
/// │       └── Nf3 (selected, shallow +30 for us)
/// └── d4  (sibling, shallow +30 for us)
class _VerifierTree {
  late final BuildTreeNode root, e4, d4, e4e5, e4e5nf3;

  _VerifierTree() {
    resetNodeIds();
    root = makeNode(
      fen: kStandardStartFen,
      san: '',
      ply: 0,
      isWhiteToMove: true,
    );
    e4 = makeNode(
      fen: kFenAfterE4,
      san: 'e4',
      uci: 'e2e4',
      ply: 1,
      isWhiteToMove: false,
      evalCp: -50,
      parent: root,
    )..isRepertoireMove = true;
    d4 = makeNode(
      fen: kFenAfterD4,
      san: 'd4',
      uci: 'd2d4',
      ply: 1,
      isWhiteToMove: false,
      evalCp: -30,
      parent: root,
    );
    e4e5 = makeNode(
      fen: kFenAfterE4E5,
      san: 'e5',
      uci: 'e7e5',
      ply: 2,
      isWhiteToMove: true,
      evalCp: 35,
      moveProbability: 0.55,
      cumulativeProbability: 0.55,
      parent: e4,
    );
    e4e5nf3 = makeNode(
      fen: kFenAfterE4E5Nf3,
      san: 'Nf3',
      uci: 'g1f3',
      ply: 3,
      isWhiteToMove: false,
      evalCp: -30,
      parent: e4e5,
    )..isRepertoireMove = true;
  }

  BuildTree toTree() => BuildTree(root: root, totalNodes: 5);

  FenMap toFenMap() {
    final fm = FenMap();
    fm.populate(root);
    return fm;
  }
}

Future<VerificationReport> _verify(
  _VerifierTree t,
  FakeStockfishPool pool, {
  bool Function()? isCancelled,
}) {
  final fenMap = t.toFenMap();
  final verifier = RepertoireVerifier(config: _config, pool: pool);
  return verifier.verify(
    t.toTree(),
    fenMap: fenMap,
    ecaCalc: ExpectimaxCalculator(config: _config, fenMap: fenMap),
    isCancelled: isCancelled,
  );
}

void main() {
  group('RepertoireVerifier', () {
    test('all moves within threshold: one pass, no demotions, deep evals '
        'land on the chosen nodes, siblings never deep-checked', () async {
      final t = _VerifierTree();
      final pool = FakeStockfishPool()
        ..stmCpByFen[kFenAfterE4] =
            -48 // +48 for us at depth
        ..stmCpByFen[kFenAfterE4E5Nf3] = -25; // +25 for us

      final report = await _verify(t, pool);

      expect(report.completed, isTrue);
      expect(report.passes, 1);
      expect(report.demotions, isEmpty);
      expect(report.movesChecked, 2);
      expect(report.evalsRun, 2);
      expect(report.verifyDepth, 20);

      // Deep evals overwrite the shallow ones on the chosen nodes.
      expect(t.e4.engineEvalCp, -48);
      expect(t.e4e5nf3.engineEvalCp, -25);

      // Cheap accept: d4's optimistic shallow eval (+30) cannot beat the
      // deep-checked +48 by more than maxEvalLossCp, so it is never
      // deep-evaluated.
      expect(pool.evalCalls, isNot(contains(kFenAfterD4)));

      // Selection untouched.
      expect(t.e4.isRepertoireMove, isTrue);
      expect(t.d4.isRepertoireMove, isFalse);
      expect(t.e4e5nf3.isRepertoireMove, isTrue);
    });

    test('collapsed deep eval: chosen move demoted, selection re-runs, '
        'new spine verified on the next pass', () async {
      final t = _VerifierTree();
      final pool = FakeStockfishPool()
        ..stmCpByFen[kFenAfterE4] =
            80 // -80 for us: collapse
        ..stmCpByFen[kFenAfterE4E5Nf3] = -25
        ..stmCpByFen[kFenAfterD4] = -40; // +40 for us: the replacement

      final nodesBefore = t.root.countSubtree();
      final report = await _verify(t, pool);

      expect(report.completed, isTrue);
      expect(report.passes, 2);
      expect(report.demotions, hasLength(1));
      final demotion = report.demotions.single;
      expect(demotion.oldSan, 'e4');
      expect(demotion.newSan, 'd4');
      expect(demotion.oldDeepCpUs, -80);
      expect(demotion.newDeepCpUs, 40);

      // Re-selection moved the repertoire to d4; the old e4 spine is
      // unmarked but its nodes still exist (verification never removes).
      expect(t.d4.isRepertoireMove, isTrue);
      expect(t.e4.isRepertoireMove, isFalse);
      expect(t.e4e5nf3.isRepertoireMove, isFalse);
      expect(report.selectedCount, 1);
      expect(t.root.countSubtree(), nodesBefore);

      // Pass 1 deep-checked e4 + Nf3, then d4 as suspect sibling; pass 2
      // reused the cached d4 eval instead of re-running it.
      expect(report.evalsRun, 3);
      expect(
        pool.evalCalls.where((f) => f == kFenAfterD4).length,
        1,
        reason: 'deep evals are cached across passes',
      );
      expect(report.movesChecked, 3);
    });

    test('no engine workers: reports incomplete and changes nothing', () async {
      final t = _VerifierTree();
      final pool = FakeStockfishPool(workers: 0);

      final report = await _verify(t, pool);

      expect(report.completed, isFalse);
      expect(report.movesChecked, 0);
      expect(report.evalsRun, 0);
      expect(t.e4.isRepertoireMove, isTrue);
      expect(t.e4.engineEvalCp, -50, reason: 'shallow eval untouched');
    });

    test('cancellation before the first eval batch: incomplete, no evals, '
        'selection untouched', () async {
      final t = _VerifierTree();
      final pool = FakeStockfishPool()
        ..stmCpByFen[kFenAfterE4] = -48
        ..stmCpByFen[kFenAfterE4E5Nf3] = -25;

      final report = await _verify(t, pool, isCancelled: () => true);

      expect(report.completed, isFalse);
      expect(report.evalsRun, 0);
      expect(report.demotions, isEmpty);
      expect(t.e4.isRepertoireMove, isTrue);
    });
  });
}
