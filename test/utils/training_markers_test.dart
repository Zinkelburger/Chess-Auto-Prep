import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/utils/pgn_comment_utils.dart'
    show filterDisplayComment;
import 'package:chess_auto_prep/utils/training_markers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('marker tokens in comments', () {
    test('detects tokens regardless of surrounding prose', () {
      expect(hasPuzzleStart('[%tstart]'), isTrue);
      expect(hasPuzzleStart('Only move. [%tstart]'), isTrue);
      expect(hasPuzzleStart('Only move.'), isFalse);
      expect(hasPuzzleStart(null), isFalse);
      expect(hasPuzzleEnd('done [%tend]'), isTrue);
      expect(hasPuzzleEnd('[%tstart]'), isFalse);
    });

    test('writePuzzleMarker adds and removes without touching prose or '
        'other tokens', () {
      expect(writePuzzleMarker(null, start: true, on: true), '[%tstart]');
      expect(
        writePuzzleMarker('Key square. [%cal Gd4e5]', start: true, on: true),
        'Key square. [%cal Gd4e5] [%tstart]',
      );
      expect(
        writePuzzleMarker('Key square. [%tstart]', start: true, on: false),
        'Key square.',
      );
      expect(writePuzzleMarker('[%tstart]', start: true, on: false), isNull);
      // Start and end are independent tokens.
      expect(
        writePuzzleMarker('[%tstart]', start: false, on: true),
        '[%tstart] [%tend]',
      );
    });

    test('markers never appear in displayed prose', () {
      expect(filterDisplayComment('Solve this. [%tstart]'), 'Solve this.');
      expect(filterDisplayComment('[%tend]'), isEmpty);
    });
  });

  group('togglePuzzleMarker on a tree', () {
    MoveTree tree() =>
        MoveTree.fromMoves(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6']);

    test('setting a start clears any previous start (one per chapter)', () {
      final t = tree();
      final first = TreePath.empty.child(0);
      final third = first.child(0).child(0);
      t.setComment(first, 'Old start. [%tstart]');

      final on = togglePuzzleMarker(
        t,
        third,
        start: true,
        setComment: t.setComment,
      );

      expect(on, isTrue);
      expect(t.nodeAt(first)!.comment, 'Old start.');
      expect(hasPuzzleStart(t.nodeAt(third)!.comment), isTrue);
    });

    test('toggling the marked move off leaves its prose', () {
      final t = tree();
      final first = TreePath.empty.child(0);
      t.setComment(first, 'Best by test. [%tstart]');

      final on = togglePuzzleMarker(
        t,
        first,
        start: true,
        setComment: t.setComment,
      );

      expect(on, isFalse);
      expect(t.nodeAt(first)!.comment, 'Best by test.');
    });

    test('start and end markers do not disturb each other', () {
      final t = tree();
      final first = TreePath.empty.child(0);
      togglePuzzleMarker(t, first, start: true, setComment: t.setComment);
      togglePuzzleMarker(t, first, start: false, setComment: t.setComment);

      final comment = t.nodeAt(first)!.comment;
      expect(hasPuzzleStart(comment), isTrue);
      expect(hasPuzzleEnd(comment), isTrue);
    });
  });
}
