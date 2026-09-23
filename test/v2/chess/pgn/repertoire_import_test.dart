import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_sections.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/chess/pgn/repertoire_import.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

GameTree line(String moves) =>
    readGame('[Event "x"]\n[Result "*"]\n\n$moves *\n').tree!;

void main() {
  final created = DateTime(2026, 9, 22, 12, 0, 0);

  ImportedChapters imported(String text) =>
      readImport(text, created: created) as ImportedChapters;

  Chapter chapterOf(ImportedChapter chapter) =>
      parseChapter(name: chapter.title, text: chapter.text);

  String fixture(String name) =>
      File('test/fixtures/v2_pgn/$name').readAsStringSync();

  test(
    'a game with variations becomes one line per leaf, in reading order',
    () {
      final read = imported('''
[Event "Italian"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 (3... Nf6 4. d3 (4. Ng5 d5)) 4. c3 *
''');
      expect(read.lines, 3);
      final chapter = chapterOf(read.chapters.single);
      expect(read.chapters.single.title, 'Main');
      expect(chapter.lines, hasLength(3));
      expect(chapter.lines[0].text, endsWith('3. Bc4 Bc5 4. c3 *'));
      expect(chapter.lines[1].text, endsWith('3. Bc4 Nf6 4. d3 *'));
      expect(chapter.lines[2].text, endsWith('3. Bc4 Nf6 4. Ng5 d5 *'));
      // The main line keeps the game's name; a sideline is named for the move
      // where it left it and records where it branched.
      expect(chapter.lines[0].text, contains('[Event "Italian"]'));
      expect(chapter.lines[1].text, contains('[Event "Italian — 3...Nf6"]'));
      expect(chapter.lines[1].text, contains('[BranchPlies "5"]'));
      expect(chapter.lines[2].text, contains('[Event "Italian — 4.Ng5"]'));
      expect(chapter.lines[2].text, contains('[BranchPlies "5 6"]'));
      // Each line is a game the reader takes whole.
      for (final line in chapter.lines) {
        expect(line.isWhole, isTrue, reason: line.text);
      }
    },
  );

  test(
    'a sideline drops the line id, so training rows stay with the main line',
    () {
      final read = imported('''
[Event "x"]
[LineID "line_abc"]
[Result "*"]

1. e4 e5 (1... c5) *
''');
      final chapter = chapterOf(read.chapters.single);
      expect(chapter.lines[0].lineId, 'line_abc');
      expect(chapter.lines[1].lineId, isNull);
    },
  );

  test('comments, glyphs and machine tokens ride along into the lines', () {
    final read = imported('''
[Event "x"]
[Result "*"]

{Intro} 1. e4 {[%eval 0.3] the move} e5 \$1 ({A note} 1... c5 {Sicilian [%clk 0:01:00]}) 2. Nf3 *
''');
    final chapter = chapterOf(read.chapters.single);
    expect(
      chapter.lines[0].text,
      contains('{Intro} 1. e4 {[%eval 0.3] the move} e5 \$1 2. Nf3 *'),
    );
    // The comment that introduced the variation lands on the move before it.
    expect(
      chapter.lines[1].text,
      contains(
        '{Intro} 1. e4 {[%eval 0.3] the move A note} c5 {Sicilian [%clk 0:01:00]} *',
      ),
    );
  });

  test('a game with no variations is kept byte for byte', () {
    const game = '[Event "x"]\n[Result "*"]\n\n1. e4   e5 2. Nf3 *';
    final read = imported('$game\n');
    expect(read.chapters.single.text, endsWith('\n\n$game\n'));
  });

  test('a finished game is annotation, not repertoire, and is kept whole', () {
    final read = imported('''
[Event "x"]
[Result "1-0"]

1. e4 e5 (1... c5) 2. Nf3 1-0
''');
    expect(read.lines, 1);
    expect(read.chapters.single.text, contains('(1... c5)'));
  });

  test('a Lichess study export is one chapter per ChapterName', () {
    final read = imported(fixture('lichess_study.pgn'));
    expect(read.chapters.map((c) => c.title), ['6.Bg5 e6', '6.Bg5 Nbd7']);
    expect(read.chapters[0].lines, 2, reason: 'the poisoned pawn is a line');
    expect(read.chapters[1].lines, 1);
    expect(read.chapters[0].text, startsWith('// 6.Bg5 e6\n'));
    expect(read.chapters[0].text, contains('// Chapter: 6.Bg5 e6\n'));
    expect(
      read.chapters[0].text,
      contains('// Created on 2026-09-22 12:00:00\n\n[Event'),
    );
  });

  test('a Chessable course is one chapter per title in the player header', () {
    final read = imported('''
[Event "?"]
[White "1) Introduction"]
[Black "Overview"]
[Result "*"]

1. d4 *

[Event "?"]
[White "2) 3...c6"]
[Black "Main line"]
[Result "*"]

1. d4 d5 2. Nf3 Nf6 3. e3 c6 *

[Event "?"]
[White "2) 3...c6"]
[Black "Early ...Bf5"]
[Result "*"]

1. d4 d5 2. Nf3 Nf6 3. e3 c6 4. Bd3 Bf5 (4... Bg4 5. c4) *

[Event "?"]
[White "Model games"]
[Black "Colle - Someone"]
[Result "*"]

1. d4 d5 2. Nf3 Nf6 3. e3 e6 (3... c5) 4. Bd3 *
''');
    expect(read.chapters.map((c) => c.title), [
      '1) Introduction',
      '2) 3...c6',
      'Model games',
    ]);
    expect(read.chapters[1].lines, 3);
    expect(read.chapters[2].lines, 1, reason: 'model games stay whole');
    final sideline = chapterOf(read.chapters[1]).lines[2];
    expect(
      sideline.text,
      contains('[White "2) 3...c6"]'),
      reason: 'never the chapter',
    );
    expect(sideline.text, contains('[Black "Early ...Bf5 — 4...Bg4"]'));
  });

  test(
    'a line listed under every chapter title is written once per chapter',
    () {
      final read = imported('''
[Event "?"]
[White "A"]
[Black "Line"]
[Result "*"]

1. e4 *

[Event "?"]
[White "A"]
[Black "Line"]
[Result "*"]

1. e4 *

[Event "?"]
[White "B"]
[Black "Line"]
[Result "*"]

1. d4 *

[Event "?"]
[White "B"]
[Black "Other"]
[Result "*"]

1. c4 *
''');
      expect(read.chapters[0].lines, 1);
      expect(read.chapters[1].lines, 2);
    },
  );

  test('a file the app wrote keeps the side it states', () {
    final read = imported('// Color: Black\n\n[Event "x"]\n\n1. e4 c5 *\n');
    expect(read.side, Side.black);
    expect(read.chapters.single.text, contains('// Color: Black\n'));
  });

  test(
    'the side is read off the shape of the tree when the file does not say',
    () {
      // Nine White lines: Black branches at every turn, White never does.
      final buffer = StringBuffer();
      for (final reply in [
        'e5',
        'c5',
        'e6',
        'c6',
        'd5',
        'd6',
        'Nf6',
        'g6',
        'b6',
      ]) {
        buffer.write('[Event "x"]\n[Result "*"]\n\n1. e4 $reply 2. Nf3 *\n\n');
      }
      expect(imported(buffer.toString()).side, Side.white);
      // Turned around, it is a Black repertoire.
      final black = StringBuffer();
      for (final first in [
        'e4',
        'd4',
        'c4',
        'Nf3',
        'g3',
        'b3',
        'f4',
        'Nc3',
        'e3',
      ]) {
        black.write('[Event "x"]\n[Result "*"]\n\n1. $first c5 *\n\n');
      }
      expect(imported(black.toString()).side, Side.black);
    },
  );

  test('a handful of lines is not enough to guess a side from', () {
    final read = imported(
      '[Event "x"]\n\n1. e4 e5 *\n\n[Event "y"]\n\n1. d4 d5 *\n',
    );
    expect(read.side, isNull);
    expect(read.chapters.single.text, isNot(contains('// Color:')));
  });

  test('text with no moves in it is nothing to import', () {
    expect(readImport('', created: created), isA<NothingToImport>());
    expect(readImport('hello', created: created), isA<NothingToImport>());
    expect(
      readImport('[Event "x"]\n[Result "*"]\n\n*\n', created: created),
      isA<NothingToImport>(),
    );
  });

  test('a game nothing can read is kept as its bytes beside the lines', () {
    final read = imported('''
[Event "x"]
[FEN "not a position"]

1. e4 *

[Event "y"]

1. d4 d5 *
''');
    final chapter = chapterOf(read.chapters.single);
    expect(chapter.lines, hasLength(2));
    expect(chapter.unreadableGames, 1);
    expect(chapter.lines[0].text, contains('[FEN "not a position"]'));
  });

  test('every written chapter reads back as itself', () {
    for (final name in [
      'chessable_course.pgn',
      'lichess_study.pgn',
      'dialects.pgn',
    ]) {
      final read = readImport(fixture(name), created: created);
      if (read is! ImportedChapters) continue;
      for (final chapter in read.chapters) {
        final parsed = chapterOf(chapter);
        expect(
          writeChapter(parsed),
          chapter.text,
          reason: '$name: ${chapter.title}',
        );
        expect(
          parsed.lines.length,
          chapter.lines,
          reason: '$name: ${chapter.title}',
        );
      }
    }
  });

  test('a course is one file: each line names its chapter and its id', () {
    for (final name in ['chessable_course.pgn', 'lichess_study.pgn']) {
      final read = imported(fixture(name));
      final text = courseText(read, created: created);
      final file = parseChapter(name: 'Course', text: text);
      expect(file.lines, hasLength(read.lines), reason: name);
      expect(
        chapterSections(file.lines),
        read.chapters.length == 1
            ? [null]
            : [for (final c in read.chapters) c.title.trim()],
        reason: name,
      );
      expect(sectionsInText(text), chapterSections(file.lines), reason: name);
      if (read.chapters.length > 1) {
        expect(file.lines.every((l) => l.lineId != null), isTrue);
        expect(file.side, read.side ?? Side.white);
      }
      // Each chapter of the file holds the lines its own file would have.
      for (final chapter in read.chapters) {
        final view = sectionView(
          file,
          read.chapters.length == 1 ? null : chapter.title.trim(),
        );
        expect(view.chapter.lines, hasLength(chapter.lines), reason: name);
      }
    }
  });

  // inferredRepertoireSide
  test('the side that branches is the opponent', () {
    final whiteBook = [
      for (final reply in ['e5', 'c5', 'e6', 'c6', 'd5', 'd6', 'Nf6', 'g6'])
        line('1. e4 $reply 2. Nf3'),
    ];
    expect(inferredRepertoireSide(whiteBook), Side.white);
    final blackBook = [
      for (final first in ['e4', 'd4', 'c4', 'Nf3', 'g3', 'b3', 'f4', 'Nc3'])
        line('1. $first c5'),
    ];
    expect(inferredRepertoireSide(blackBook), Side.black);
  });

  test('too few lines to branch are read by the move they end on', () {
    final endsOnWhite = [
      for (final reply in ['e5', 'c5', 'e6', 'c6']) line('1. e4 $reply 2. Nf3'),
    ];
    expect(inferredRepertoireSide(endsOnWhite), Side.white);
  });

  test('a handful of lines, or a thin margin, says nothing', () {
    expect(
      inferredRepertoireSide([line('1. e4 e5'), line('1. d4 d5')]),
      isNull,
    );
    final mixed = [
      line('1. e4 e5'),
      line('1. e4 c5 2. Nf3'),
      line('1. d4 d5'),
      line('1. d4 Nf6 2. c4'),
    ];
    expect(inferredRepertoireSide(mixed), isNull);
  });
}
