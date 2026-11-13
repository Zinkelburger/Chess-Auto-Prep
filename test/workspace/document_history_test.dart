import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/workspace/document/document_history.dart';
import 'package:chess_auto_prep/workspace/document/document_projection.dart';
import 'package:flutter_test/flutter_test.dart';

Chapter _board([String moves = '1. e4']) =>
    parseChapter(name: 'Board', text: '$moves *\n');

void main() {
  group('held edits', () {
    final original = (chapter: _board(), view: null);
    Landing landing() => (
      text: '',
      scope: const WholeDocument(),
      chapter: _board('1. d4'),
      view: null,
    );

    test('are not empty once made, nor after an edit made on the original '
        'again', () {
      final held = HeldEdits(original, landing());
      expect(held.isEmpty, isFalse);
      held.takeBack();
      expect(held.isEmpty, isTrue);
      held.add(original, landing());
      expect(held.isEmpty, isFalse);
    });

    test('keep a hundred steps to undo', () {
      final held = HeldEdits(original, landing());
      for (var i = 0; i < HeldEdits.undoDepth; i++) {
        held.add((chapter: _board(), view: null), landing());
      }
      for (var i = 0; i < 100; i++) {
        held.takeBack();
      }
      expect(held.canUndo, isFalse);
      expect(held.isEmpty, isFalse, reason: 'the original was dropped');
    });
  });

  test('the analysis board keeps its last two hundred versions, oldest '
      'dropped first', () {
    final board = KeptBoard(_board());
    expect(board.canUndo, isFalse);
    expect(board.takeBack(), isNull);
    final versions = [for (var i = 0; i <= 200; i++) _board()];
    versions.forEach(board.remember);
    expect(board.canUndo, isTrue);
    Chapter? last;
    for (var i = 0; i < 200; i++) {
      last = board.takeBack();
      expect(last, isNotNull);
    }
    expect(last, same(versions[1]));
    expect(board.takeBack(), isNull);
    expect(board.canUndo, isFalse);
  });
}
