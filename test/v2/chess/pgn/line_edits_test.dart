// A line is one game of the chapter file, so renaming or removing one is an
// edit to whole games. What matters is that nothing else in the file moves.
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/v2/chess/pgn/line_edits.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

Chapter white() => parseChapter(name: 'Gambit', text: whiteChapter);

ChapterEdited edited(ChapterEdit edit) => edit as ChapterEdited;

void main() {
  test('renaming a line writes its Event tag and nothing else', () {
    final before = white();

    final after = edited(renamedLine(before, game: 1, name: 'The Slav'));

    expect(tagValue(after.chapter.lines[1].tags, 'Event'), 'The Slav');
    expect(after.chapter.lines[1].text, contains('[Event "The Slav"]'));
    expect(after.chapter.lines[1].text, contains('[CumProb "0.31"]'));
    expect(after.chapter.lines[1].text, endsWith('3. Nf3 *'));
    expect(after.games.rewritten, {1});
    expect(after.games.order, [0, 1, 2]);
  });

  test('renaming leaves every other game byte for byte', () {
    final before = white();

    final after = edited(renamedLine(before, game: 1, name: 'The Slav'));

    expect(after.chapter.lines[0].text, before.lines[0].text);
    expect(after.chapter.lines[2].text, before.lines[2].text);
  });

  test('renaming a line to the name it has writes nothing', () {
    final before = white();
    final name = tagValue(before.lines[0].tags, 'Event')!;

    expect(renamedLine(before, game: 0, name: name), isA<ChapterUnchanged>());
  });

  test('deleting a line takes its game out and moves no other', () {
    final before = white();

    final after = edited(lineDeleted(before, game: 1));

    expect(after.chapter.lines, hasLength(2));
    expect(after.chapter.lines[0].text, before.lines[0].text);
    expect(after.chapter.lines[1].text, before.lines[2].text);
    expect(after.games.order, [0, 2]);
    expect(after.games.rewritten, isEmpty);
    expect(writeChapter(after.chapter), isNot(contains('The Slav')));
  });

  test('the file a deletion produces reads back as the chapter it made', () {
    final after = edited(lineDeleted(white(), game: 0));

    final reread = parseChapter(
      name: 'Gambit',
      text: writeChapter(after.chapter),
    );

    expect(reread.lines.map((line) => line.text), [
      for (final line in after.chapter.lines) line.text,
    ]);
  });

  test('changing the side rewrites the Color line where it stands', () {
    final before = white();

    final after = edited(sideSet(before, Side.black));

    expect(after.chapter.side, Side.black);
    expect(
      writeChapter(after.chapter),
      startsWith(
        "// Queen's Gambit\n"
        '// Color: Black\n'
        '// Chapter: 1) Exchange\n',
      ),
    );
    expect(after.games.heading, isTrue);
    expect(after.games.rewritten, isEmpty);
  });

  test('changing the side leaves every game where it was', () {
    final before = white();

    final after = edited(sideSet(before, Side.black));

    expect(
      after.chapter.lines.map((line) => line.text),
      before.lines.map((line) => line.text),
    );
    expect(after.games.order, [0, 1, 2]);
  });

  test('a chapter with no Color line gains one above what it says', () {
    final before = parseChapter(
      name: 'Imported',
      text: '// Imported\n\n[Event "One"]\n[Result "*"]\n\n1. e4 *\n',
    );

    final after = edited(sideSet(before, Side.black));

    expect(after.chapter.side, Side.black);
    expect(after.chapter.preamble, '// Color: Black\n// Imported\n\n');
  });

  test('setting the side it already has writes nothing', () {
    expect(sideSet(white(), Side.white), isA<ChapterUnchanged>());
  });
}
