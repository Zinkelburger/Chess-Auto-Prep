import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/study_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

const annotated = '''[Event "Study: First"]
[StudyName "Study"]
[ChapterName "First"]
[Result "*"]
[Unknown "keep me"]

{Introduction [%csl Re4]} 1. e4! {main} (1. d4 {side} d5) e5 *

[Event "Study: Second"]
[ChapterName "Second"]

1. Nf3 *
''';
void main() {
  test(
    'clear annotations keeps every move and unknown tag; second game is exact',
    () {
      final before = parseChapter(name: 'Study', text: annotated, game: 0);
      final edit =
          cleanStudyChapter(before, 0, annotations: true) as ChapterEdited;
      expect(edit.games.rewritten, {0});
      expect(edit.chapter.lines.last.text, before.lines.last.text);
      final tree = edit.chapter.lines.first.tree!;
      expect(tree.rootComment, isNull);
      expect(tree.children.length, 2);
      expect(tree.children.first.nags, isEmpty);
      expect(tree.children.first.comment, isNull);
      expect(tree.children.last.comment, isNull);
      expect(tree.children.first.children.single.san, 'e5');
      expect(tagValue(edit.chapter.lines.first.tags, 'Unknown'), 'keep me');
    },
  );
  test('clear variations retains mainline notes, glyphs and introduction', () {
    final before = parseChapter(name: 'Study', text: annotated, game: 0);
    final edit =
        cleanStudyChapter(before, 0, annotations: false) as ChapterEdited;
    final tree = edit.chapter.lines.first.tree!;
    expect(tree.rootComment, contains('Introduction'));
    expect(tree.children.single.nags, [1]);
    expect(tree.children.single.comment, 'main');
    expect(studyContentCount(tree).moves, 2);
    expect(edit.chapter.lines.last.text, before.lines.last.text);
  });
  test(
    'tag edit keeps owned and unknown raw headers and synchronizes Result',
    () {
      final before = parseChapter(name: 'Study', text: annotated, game: 0);
      final edit =
          editStudyTags(before, 0, {
                'Result': '1-0',
                'Unknown': 'keep me',
                'Annotator': 'A "quote"',
              })
              as ChapterEdited;
      final line = edit.chapter.lines.first;
      expect(tagValue(line.tags, 'StudyName'), 'Study');
      expect(tagValue(line.tags, 'Annotator'), 'A "quote"');
      expect(line.terminator, '1-0');
      expect(line.text, contains('e5 1-0'));
      expect(
        editStudyTags(before, 0, {'FEN': 'bad'}),
        isA<ChapterEditRefused>(),
      );
      expect(
        editStudyTags(before, 0, {'Result': 'draw'}),
        isA<ChapterEditRefused>(),
      );
    },
  );
  test(
    'reset root strips stale FEN when returning to start and keeps other game',
    () {
      final before = parseChapter(
        name: 'Study',
        text:
            '[Event "Study: First"]\n[FEN "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"]\n[SetUp "1"]\n[Unknown "saved"]\n\n1. e4 *\n\n[Event "Second"]\n\n1. d4 *\n',
        game: 0,
      );
      final edit = resetStudyChapter(before, 0, Fen.initial) as ChapterEdited;
      expect(edit.chapter.lines.first.tree!.rootFen, Fen.initial);
      expect(edit.chapter.lines.first.tree!.children, isEmpty);
      expect(tagValue(edit.chapter.lines.first.tags, 'FEN'), isNull);
      expect(tagValue(edit.chapter.lines.first.tags, 'Unknown'), 'saved');
      expect(edit.chapter.lines.last.text, before.lines.last.text);
      expect(
        resetStudyChapter(before, 0, const Fen('bad')),
        isA<ChapterEditRefused>(),
      );
    },
  );
  test('malformed source is protected against every rewrite', () {
    final before = parseChapter(
      name: 'Bad',
      text: '[Event "Bad"]\n\n1. e4 Qz9 *\n',
      game: 0,
    );
    expect(
      cleanStudyChapter(before, 0, annotations: true),
      isA<ChapterEditRefused>(),
    );
    expect(
      editStudyTags(before, 0, {'Result': '*'}),
      isA<ChapterEditRefused>(),
    );
    expect(
      resetStudyChapter(before, 0, Fen.initial),
      isA<ChapterEditRefused>(),
    );
  });
}
