/// The opponent-mistake weight: a boost on the expectimax argmax, never a
/// mode of its own.  It tilts between sound candidates by how much their
/// subtrees make opponents go wrong, and cannot promote a move the eval-loss
/// guard rejects.
library;

import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/utils/ease_utils.dart' show winProbability;
import 'package:flutter_test/flutter_test.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

BuildTreeNode _node({
  required String san,
  required String uci,
  required double expectimax,
  required int evalForUs,
  double cplValue = 0.0,
}) {
  return BuildTreeNode(
      fen: '$san-fen',
      moveSan: san,
      moveUci: uci,
      ply: 1,
      isWhiteToMove: false,
      nodeId: san.hashCode,
      cumulativeProbability: 1.0,
    )
    ..expectimaxValue = expectimax
    ..hasExpectimax = true
    // Side-to-move POV: after our move it is Black's turn, so our eval
    // is the negation.
    ..engineEvalCp = -evalForUs
    ..cplValue = cplValue;
}

/// Root (White to move) with two of our candidates.
BuildTree _tree(List<BuildTreeNode> ourMoves) {
  final root = BuildTreeNode(
    fen: _startFen,
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: true,
    nodeId: 0,
    cumulativeProbability: 1.0,
  );
  for (final m in ourMoves) {
    m.parent = root;
    root.children.add(m);
  }
  return BuildTree(root: root);
}

List<String> _picked(BuildTree tree, TreeBuildConfig config) {
  RepertoireSelector(
    config: config,
    ecaCalc: ExpectimaxCalculator(config: config),
  ).select(tree);
  return [
    for (final c in tree.root.children)
      if (c.isRepertoireMove) c.moveSan,
  ];
}

void main() {
  const base = TreeBuildConfig(
    startFen: _startFen,
    playAsWhite: true,
    maxEvalLossCp: 50,
    minEvalCp: -9999,
    maxEvalCp: 9999,
  );

  group('mistakeWeight', () {
    test('0 leaves the plain expectimax pick alone', () {
      final tree = _tree([
        _node(san: 'e4', uci: 'e2e4', expectimax: 0.60, evalForUs: 30),
        _node(
          san: 'd4',
          uci: 'd2d4',
          expectimax: 0.55,
          evalForUs: 25,
          cplValue: 500,
        ),
      ]);
      expect(_picked(tree, base), ['e4']);
    });

    test('lifts the move whose subtree makes opponents go wrong', () {
      // Selection marks the tree, so each pick gets a fresh one.
      BuildTree tree() => _tree([
        _node(san: 'e4', uci: 'e2e4', expectimax: 0.60, evalForUs: 30),
        _node(
          san: 'd4',
          uci: 'd2d4',
          expectimax: 0.55,
          evalForUs: 25,
          cplValue: 100,
        ),
      ]);
      // d4: 0.55 × (1 + 1.0 × 1.0) = 1.10 > e4: 0.60.
      expect(_picked(tree(), base.copyWith(mistakeWeight: 100)), ['d4']);
      // A small weight is not enough: 0.55 × 1.05 = 0.5775 < 0.60.
      expect(_picked(tree(), base.copyWith(mistakeWeight: 5)), ['e4']);
    });

    test('never crosses the eval-loss guard', () {
      BuildTree tree() => _tree([
        _node(san: 'e4', uci: 'e2e4', expectimax: 0.60, evalForUs: 30),
        _node(
          san: 'g4',
          uci: 'g2g4',
          expectimax: 0.50,
          evalForUs: -40, // 70cp behind, guard is 50
          cplValue: 1000,
        ),
      ]);
      expect(_picked(tree(), base.copyWith(mistakeWeight: 100)), ['e4']);
      // Widen the guard and the same weight now reaches it.
      expect(
        _picked(tree(), base.copyWith(mistakeWeight: 100, maxEvalLossCp: 100)),
        ['g4'],
      );
    });

    test('saturates at one pawn of expected loss', () {
      final tree = _tree([
        _node(
          san: 'e4',
          uci: 'e2e4',
          expectimax: 0.50,
          evalForUs: 30,
          cplValue: 1000,
        ),
        _node(
          san: 'd4',
          uci: 'd2d4',
          expectimax: 0.55,
          evalForUs: 25,
          cplValue: kMistakeFullBoostCp,
        ),
      ]);
      // Unsaturated, e4 would score 0.50 × 11 = 5.5; capped it is 1.0,
      // below d4's 1.1.
      expect(_picked(tree, base.copyWith(mistakeWeight: 100)), ['d4']);
    });

    test('stored expectimax values stay unboosted', () {
      final tree = _tree([
        _node(san: 'e4', uci: 'e2e4', expectimax: 0.60, evalForUs: 30),
        _node(
          san: 'd4',
          uci: 'd2d4',
          expectimax: 0.55,
          evalForUs: 25,
          cplValue: 100,
        ),
      ]);
      final config = base.copyWith(mistakeWeight: 100);
      ExpectimaxCalculator(config: config).calculate(tree);
      final d4 = tree.root.children.last;
      // Leaves take their engine win probability; the root takes the
      // boosted winner's *raw* value, not the doubled one the argmax saw.
      expect(d4.expectimaxValue, closeTo(winProbability(25), 1e-9));
      expect(tree.root.expectimaxValue, closeTo(d4.expectimaxValue, 1e-9));
      expect(tree.root.expectimaxValue, lessThan(1.0));
    });
  });
}
