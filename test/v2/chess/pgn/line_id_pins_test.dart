import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/chess/pgn/line_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/line_id_pins.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two short lines with no id headers, trained under ids worked out from
/// their moves and their places — short enough that the place is part of
/// the id, which the 22 characters of a long line's id never reach — and
/// one that names its own.
const _chapter = '''
// Color: White

[Event "Ruy"]

1. e4 e5 2. Nf3 *

[Event "Italian"]

1. e4 c5 *

[Event "Scotch"]
[LineID "scotch"]

1. d4 *
''';

void main() {
  final chapter = parseChapter(name: 'Open games', text: _chapter);
  final ids = trainedIds(chapter.lines);

  ({Chapter chapter, GamesArranged games}) pinned(ChapterEdit edit) {
    final edited = edit as ChapterEdited;
    return withIdsPinned(chapter, edited.chapter, edited.games);
  }

  test('a game moved up by a delete keeps the id it was trained under', () {
    final after = pinned(lineDeleted(chapter, game: 0));
    expect(trainedIds(after.chapter.lines), [ids[1], 'scotch']);
    expect(after.chapter.lines.first.lineId, ids[1]);
    expect(after.games.rewritten, {1}, reason: 'the pinned game is written');
    expect(writeChapter(after.chapter), contains('[LineID "${ids[1]}"]'));
  });

  test('a line given another move keeps the id it was trained under', () {
    final longer = parseChapter(
      name: 'Open games',
      text: _chapter.replaceFirst('2. Nf3 *', '2. Nf3 Nc6 *'),
    );
    final after = withIdsPinned(
      chapter,
      longer,
      GamesArranged(order: [0, 1, 2], rewritten: {0}, before: 3),
    );
    expect(trainedIds(after.chapter.lines), ids);
    expect(after.chapter.lines.first.lineId, ids[0]);
    expect(after.chapter.lines[1].text, chapter.lines[1].text);
    expect(after.games.rewritten, {0});
  });

  test('a renamed line keeps its bytes: its id does not change', () {
    final edited = renamedLine(chapter, game: 0, name: 'Spanish');
    final after = pinned(edited);
    expect(after.chapter, same((edited as ChapterEdited).chapter));
  });

  test('a game that already names its id is left alone', () {
    final after = pinned(lineDeleted(chapter, game: 1));
    expect(after.chapter.lines.last.text, chapter.lines.last.text);
    expect(after.games.rewritten, isEmpty);
  });

  test('a study is never pinned', () {
    final study = parseChapter(name: 'Study', text: _chapter, game: 0);
    final edited = lineDeleted(study, game: 1) as ChapterEdited;
    final after = withIdsPinned(study, edited.chapter, edited.games);
    expect(identical(after.chapter, edited.chapter), isTrue);
  });

  test('an id header is added after the last tag, moves untouched', () {
    final line = chapter.lines.first;
    final written = withIdHeader(line, 'x')!;
    expect(written.text, startsWith('[Event "Ruy"]\n[LineID "x"]\n'));
    expect(movesOf(written), movesOf(line));
  });

  test('a long line keeps its id wherever it goes, so it is not pinned', () {
    final long = parseChapter(
      name: 'Open games',
      text: _chapter.replaceFirst('1. e4 c5 *', '1. e4 c5 2. Nf3 d6 3. d4 *'),
    );
    final edited = lineDeleted(long, game: 0) as ChapterEdited;
    final after = withIdsPinned(long, edited.chapter, edited.games);
    expect(after.chapter, same(edited.chapter));
  });
}
