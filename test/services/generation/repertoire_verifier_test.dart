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
  FakeStockfishPool scores({int e4 = -48, int d4 = -30}) => FakeStockfishPool()
    ..stmCpByFen[kFenAfterE4] = e4
    ..stmCpByFen[kFenAfterD4] = d4
    ..stmCpByFen[kFenAfterE4E5] = 35
    ..stmCpByFen[kFenAfterE4E5Nf3] = -25;
  test(
    'every saved candidate is checked; values refreshed without a demotion',
    () async {
      final t = _VerifierTree();
      final pool = scores();
      final report = await _verify(t, pool);
      expect(report.completed, isTrue);
      expect(report.passes, 1);
      expect(report.evalsRun, 4);
      expect(pool.evalCalls, contains(kFenAfterD4));
      expect(report.demotions, isEmpty);
      expect(t.e4.hasExpectimax, isTrue);
      expect(t.e4.engineEvalCp, -48);
    },
  );
  test(
    'shallow sibling is not an upper bound: deep improvement changes selection',
    () async {
      final t = _VerifierTree();
      final report = await _verify(t, scores(d4: -200));
      expect(report.completed, isTrue);
      expect(t.d4.isRepertoireMove, isTrue);
      expect(t.e4.isRepertoireMove, isFalse);
      expect(report.demotions.single.newSan, 'd4');
      expect(t.e4e5nf3.isRepertoireMove, isFalse);
    },
  );
  test(
    'deep collapse demotes without a bounded re-verification loop',
    () async {
      final t = _VerifierTree();
      final report = await _verify(t, scores(e4: 80, d4: -40));
      expect(report.completed, isTrue);
      expect(report.passes, 1);
      expect(report.demotions.single.oldDeepCpUs, -80);
      expect(report.selectedCount, 1);
    },
  );
  test('engine unavailable leaves the original tree intact', () async {
    final t = _VerifierTree();
    final report = await _verify(t, FakeStockfishPool(workers: 0));
    expect(report.completed, isFalse);
    expect(t.e4.engineEvalCp, -50);
  });
  test(
    'cancellation during evaluation commits none of the new values',
    () async {
      final t = _VerifierTree();
      final pool = scores();
      final report = await _verify(
        t,
        pool,
        isCancelled: () => pool.evalCalls.isNotEmpty,
      );
      expect(report.completed, isFalse);
      expect(t.e4.engineEvalCp, -50);
      expect(t.e4.isRepertoireMove, isTrue);
    },
  );
}
