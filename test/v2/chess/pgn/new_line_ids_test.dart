// A line added to a chapter gets an id no other game is known by. A game
// with no id header is trained under an id worked out from its moves and its
// place, and for a long line that id is the same whatever the place — so the
// id a new line would be given can already be another game's.
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edits.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_sections.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/chess/pgn/line_id_pins.dart';
import 'package:chess_auto_prep/v2/chess/pgn/line_moves.dart';
import 'package:flutter_test/flutter_test.dart';

/// A long line with no id header.
const _ruy = '''
// Color: White

[Event "Ruy"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *
''';

/// `3. Bb5`, which has one reply: a move played there is a game of its own.
final _bb5 = NodePath.of([0, 0, 0, 0, 0]);

void main() {
  final chapter = parseChapter(name: 'Ruy', text: _ruy);
  final ruy = trainedIds(chapter.lines).single!;

  test('a long line is trained under the id a line after it would get', () {
    final sans = ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5'];
    expect(newLineId([...sans, 'Nf6'], 1, const {}), ruy);
  });

  test('a branch written as a new game gets an id of its own', () {
    final result = addMove(chapter, at: _bb5, uci: 'g8f6') as MoveAdded;
    final added = result.chapter.lines.last;
    expect(result.chapter.lines, hasLength(2));
    expect(added.lineId, isNot(ruy));
    expect(trainedIds(result.chapter.lines), [ruy, added.lineId]);
  });

  test('a line dropped on the chapter carrying that id gets its own', () {
    final other = parseChapter(
      name: 'Other',
      text:
          '[Event "Berlin"]\n[LineID "$ruy"]\n\n'
          '1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 *\n',
    ).lines.single;
    final after = linesAddedTo(chapter, lines: [other]) as ChapterEdited;
    final added = after.chapter.lines.last;
    expect(added.lineId, isNot(ruy));
    expect(trainedIds(after.chapter.lines), [ruy, added.lineId]);
    expect(movesOf(added), movesOf(other));
  });

  test('a game added to one chapter of a course gets an id no game of the '
      'file has', () {
    const course = '''
// Color: White

[Event "Ruy"]
[ChapterName "Open games"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *

[Event "Berlin"]
[ChapterName "Berlin"]
[LineID "berlin"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 *
''';
    final file = parseChapter(name: 'Course', text: course);
    expect(trainedIds(file.lines), [ruy, 'berlin']);
    final view = sectionView(file, 'Berlin');
    final result = addMove(view.chapter, at: _bb5, uci: 'd7d6') as MoveAdded;
    final back = spliced(
      view,
      result.chapter,
      GamesArranged.of(result.written, before: view.chapter.lines.length),
    )!;
    final added = back.file.lines.last;
    expect(back.games.order, [0, 1, null]);
    expect(sectionOf(added), 'Berlin');
    expect(added.lineId, isNot(ruy));
    expect(trainedIds(back.file.lines), [ruy, 'berlin', added.lineId]);
  });

  test('every id a chapter is known by is in use, headers and worked out', () {
    const two =
        '$_ruy\n[Event "Scotch"]\n[LineID "scotch"]\n\n1. e4 e5 2. d4 *\n';
    expect(idsInUse(parseChapter(name: 'Two', text: two)), {ruy, 'scotch'});
  });
}
