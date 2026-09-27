import 'package:chess_auto_prep/v2/chess/pgn/comment_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/move_label.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_merge.dart';
import 'package:flutter_test/flutter_test.dart';

GameTree treeOf(String pgn) => readGame(pgn).tree!;

void main() {
  group('NodePath', () {
    test('is a value', () {
      expect(NodePath.of([0, 1]), NodePath.of([0, 1]));
      expect(NodePath.of([0, 1]).hashCode, NodePath.of([0, 1]).hashCode);
      expect(NodePath.of([0, 1]), isNot(NodePath.of([0, 2])));
    });

    test('walks up and down', () {
      final path = const NodePath.root().child(0).child(2);
      expect(path.indexes, [0, 2]);
      expect(path.parent, NodePath.of([0]));
      expect(const NodePath.root().parent.isRoot, isTrue);
    });

    test('knows where the variation it is in branches off', () {
      expect(NodePath.of([0, 0, 0]).branchPoint, isNull, reason: 'main line');
      expect(const NodePath.root().branchPoint, isNull);
      expect(NodePath.of([0, 1]).branchPoint, NodePath.of([0]));
      expect(NodePath.of([0, 1, 0, 0]).branchPoint, NodePath.of([0]));
      expect(NodePath.of([0, 2, 1, 0]).branchPoint, NodePath.of([0, 2]));
    });
  });

  group('GameTree', () {
    final tree = treeOf('1. e4 e5 (1... c5 2. Nf3) 2. Nf3 *');

    test('finds nodes and lines by path', () {
      expect(tree.nodeAt(NodePath.of([0, 1, 0]))?.san, 'Nf3');
      expect(tree.lineTo(NodePath.of([0, 1])).map((n) => n.san), ['e4', 'c5']);
      expect(tree.nodeAt(const NodePath.root()), isNull);
      expect(tree.nodeAt(NodePath.of([0, 5])), isNull);
      expect(tree.lineTo(NodePath.of([0, 5])), isEmpty);
    });

    test('follows the main line to its end', () {
      expect(tree.endOfLineFrom(const NodePath.root()), NodePath.of([0, 0, 0]));
      expect(tree.endOfLineFrom(NodePath.of([0, 1])), NodePath.of([0, 1, 0]));
    });
  });

  group('mergeForests', () {
    test('keeps the first forest\'s order and adds new moves after', () {
      final a = treeOf('1. e4 e5 2. Nf3 *').children;
      final b = treeOf('1. e4 c5 (1... e5 2. Nc3) *').children;
      final merged = mergeForests(a, b);
      final e4 = merged.single;
      expect(e4.children.map((n) => n.san), ['e5', 'c5']);
      expect(e4.children[0].children.map((n) => n.san), ['Nf3', 'Nc3']);
    });

    test('keeps the first comment and fills in a missing one', () {
      final a = treeOf('1. e4 {A} e5 *').children;
      final b = treeOf('1. e4 {B} e5 {only here} *').children;
      final e4 = mergeForests(a, b).single;
      expect(e4.comment, 'A');
      expect(e4.children.single.comment, 'only here');
    });
  });

  test('move number labels', () {
    final tree = treeOf('1. e4 e5 2. Nf3 *');
    final [e4] = tree.children;
    final [e5] = e4.children;
    expect(moveNumberLabel(e4, startsLine: true), '1.');
    expect(moveNumberLabel(e5, startsLine: false), '');
    expect(moveNumberLabel(e5, startsLine: true), '1...');
  });

  test('display comment drops machine tokens', () {
    expect(
      displayComment('Good [%eval 0.3] move  [%clk 0:01:00]'),
      'Good move',
    );
    expect(displayComment('[%score 46.4%]'), '');
    expect(nagGlyph(3), '!!');
    expect(nagGlyph(140), isNull);
  });
}
