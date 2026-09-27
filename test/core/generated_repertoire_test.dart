// The generated bundle keeps the adopted tree, position index and traps together.

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/generated_repertoire.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:flutter_test/flutter_test.dart';

BuildTree _smallTree() {
  final root = BuildTreeNode(
    fen: kStandardStartFen,
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: true,
    nodeId: 0,
  )..engineEvalCp = 20;

  final e4 = BuildTreeNode(
    fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
    moveSan: 'e4',
    moveUci: 'e2e4',
    ply: 1,
    isWhiteToMove: false,
    nodeId: 1,
    parent: root,
  )..engineEvalCp = 25;
  root.children.add(e4);

  final e5 = BuildTreeNode(
    fen: 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2',
    moveSan: 'e5',
    moveUci: 'e7e5',
    ply: 2,
    isWhiteToMove: true,
    nodeId: 2,
    parent: e4,
  )..engineEvalCp = 22;
  e4.children.add(e5);

  return BuildTree(root: root)..computeMetadata();
}

void main() {
  group('GeneratedRepertoire.fromTree', () {
    test('fenMap indexes the adopted tree', () {
      final tree = _smallTree();
      final bundle = GeneratedRepertoire.fromTree(tree, playAsWhite: true);

      expect(bundle.tree, same(tree));
      expect(bundle.playAsWhite, isTrue);
      expect(bundle.fenMap.contains(tree.root.fen), isTrue);
      expect(bundle.fenMap.size, 3, reason: 'three distinct positions');
    });

    test('a tree with no trap structure yields an empty trap index', () {
      final tree = _smallTree();
      final bundle = GeneratedRepertoire.fromTree(tree, playAsWhite: true);
      expect(bundle.traps.allTraps, isEmpty);
      expect(bundle.traps.metrics.totalTraps, 0);
    });

    test('the bundle retains the generation perspective', () {
      final tree = _smallTree();
      final bundle = GeneratedRepertoire.fromTree(tree, playAsWhite: false);
      expect(bundle.playAsWhite, isFalse);
    });
  });
}
