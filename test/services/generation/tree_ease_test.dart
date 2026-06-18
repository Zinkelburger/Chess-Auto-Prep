import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/tree_ease.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generation_test_helpers.dart';

void main() {
  group('calculateTreeEase', () {
    test('sets ease on nodes with evaluated children', () {
      final t = StandardTree();
      final tree = t.toTree();
      final scored = calculateTreeEase(tree);

      expect(scored, greaterThan(0));
      // e4 has children with evals -> should have ease
      expect(t.e4.ease, isNotNull);
      // d4 has children with evals -> should have ease
      expect(t.d4.ease, isNotNull);
      // root has children with evals -> should have ease
      expect(t.root.ease, isNotNull);
    });

    test('leaves do not get ease', () {
      final t = StandardTree();
      calculateTreeEase(t.toTree());

      expect(t.e4e5nf3.ease, isNull);
      expect(t.e4c5nf3.ease, isNull);
      expect(t.d4d5c4.ease, isNull);
      expect(t.d4nf6c4.ease, isNull);
    });

    test('high ease when popular moves are close to best', () {
      resetNodeIds();
      final parent = makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        ply: 1,
        isWhiteToMove: false,
        evalCp: -30,
      );
      // Both children have nearly equal evals -> easy for opponent
      makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 30,
        moveProbability: 0.6,
        parent: parent,
      );
      makeNode(
        fen: kFenAfterE4C5,
        san: 'c5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 32,
        moveProbability: 0.3,
        parent: parent,
      );

      final tree = BuildTree(root: parent);
      calculateTreeEase(tree);
      expect(parent.ease, isNotNull);
      expect(parent.ease!, greaterThan(0.8));
    });

    test('low ease when popular move is much worse than best', () {
      resetNodeIds();
      final parent = makeNode(
        fen: kFenAfterE4,
        san: 'e4',
        ply: 1,
        isWhiteToMove: false,
        evalCp: -30,
      );
      // Popular move is terrible (eval 300 for opponent = -300 side-to-move)
      makeNode(
        fen: kFenAfterE4E5,
        san: 'e5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: 300,
        moveProbability: 0.7,
        parent: parent,
      );
      // Best move is great (eval -50 for opponent = 50 side-to-move)
      makeNode(
        fen: kFenAfterE4C5,
        san: 'c5',
        ply: 2,
        isWhiteToMove: true,
        evalCp: -50,
        moveProbability: 0.1,
        parent: parent,
      );

      final tree = BuildTree(root: parent);
      calculateTreeEase(tree);
      expect(parent.ease, isNotNull);
      expect(parent.ease!, lessThan(0.5));
    });

    test('returns count of nodes scored', () {
      final t = StandardTree();
      final count = calculateTreeEase(t.toTree());
      // Only internal nodes with evaluated children get ease.
      // root, e4, d4, e4e5, e4c5, d4d5, d4nf6 = 7 candidates,
      // but ply-2 nodes with single children also qualify.
      expect(count, greaterThanOrEqualTo(3));
    });
  });
}
