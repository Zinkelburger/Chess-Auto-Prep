import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_heading.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  test('reads the root moves and the draft mark off the heading', () {
    final heading = readHeading(
      '// King\'s Gambit\n// Color: White\n// Draft\n// Root: 1. e4 e5 2. f4\n\n'
      '[Event "x"]\n\n1. e4 *\n// Root: 1. d4\n',
    );
    expect(heading.rootMoves, ['e4', 'e5', 'f4']);
    expect(heading.draft, isTrue);
    expect(heading.rootText, '1.e4 e5 2.f4');
    expect(
      heading.rootFen,
      const Fen('rnbqkbnr/pppp1ppp/8/4p3/4PP2/8/PPPP2PP/RNBQKBNR b KQkq - 0 2'),
    );
  });

  test('a heading with no root starts at the start and is not a draft', () {
    final heading = readHeading(emptyChapter);
    expect(heading.startsAtTheStart, isTrue);
    expect(heading.draft, isFalse);
    expect(heading.rootFen, Fen.initial);
    expect(heading, ChapterHeading.none);
  });

  test('a root that cannot be played from the start reads as no root', () {
    expect(readHeading('// Root: 1. e5 e4\n').rootMoves, isEmpty);
    expect(readHeading('// Root:\n').rootMoves, isEmpty);
  });

  test('the fixture chapter’s root line reads back as its moves', () {
    expect(readHeading(whiteChapter).rootMoves, ['d4', 'd5', 'c4']);
  });

  test('a new chapter for a position writes the root line the old app '
      'writes, and reads it back', () {
    final text = newChapterText(
      name: 'Gambit',
      side: Side.white,
      created: DateTime(2026, 9, 21, 10, 0, 0),
      rootMoves: const ['e4', 'e5', 'f4'],
    );
    expect(
      text,
      '// Gambit\n// Color: White\n// Root: 1. e4 e5 2. f4\n'
      '// Created on 2026-09-21 10:00:00\n\n',
    );
    expect(readHeading(text).rootMoves, ['e4', 'e5', 'f4']);
    expect(rootLine(const ['e4', 'c5']), '// Root: 1. e4 c5\n');
    expect(rootLine(const []), '');
  });

  test('an empty chapter with a root starts its board there', () {
    final chapter = parseChapter(
      name: 'Gambit',
      text: '// Gambit\n// Color: White\n// Root: 1. e4 e5 2. f4\n\n',
    );
    expect(chapter.tree.isEmpty, isTrue);
    expect(chapter.tree.rootFen, readHeading(chapter.preamble).rootFen);
  });

  test('a chapter with games starts where its games start', () {
    final chapter = parseChapter(name: 'W', text: whiteChapter);
    expect(chapter.tree.rootFen, Fen.initial);
  });
}
