import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_sections.dart';
import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/chess/pgn/line_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/line_id_pins.dart';
import 'package:chess_auto_prep/v2/chess/pgn/line_moves.dart';
import 'package:chess_auto_prep/v2/chess/training/training_line.dart';
import 'package:flutter_test/flutter_test.dart';

/// A course in one file: two chapters by tag, their games interleaved the
/// way a hand-edited file ends up, and one game that names no chapter.
const _course = '''
// Color: White

[Event "Ruy"]
[ChapterName "Open games"]

1. e4 e5 2. Nf3 *

[Event "Sicilian"]
[ChapterName "Sicilian"]

1. e4 c5 *

[Event "Loose"]

1. d4 *

[Event "Italian"]
[ChapterName "Open games"]

1. e4 e5 2. Bc4 *
''';

void main() {
  final file = parseChapter(name: 'Course', text: _course);

  test('the chapters are the names, in the order they first appear', () {
    expect(sectionsIn(file.lines), ['Open games', 'Sicilian', null]);
    expect(sectionsInText(_course), ['Open games', 'Sicilian', null]);
  });

  test('a file with no names is one chapter', () {
    expect(sectionsInText('[Event "a"]\n\n1. e4 *\n'), [null]);
    expect(sectionsInText('// Color: White\n'), [null]);
  });

  test('a file whose games all carry one name is one chapter too', () {
    // Singleton identity stays named; an older whole-file ref still reads it.
    const one = '[Event "a"]\n[ChapterName "KID"]\n\n1. d4 *\n';
    expect(sectionsInText(one), ['KID']);
    final file = parseChapter(name: 'Renamed', text: one);
    final view = sectionView(file, null);
    expect(view.places, [0]);
    expect(view.isWholeFile, isFalse, reason: 'a new line takes the name');
    final other = parseChapter(name: 'x', text: '[Event "b"]\n\n1. e4 *\n');
    final edited =
        linesAddedTo(view.chapter, lines: other.lines) as ChapterEdited;
    final back = spliced(view, edited.chapter, edited.games)!;
    expect(sectionOf(back.file.lines.last), 'KID');
    expect(sectionsInText(writeChapter(back.file)), ['KID']);
  });

  test('a chapter is its games wherever they sit, trained as the file', () {
    final view = sectionView(file, 'Open games');
    expect(view.places, [0, 3]);
    expect(view.chapter.lines.map((l) => l.nameAt(0)), ['Ruy', 'Italian']);
    expect(view.chapter.name, 'Open games');
    final ids = trainedIds(file.lines);
    expect(trainingLines(view.chapter, source: 'f').map((l) => l.key.id), [
      ids[0],
      ids[3],
    ]);
    expect(view.isWholeFile, isFalse);
  });

  test('an edit of a chapter goes back into its places', () {
    final view = sectionView(file, 'Open games');
    final edited = renamedLine(view.chapter, game: 1, name: 'Giuoco');
    edited as ChapterEdited;
    final back = spliced(view, edited.chapter, edited.games)!;
    expect(back.file.lines.map((l) => l.nameAt(0)), [
      'Ruy',
      'Sicilian',
      'Loose',
      'Giuoco',
    ]);
    expect(back.games.order, [0, 1, 2, 3]);
    expect(back.games.rewritten, {3});
    expect(back.file.lines[1].text, file.lines[1].text);
  });

  test('a deleted game leaves its place; the others keep theirs', () {
    final view = sectionView(file, 'Open games');
    final edited = lineDeleted(view.chapter, game: 0) as ChapterEdited;
    final back = spliced(view, edited.chapter, edited.games)!;
    expect(back.games.order, [1, 2, 3]);
    expect(back.games.rewritten, isEmpty);
    expect(writeChapter(back.file), isNot(contains('Ruy')));
    expect(writeChapter(back.file), endsWith('1. e4 e5 2. Bc4 *\n'));
  });

  test('a game added to a chapter goes at the end with its name', () {
    final view = sectionView(file, 'Sicilian');
    final other = parseChapter(
      name: 'x',
      text: '[Event "Najdorf"]\n\n1. e4 c5 2. Nf3 *\n',
    );
    final edited =
        linesAddedTo(view.chapter, lines: other.lines) as ChapterEdited;
    final back = spliced(view, edited.chapter, edited.games)!;
    expect(back.games.order, [0, 1, 2, 3, null]);
    expect(sectionOf(back.file.lines.last), 'Sicilian');
    final text = writeChapter(back.file);
    expect(
      text,
      endsWith(
        '1. e4 e5 2. Bc4 *\n\n'
        '[Event "Najdorf"]\n[ChapterName "Sicilian"]\n\n1. e4 c5 2. Nf3 *\n',
      ),
    );
    expect(sectionsInText(text), ['Open games', 'Sicilian', null]);
  });

  test('the games with no name are a chapter of their own', () {
    final view = sectionView(file, null);
    expect(view.places, [2]);
    expect(view.isWholeFile, isFalse);
    final plain = parseChapter(name: 'p', text: '[Event "a"]\n\n1. e4 *\n');
    expect(sectionView(plain, null).isWholeFile, isTrue);
  });

  test('a line takes another chapter name, or none, moves untouched', () {
    final line = file.lines.first;
    final moved = withSection(line, 'Sicilian')!;
    expect(sectionOf(moved), 'Sicilian');
    expect(movesOf(moved), movesOf(line));
    expect(moved.text, startsWith('[Event "Ruy"]\n[ChapterName "Sicilian"]\n'));
    final loose = withSection(line, null)!;
    expect(sectionOf(loose), isNull);
    expect(loose.text, startsWith('[Event "Ruy"]\n\n1. e4'));
  });

  test('a name with a quote in it reads back as written', () {
    final line = withSection(file.lines[2], 'The "best" line')!;
    expect(sectionOf(line), 'The "best" line');
    expect(sectionsInText('${line.text}\n\n${file.lines[0].text}\n'), [
      'The "best" line',
      'Open games',
    ]);
  });

  test('the names read off the text are the names the games carry', () {
    const tricky = r'''
[Event "a"] [ChapterName "Two on a line"]

1. e4 *

[Event "b"]
[ChapterName "Moves beside it"] 1. d4 {a "quoted" word} *

[Event "c"]
[ChapterName "Escaped \"quote\" and slash \\"]

1. c4 *
''';
    final lines = parseChapter(name: 'Tricky', text: tricky).lines;
    expect(sectionsInText(tricky), [
      'Two on a line',
      'Moves beside it',
      r'Escaped "quote" and slash \',
    ]);
    expect(sectionsInText(tricky), chapterSections(lines));
  });

  test('a view over the arrangement that composes with others', () {
    final view = sectionView(file, 'Open games');
    final back = spliced(
      view,
      view.chapter,
      GamesArranged(order: [1, 0], before: 2),
    )!;
    expect(back.games.order, [3, 1, 2, 0]);
  });
}
