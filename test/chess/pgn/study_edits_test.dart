import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/chess/pgn/study.dart';
import 'package:chess_auto_prep/chess/pgn/study_edits.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

String chapterText(String name, String moves) =>
    '[Event "S: $name"]\n[StudyName "S"]\n[ChapterName "$name"]\n\n$moves *\n';

/// A study of [names], one game each, showing chapter [showing].
Chapter study(List<String> names, {int showing = 0, String last = '\n'}) {
  final text = [
    for (final name in names) chapterText(name, '1. e4'),
  ].join('\n');
  return parseChapter(
    name: 'S',
    text: last == '\n' ? text : text.substring(0, text.length - 1) + last,
    game: showing,
  );
}

List<String> names(Chapter chapter) => [
  for (final c in studyChapters(chapter.lines)) c.name,
];

ChapterEdited edited(ChapterEdit edit) => edit as ChapterEdited;

void main() {
  group('moving a chapter', () {
    test('moves it one place, the shown chapter followed', () {
      final moved = edited(
        moveChapter(study(['A', 'B', 'C'], showing: 2), index: 1, by: 1),
      ).chapter;
      expect(names(moved), ['A', 'C', 'B']);
      expect(moved.game, 1, reason: 'C was shown and is now second');
    });

    test('past either end, or from no chapter, is refused', () {
      final three = study(['A', 'B', 'C']);
      expect(
        (moveChapter(three, index: 0, by: -1) as ChapterEditRefused).reason,
        'That chapter is already first.',
      );
      expect(
        (moveChapter(three, index: 2, by: 1) as ChapterEditRefused).reason,
        'That chapter is already last.',
      );
      expect(moveChapter(three, index: 5, by: -1), isA<ChapterEditRefused>());
    });
  });

  group('deleting a chapter', () {
    int? showingAfter(int showing, int index) => edited(
      deleteChapter(study(['A', 'B', 'C'], showing: showing), index: index),
    ).chapter.game;

    test('keeps a study of one, and lets a study of two lose one', () {
      expect(deleteChapter(study(['A']), index: 0), isA<ChapterEditRefused>());
      expect(
        names(edited(deleteChapter(study(['A', 'B']), index: 0)).chapter),
        ['B'],
      );
    });

    test('of another chapter keeps the shown one on the board', () {
      expect(showingAfter(0, 2), 0);
      expect(showingAfter(2, 0), 1);
    });

    test('of the shown chapter shows the one that took its place', () {
      expect(showingAfter(0, 0), 0);
      expect(showingAfter(1, 1), 1);
      expect(showingAfter(2, 2), 1);
    });
  });

  test('renaming a chapter that is not in the study is refused', () {
    expect(
      renameChapter(study(['A']), study: 'S', index: 3, name: 'X'),
      isA<ChapterEditRefused>(),
    );
  });

  group('adding a chapter', () {
    ChapterEdit add(Chapter to, {String name = 'New'}) =>
        addChapter(to, study: 'S', name: name, orientation: Side.white);

    test('puts a blank line before it, after a study of one or of more', () {
      for (final chapters in [
        ['A'],
        ['A', 'B'],
      ]) {
        final text = writeChapter(edited(add(study(chapters))).chapter);
        expect(text, contains('*\n\n[Event "S: New"]'), reason: '$chapters');
      }
    });

    test('ends the file the way it ended before', () {
      final text = writeChapter(
        edited(add(study(['A', 'B'], last: ''))).chapter,
      );
      expect(text, endsWith('*'));
    });

    test('writes a file that ends its games in CRLF in CRLF', () {
      // Only the game's ending says so: its tag and moves share a line.
      final crlf = parseChapter(
        name: 'S',
        text: '[Event "S: A"] 1. e4 *\r\n',
        game: 0,
      );
      final text = writeChapter(edited(add(crlf)).chapter);
      expect(text, contains('[Event "S: New"]\r\n'));
    });

    test('a name that cannot be written is refused', () {
      expect(add(study(['A']), name: 'two\nlines'), isA<ChapterEditRefused>());
    });
  });
}
