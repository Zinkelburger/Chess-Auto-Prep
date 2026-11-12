import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_line.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:flutter_test/flutter_test.dart';

List<ChapterLine> linesOf(String games) => parseChapter(
  name: 'Book',
  text: '// Book\n// Color: White\n\n$games',
).lines;

void main() {
  group('a line id', () {
    test('is read from the LineID header, the last of two, never a blank '
        'one', () {
      final [named, blank, none, twice] = linesOf('''
[Event "A"]
[LineID "abc"]

1. e4 *

[Event "B"]
[LineID "  "]

1. d4 *

[Event "C"]

1. c4 *

[Event "D"]
[LineID "old"]
[LineID "new"]

1. Nf3 *
''');
      expect(named.lineId, 'abc');
      expect(blank.lineId, isNull);
      expect(idHeaderAt(blank.tags), -1);
      expect(none.lineId, isNull);
      expect(idHeaderAt(none.tags), -1);
      expect(twice.lineId, 'new');
    });

    test('a LineID that is the first header counts', () {
      final line = linesOf('[Event "A"]\n[LineID "abc"]\n\n1. e4 *\n').single;
      final first = ChapterLine(
        tags: [...line.tags.reversed],
        tree: line.tree,
        text: line.text,
        trailer: line.trailer,
        terminator: line.terminator,
        separator: line.separator,
      );
      expect(idHeaderAt(first.tags), 0);
      expect(first.lineId, 'abc');
    });

    test('a header list with no tags has none', () {
      expect(idHeaderAt(const <PgnHeader>[]), -1);
    });
  });

  test('a line is named by its Event, else by its place', () {
    final [named, unnamed] = linesOf('''
[Event "Najdorf"]

1. e4 *

[Event ""]

1. d4 *
''');
    expect(named.nameAt(0), 'Najdorf');
    expect(unnamed.nameAt(4), 'Line 5');
  });

  test('two lists are the same lines when they hold the same games, one for '
      'one', () {
    final lines = linesOf('[Event "A"]\n\n1. e4 *\n\n[Event "B"]\n\n1. d4 *\n');
    final other = linesOf('[Event "A"]\n\n1. e4 *\n');
    expect(sameLines(lines, lines), isTrue);
    expect(sameLines(lines, [...lines]), isTrue);
    expect(sameLines(lines, [lines.first]), isFalse);
    expect(sameLines(lines, [other.single, lines.last]), isFalse);
    expect(sameLines(lines, [lines.first, other.single]), isFalse);
  });
}
