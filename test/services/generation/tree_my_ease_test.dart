import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/tree_my_ease.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('calculateMyEase', () {
    late BuildTree tree;
    late BuildTreeNode root;

    setUp(() {
      var nextId = 1;
      root = BuildTreeNode(
        fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        moveSan: '',
        moveUci: '',
        ply: 0,
        isWhiteToMove: true,
        nodeId: nextId++,
      )..engineEvalCp = 25;

      final e4 =
          BuildTreeNode(
              fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
              moveSan: 'e4',
              moveUci: 'e2e4',
              ply: 1,
              isWhiteToMove: false,
              nodeId: nextId++,
              parent: root,
            )
            ..engineEvalCp = -30
            ..maiaFrequency = 0.42
            ..moveProbability = 1.0
            ..isRepertoireMove = true;

      final d4 =
          BuildTreeNode(
              fen: 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1',
              moveSan: 'd4',
              moveUci: 'd2d4',
              ply: 1,
              isWhiteToMove: false,
              nodeId: nextId++,
              parent: root,
            )
            ..engineEvalCp = -25
            ..maiaFrequency = 0.38
            ..moveProbability = 1.0;

      root.children.addAll([e4, d4]);

      tree = BuildTree(root: root, totalNodes: root.countSubtree());
      tree.computeMetadata();
    });

    test('sets myEase on our-move children from maiaFrequency', () {
      final count = calculateMyEase(tree, playAsWhite: true);

      expect(count, 2);
      expect(root.children[0].myEase, closeTo(0.42, 0.001));
      expect(root.children[1].myEase, closeTo(0.38, 0.001));
    });

    test('does not set myEase on opponent-move children', () {
      final e4 = root.children[0];
      final c5 =
          BuildTreeNode(
              fen: 'test-fen',
              moveSan: 'c5',
              moveUci: 'c7c5',
              ply: 2,
              isWhiteToMove: true,
              nodeId: 10,
              parent: e4,
            )
            ..engineEvalCp = 35
            ..maiaFrequency = 0.41;

      e4.children.add(c5);
      tree.computeMetadata();

      calculateMyEase(tree, playAsWhite: true);

      expect(c5.myEase, -1.0);
    });

    test('forced move (only reasonable) gets myEase = 1.0', () {
      root.children[0].engineEvalCp = -10;
      root.children[1].engineEvalCp = -300;
      root.children[0].maiaFrequency = 0.3;

      calculateMyEase(tree, playAsWhite: true);

      expect(root.children[0].myEase, 1.0);
    });

    test('low Maia but engine best is capped at 0.5', () {
      root.children[0].maiaFrequency = 0.10;
      root.children[0].engineEvalCp = -10;
      root.children[1].engineEvalCp = -20;

      calculateMyEase(tree, playAsWhite: true);

      expect(root.children[0].myEase, lessThanOrEqualTo(0.5));
    });

    test('defaults to 0.5 when maiaFrequency is not set', () {
      root.children[0].maiaFrequency = -1.0;
      root.children[1].maiaFrequency = -1.0;

      calculateMyEase(tree, playAsWhite: true);

      expect(root.children[0].myEase, 0.5);
      expect(root.children[1].myEase, 0.5);
    });
  });

  group('computePositionQuality', () {
    test('at our-move node returns myEase of repertoire child', () {
      final parent = BuildTreeNode(
        fen: 'fen',
        moveSan: '',
        moveUci: '',
        ply: 0,
        isWhiteToMove: true,
        nodeId: 1,
      );
      final child =
          BuildTreeNode(
              fen: 'fen2',
              moveSan: 'e4',
              moveUci: 'e2e4',
              ply: 1,
              isWhiteToMove: false,
              nodeId: 2,
              parent: parent,
            )
            ..myEase = 0.8
            ..isRepertoireMove = true;
      parent.children.add(child);

      final q = computePositionQuality(parent, true);
      expect(q, closeTo(0.8, 0.001));
    });

    test('at opponent-move node returns (1 - ease)', () {
      final node = BuildTreeNode(
        fen: 'fen',
        moveSan: 'c5',
        moveUci: 'c7c5',
        ply: 2,
        isWhiteToMove: false,
        nodeId: 1,
      )..ease = 0.7;

      final q = computePositionQuality(node, true);
      expect(q, closeTo(0.3, 0.001));
    });
  });

  group('computeLinePlayability', () {
    test('geometric mean of position qualities', () {
      final nodes = <BuildTreeNode>[];
      for (var i = 0; i < 3; i++) {
        final parent = BuildTreeNode(
          fen: 'fen-$i',
          moveSan: i == 0 ? '' : 'e$i',
          moveUci: '',
          ply: i * 2,
          isWhiteToMove: true,
          nodeId: i + 1,
        );
        final child =
            BuildTreeNode(
                fen: 'fen-child-$i',
                moveSan: 'Nf${i + 3}',
                moveUci: '',
                ply: i * 2 + 1,
                isWhiteToMove: false,
                nodeId: 10 + i,
                parent: parent,
              )
              ..myEase = 0.8
              ..isRepertoireMove = true;
        parent.children.add(child);
        nodes.add(parent);
      }

      final lp = computeLinePlayability(nodes, true);
      expect(lp.playability, closeTo(0.8, 0.01));
      expect(lp.easyMoveCount, 3);
      expect(lp.hardMoveCount, 0);
    });

    test('empty line returns neutral playability', () {
      final lp = computeLinePlayability([], true);
      expect(lp.playability, 0.5);
    });
  });
}
