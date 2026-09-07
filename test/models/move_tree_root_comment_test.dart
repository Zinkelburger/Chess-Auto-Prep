/// The comment before the first move (a Lichess chapter's introduction,
/// shapes drawn on the start position) is part of the tree, and the
/// chapter-wide clear operations behave like Lichess's.
library;

import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('root comment', () {
    test('survives a PGN round-trip, shapes included', () {
      final tree = MoveTree.fromPgn(
        '{ Welcome. [%cal Ge2e4] } 1. e4 e5 { Classical. } *',
      );
      expect(tree.rootComment, 'Welcome. [%cal Ge2e4]');
      expect(tree.roots.single.san, 'e4');
      final text = tree.toPgnMoveText();
      expect(text, startsWith('{Welcome. [%cal Ge2e4]} 1. e4'));
      expect(MoveTree.fromPgn(text).rootComment, 'Welcome. [%cal Ge2e4]');
    });

    test('is written even when the tree has no moves', () {
      final tree = MoveTree()..rootComment = 'Set-up notes';
      expect(tree.toPgnMoveText(), '{Set-up notes}');
      expect(
        MoveTree.fromPgn(tree.toPgnMoveText()).rootComment,
        'Set-up notes',
      );
    });

    test('setComment / commentAt address it through the empty path', () {
      final tree = MoveTree.fromMoves(['e4']);
      expect(tree.commentAt(TreePath.empty), isNull);
      final before = tree.version;
      tree.setComment(TreePath.empty, 'Intro');
      expect(tree.commentAt(TreePath.empty), 'Intro');
      expect(tree.version, greaterThan(before));
      tree.setComment(TreePath.empty, '   ');
      expect(tree.rootComment, isNull);
    });

    test('copyWithFreshIds keeps it', () {
      final tree = MoveTree.fromMoves(['d4'])..rootComment = 'Queen pawn';
      expect(tree.copyWithFreshIds().rootComment, 'Queen pawn');
    });
  });

  test('a comment written before a move joins that move rather than '
      'vanishing', () {
    final tree = MoveTree.fromPgn(
      '1. e4 e5 (1... { The Sicilian. } c5 { Sharp. }) 2. Nf3 *',
    );
    final c5 = tree.nodeAt(const TreePath([0, 1]))!;
    expect(c5.san, 'c5');
    expect(c5.comment, 'The Sicilian. Sharp.');
  });

  group('clearAnnotations', () {
    test('drops comments, glyphs and the root comment, keeps moves', () {
      final tree = MoveTree.fromPgn(
        '{ Intro } 1. e4! { good } e5 (1... c5 \$2 { [%csl Rc5] }) 2. Nf3 *',
      );
      tree.clearAnnotations();
      expect(tree.rootComment, isNull);
      void check(List<MoveNode> nodes) {
        for (final n in nodes) {
          expect(n.comment, isNull, reason: n.san);
          expect(n.nags, isNull, reason: n.san);
          check(n.children);
        }
      }

      check(tree.roots);
      expect(tree.sanSequenceAt(const TreePath([0, 0, 0])), [
        'e4',
        'e5',
        'Nf3',
      ]);
      expect(tree.nodeAt(const TreePath([0, 1]))?.san, 'c5');
    });
  });

  group('clearVariations', () {
    test('keeps the mainline and its annotations only', () {
      final tree = MoveTree.fromPgn(
        '1. e4 { main } (1. d4 d5) e5 (1... c5 2. Nf3 (2. c3)) 2. Nf3 *',
      );
      tree.clearVariations();
      expect(tree.roots, hasLength(1));
      expect(tree.roots.single.comment, 'main');
      expect(tree.roots.single.children, hasLength(1));
      expect(tree.sanSequenceAt(tree.mainlineEndFrom(TreePath.empty)), [
        'e4',
        'e5',
        'Nf3',
      ]);
      expect(tree.nodeAt(const TreePath([0, 1])), isNull);
    });

    test('is a no-op on an empty tree', () {
      final tree = MoveTree();
      tree.clearVariations();
      expect(tree.isEmpty, isTrue);
    });
  });
}
