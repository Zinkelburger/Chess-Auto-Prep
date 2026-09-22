import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_text.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  group('a chapter read and written again is the same file', () {
    for (final entry in chapterFixtures.entries) {
      test(entry.key, () {
        final chapter = parseChapter(name: 'Chapter', text: entry.value);
        expect(writeChapter(chapter), entry.value);
        expect(chapter.issues, isEmpty);
      });
    }

    test('a file with no trailing newline keeps not having one', () {
      const text = '[Event "A"]\n[Result "*"]\n\n1. e4 *';
      expect(writeChapter(parseChapter(name: 'A', text: text)), text);
    });

    test('a file that is nothing but a preamble is all preamble', () {
      final chapter = parseChapter(name: 'New', text: emptyChapter);
      expect(chapter.preamble, emptyChapter);
      expect(chapter.lines, isEmpty);
      expect(chapter.tree.isEmpty, isTrue);
      expect(chapter.side, Side.white);
    });
  });

  group('the games of a chapter', () {
    final chapter = parseChapter(name: 'Queen\'s Gambit', text: whiteChapter);

    test('keep every tag the file gave them, in order', () {
      final tags = chapter.lines.first.tags;
      expect(tags.whereType<PgnTag>().map((t) => t.key).take(5), [
        'Event',
        'White',
        'Black',
        'Result',
        'LineID',
      ]);
      expect(tagValue(tags, 'CumProb'), '0.42');
      expect(tagValue(tags, 'Annotator'), 'Chess Auto Prep');
      expect(tagValue(tags, 'PassCount'), '3');
    });

    test('carry the id every later lookup uses', () {
      expect(chapter.lines.map((line) => line.lineId), [
        'line_MS4gZDQgZDUgMi4gYzQ',
        'line_MS4gZDQgZDUgMi4gYzUx',
        'line_MS4gZDQgZDUgMi4gYzYy',
      ]);
    });

    test('merge into one tree, the first game first', () {
      expect(chapter.gameCount, 3);
      expect(chapter.skippedGames, 0);
      expect(chapter.tree.rootComment, 'Our repertoire against 1... d5.');
      final d4 = chapter.tree.children.single;
      expect(d4.children.map((n) => n.san), ['d5', 'Nf6']);
      final c4 = d4.children.first.children.single;
      expect(c4.children.map((n) => n.san), ['e6', 'c6']);
    });

    test('a game from another root stays out of the tree and in the file', () {
      final other = parseChapter(name: 'Sicilian', text: blackChapter);
      expect(other.gameCount, 2);
      expect(other.skippedGames, 1);
      expect(other.lines.last.text, contains('[Event "Elsewhere"]'));
      expect(writeChapter(other), blackChapter);
    });
  });
}
