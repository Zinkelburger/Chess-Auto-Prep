import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/utils/ease_utils.dart' show winProbability;
import 'package:flutter_test/flutter_test.dart';

import 'generation_test_helpers.dart';

TreeBuildConfig _whiteConfig() => const TreeBuildConfig(
  startFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
  playAsWhite: true,
);

void main() {
  group('ExpectimaxCalculator.calculate', () {
    late StandardTree t;
    late BuildTree tree;
    late ExpectimaxCalculator calc;

    setUp(() {
      t = StandardTree();
      tree = t.toTree();
      calc = ExpectimaxCalculator(config: _whiteConfig());
    });

    test('sets hasExpectimax on all nodes', () {
      calc.calculate(tree);

      void checkAll(BuildTreeNode node) {
        expect(
          node.hasExpectimax,
          isTrue,
          reason: '${node.moveSan}@${node.ply} should have expectimax',
        );
        for (final child in node.children) {
          checkAll(child);
        }
      }

      checkAll(tree.root);
    });

    test('leaf values use winProbability of eval-for-us', () {
      calc.calculate(tree);

      // e4e5nf3 is a leaf, black to move, evalCp=-30 (side-to-move).
      // playAsWhite=true, isWhiteToMove=false => evalForUs = -(-30) = 30
      final expected = 1.0 * winProbability(30) + 0.0 * 0.5;
      expect(t.e4e5nf3.expectimaxValue, closeTo(expected, 0.001));
    });

    test('opponent nodes compute weighted sum with tail term', () {
      calc.calculate(tree);

      // e4 is an opponent-move node (black to move, playAsWhite=true).
      // Children: e5 (p=0.55), c5 (p=0.35). Covered = 0.90, tail = 0.10.
      final vE5 = t.e4e5.expectimaxValue;
      final vC5 = t.e4c5.expectimaxValue;
      final leafVal = 1.0 * winProbability(t.e4.evalForUs(true)) + 0.0 * 0.5;
      final expected = 0.55 * vE5 + 0.35 * vC5 + 0.10 * leafVal;
      expect(t.e4.expectimaxValue, closeTo(expected, 0.001));
    });

    test('our-move nodes take max of children', () {
      calc.calculate(tree);

      // root is our-move (white to move). Best child = max V among e4, d4.
      final bestV = [
        t.e4.expectimaxValue,
        t.d4.expectimaxValue,
      ].reduce((a, b) => a > b ? a : b);
      expect(tree.root.expectimaxValue, closeTo(bestV, 0.001));
    });

    test('two-pass handles transposition leaves', () {
      resetNodeIds();
      final root = makeNode(
        fen: kStandardStartFen,
        san: '',
        ply: 0,
        isWhiteToMove: true,
        evalCp: 30,
      );
      final e4 = makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        uci: 'e2e4',
        ply: 1,
        isWhiteToMove: false,
        evalCp: -25,
        parent: root,
      );
      final leaf = makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        uci: 'e7e5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 35,
        moveProbability: 0.6,
        cumulativeProbability: 0.6,
        parent: e4,
      );
      // Canonical node with the same FEN but with children
      final canonical = makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        uci: 'e7e5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 35,
        nodeId: 999,
      );
      // Attaches itself as a child of `canonical` via `parent:`.
      makeNode(
        fen: kFenAfterE4E5Nf3,
        san: 'Nf3',
        uci: 'g1f3',
        ply: 3,
        isWhiteToMove: false,
        evalCp: -30,
        parent: canonical,
      );
      // `leaf` is childless; `canonical` has children. Simulate transposition.
      final fenMap = FenMap();
      fenMap.putCanonical(canonical.fen, canonical);
      fenMap.addTransposition(leaf.fen, leaf);

      // Ensure canonical gets calculated first via a separate tree.
      final canonicalTree = BuildTree(root: canonical);
      final calcWithFm = ExpectimaxCalculator(
        config: _whiteConfig(),
        fenMap: fenMap,
      );
      calcWithFm.calculate(canonicalTree);
      expect(canonical.hasExpectimax, isTrue);

      // Now calculate the main tree — leaf should borrow canonical's value.
      final mainTree = BuildTree(root: root);
      calcWithFm.calculate(mainTree);
      expect(leaf.hasExpectimax, isTrue);
      expect(leaf.expectimaxValue, canonical.expectimaxValue);
    });

    test('returns count of nodes that received values', () {
      final count = calc.calculate(tree);
      // StandardTree has 10 nodes; two-pass counts the second pass.
      expect(count, greaterThanOrEqualTo(10));
    });
  });

  group('ExpectimaxCalculator.scoreOurMoveChildren', () {
    test('picks highest-V child at our-move nodes', () {
      final t = StandardTree();
      final tree = t.toTree();
      final calc = ExpectimaxCalculator(config: _whiteConfig());
      calc.calculate(tree);

      final best = calc.scoreOurMoveChildren(tree.root);
      expect(best, isNotNull);
      final otherV = best!.child == t.e4
          ? t.d4.expectimaxValue
          : t.e4.expectimaxValue;
      expect(best.expectimaxValue, greaterThanOrEqualTo(otherV));
    });

    test('returns null on a node with no children', () {
      final leaf = makeNode(
        fen: kFenAfterE4E5Nf3,
        san: 'Nf3',
        ply: 3,
        isWhiteToMove: false,
        evalCp: -30,
      )..hasExpectimax = true;
      final calc = ExpectimaxCalculator(config: _whiteConfig());
      expect(calc.scoreOurMoveChildren(leaf), isNull);
    });
  });
}
