import 'package:chess_auto_prep/chess/generation/draft_chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_heading.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final created = DateTime(2026, 9, 28, 12, 30);

  test('every draft heading says it is a draft, whose side and where it '
      'starts', () {
    final heading = draftHeading(
      name: 'Main (draft)',
      side: Side.black,
      rootMoves: const ['e4', 'e5'],
      created: created,
    );
    expect(heading, startsWith('// Main (draft)\n// Draft\n// Color: Black\n'));
    final read = readHeading(heading);
    expect(read.draft, isTrue);
    expect(read.rootMoves, ['e4', 'e5']);
  });

  group('a line added as one edit', () {
    Future<Chapter> chapterOf(String moves) => readChapter(
      name: 'Main (draft)',
      text:
          '${draftHeading(name: 'Main (draft)', side: Side.white, rootMoves: const [], created: created)}'
          '${moves.isEmpty ? '' : '[Event "Line"]\n[Result "*"]\n\n$moves *\n'}',
    );

    test('goes into an empty draft whole', () async {
      final empty = await chapterOf('');
      final edit = lineAdded(empty, ['e4', 'f6', 'd4']) as ChapterEdited;
      expect(pathOfSans(edit.chapter.tree, ['e4', 'f6', 'd4']), isNotNull);
      expect(edit.chapter.lines, hasLength(1));
      expect(readHeading(edit.chapter.preamble).draft, isTrue);
    });

    test('follows what the chapter holds and writes only the rest', () async {
      final holding = await chapterOf('1. e4 e5');
      final edit = lineAdded(holding, ['e4', 'f6', 'd4']) as ChapterEdited;
      expect(pathOfSans(edit.chapter.tree, ['e4', 'e5']), isNotNull);
      expect(pathOfSans(edit.chapter.tree, ['e4', 'f6', 'd4']), isNotNull);
      expect(
        lineAdded(edit.chapter, ['e4', 'f6', 'd4']),
        isA<ChapterUnchanged>(),
      );
    });

    test('a move that is not legal changes nothing', () async {
      final empty = await chapterOf('');
      expect(lineAdded(empty, ['e4', 'Ke3']), isA<ChapterEditRefused>());
    });
  });
}
