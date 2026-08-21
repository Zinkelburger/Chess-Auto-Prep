import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/repertoire_service.dart';

void main() {
  group('parseRepertoirePgn', () {
    test('parseRepertoirePgn uses FEN headers for line start positions', () {
      const startingFen =
          'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
      final pgn = [
        '[Event "Custom Root"]',
        '[White "Repertoire"]',
        '[Black "Opponent"]',
        '[FEN "$startingFen"]',
        '[SetUp "1"]',
        '',
        '2. Nf3 *',
      ].join('\n');

      final lines = RepertoireService().parseRepertoirePgn(pgn);

      expect(lines, hasLength(1));
      expect(lines.single.startPosition.fen, startingFen);
      expect(lines.single.moves, ['Nf3']);
    });

    test('colorFromStartingSide derives each line colour from its own start '
        'position (study puzzles)', () {
      // Black to move in the first chapter, standard start in the second.
      const blackToMoveFen =
          'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 2';
      final pgn = [
        '[Event "Black puzzle"]',
        '[FEN "$blackToMoveFen"]',
        '[SetUp "1"]',
        '',
        '2... Nc6 *',
        '',
        '[Event "White puzzle"]',
        '',
        '1. e4 *',
      ].join('\n');

      final lines = RepertoireService().parseRepertoirePgn(
        pgn,
        colorFromStartingSide: true,
      );

      expect(lines, hasLength(2));
      expect(lines[0].color, 'black');
      expect(lines[0].moves, ['Nc6']);
      expect(lines[1].color, 'white');
      expect(lines[1].moves, ['e4']);
    });

    test('a [%tstart] puzzle marker sets the solver colour and start index '
        'in per-chapter colour mode', () {
      // Full game from the standard start: without a marker this chapter
      // would train as White (White moves first). The marker on Black's
      // second move says the puzzle is Black's from there.
      final pgn = [
        '[Event "Line with marker"]',
        '',
        '1. e4 e5 2. Nf3 Nc6 {Solve from here. [%tstart]} 3. Bb5 '
            'a6 {[%tend]} *',
      ].join('\n');

      final lines = RepertoireService().parseRepertoirePgn(
        pgn,
        colorFromStartingSide: true,
      );

      expect(lines, hasLength(1));
      expect(lines.single.color, 'black');
      expect(lines.single.puzzleStartIndex, 3);
      expect(lines.single.puzzleEndIndex, 5);
    });

    test('parseRepertoirePgn handles multi-game file correctly', () {
      const pgn = '''
// Color: White

[Event "Sicilian"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. e4 c5

[Event "French"]
[Date "2026-01-02"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. e4 e6
''';

      final lines = RepertoireService().parseRepertoirePgn(pgn);

      expect(lines, hasLength(2));
      expect(lines[0].moves, ['e4', 'c5']);
      expect(lines[0].name, 'Sicilian');
      expect(lines[1].moves, ['e4', 'e6']);
      expect(lines[1].name, 'French');
      expect(lines.every((line) => line.color == 'white'), isTrue);
    });

    test('parseRepertoirePgn extracts side from header', () {
      const whitePgn = '''
// Color: White

[Event "Line"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. d4 d5
''';

      const blackPgn = '''
// Color: Black

[Event "Line"]
[Date "2026-01-01"]
[White "Opponent"]
[Black "Me"]
[Result "0-1"]

1. e4 e5
''';

      final service = RepertoireService();
      expect(service.parseRepertoirePgn(whitePgn).single.color, 'white');
      expect(service.parseRepertoirePgn(blackPgn).single.color, 'black');
    });

    test('Chessable-style exports yield chapters from White headers and '
        'variation names from Black headers', () {
      // Chessable puts the chapter in [White], the variation title in
      // [Black], and Result "*" on every game.
      const pgn = '''
[Event "?"]
[White "1) Benoni With 6.e4"]
[Black "6.e4 & 7.f4 #1"]
[Result "*"]

1. d4 Nf6 2. c4 c5 *

[Event "?"]
[White "1) Benoni With 6.e4"]
[Black "6.e4 & 7.f4 #2"]
[Result "*"]

1. d4 Nf6 2. c4 e6 *

[Event "?"]
[White "2) Fianchetto System"]
[Black "10.a4 #1"]
[Result "*"]

1. d4 d5 2. c4 e6 *
''';

      final lines = RepertoireService().parseRepertoirePgn(
        pgn,
        trainingColor: 'black',
      );

      expect(lines, hasLength(3));
      expect(lines[0].chapter, '1) Benoni With 6.e4');
      expect(lines[1].chapter, '1) Benoni With 6.e4');
      expect(lines[2].chapter, '2) Fianchetto System');
      expect(lines[0].name, '6.e4 & 7.f4 #1');
      expect(lines[1].name, '6.e4 & 7.f4 #2');
      expect(lines[2].name, '10.a4 #1');
    });

    test('a model game is marked as one, its neighbours are not', () {
      // The generator's trailing "Model games" chapter: a real game, so it
      // has to carry Result "*" and a chapter title like any other game, and
      // says what it really is in the ModelGame* tags.
      const pgn = '''
[Event "My repertoire"]
[White "1. Open Sicilian"]
[Black "2... d6"]
[Result "*"]

1. e4 c5 2. Nf3 d6 *

[Event "My repertoire"]
[White "2. Model games"]
[Black "Kasparov, G – Karpov, A, Linares 1993 (1-0)"]
[Result "*"]
[ModelGameWhite "Kasparov, G"]
[ModelGameBlack "Karpov, A"]
[ModelGameResult "1-0"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 *
''';

      final lines = RepertoireService().parseRepertoirePgn(pgn);

      expect(lines.map((l) => l.isModelGame), [false, true]);
      expect(
        lines[1].chapter,
        '2. Model games',
        reason: 'it still groups in the sidebar like any other chapter',
      );
    });

    test('game collections and own exports get no chapters', () {
      // Real games: player names in White but decisive results.
      const gamesPgn = '''
[Event "London"]
[White "Kennedy, Hugh"]
[Black "Wyvill, Marmaduke"]
[Result "0-1"]

1. e4 c5 0-1

[Event "London"]
[White "Kennedy, Hugh"]
[Black "Anderssen, Adolf"]
[Result "1-0"]

1. e4 e5 1-0
''';
      // Own exports: White is the placeholder "Me".
      const ownPgn = '''
[Event "Repertoire Line"]
[White "Me"]
[Black "Opponent"]
[Result "*"]

1. e4 c5 *

[Event "Repertoire Line"]
[White "Me"]
[Black "Opponent"]
[Result "*"]

1. e4 e6 *
''';

      final service = RepertoireService();
      expect(
        service.parseRepertoirePgn(gamesPgn).map((l) => l.chapter),
        everyElement(isNull),
      );
      expect(
        service.parseRepertoirePgn(ownPgn).map((l) => l.chapter),
        everyElement(isNull),
      );
    });
  });

  group('appendMoveAtPath', () {
    late Directory tempDir;
    late RepertoireService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('repertoire_svc_test');
      service = RepertoireService();
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('appendMoveAtPath to empty repertoire creates first game', () async {
      final filePath = '${tempDir.path}/empty.pgn';
      await File(filePath).writeAsString('');

      final result = await service.appendMoveAtPath(
        filePath,
        [],
        'e4',
        isWhiteRepertoire: true,
      );

      expect(result.success, isTrue);
      expect(result.updatedContent, contains('[Event "Repertoire Line"]'));
      expect(result.updatedContent, contains('1. e4'));

      final disk = await File(filePath).readAsString();
      expect(disk, result.updatedContent);
      expect(service.parseRepertoirePgn(disk).single.moves, ['e4']);
    });

    test(
      'appendMoveAtPath extends existing game when prefix matches',
      () async {
        final filePath = '${tempDir.path}/existing.pgn';
        await File(filePath).writeAsString('''
// Color: White

[Event "Line 1"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. e4 e5
''');

        final result = await service.appendMoveAtPath(
          filePath,
          ['e4', 'e5'],
          'Nf3',
          isWhiteRepertoire: true,
        );

        expect(result.success, isTrue);
        expect(result.updatedContent, contains('Nf3'));
        expect(service.parseRepertoirePgn(result.updatedContent), hasLength(1));
        expect(service.parseRepertoirePgn(result.updatedContent).single.moves, [
          'e4',
          'e5',
          'Nf3',
        ]);
      },
    );

    test(
      'appendMoveAtPath creates sibling game when no prefix matches',
      () async {
        final filePath = '${tempDir.path}/sibling.pgn';
        await File(filePath).writeAsString('''
// Color: White

[Event "Line 1"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. e4 e5
''');

        final result = await service.appendMoveAtPath(
          filePath,
          ['e4', 'c5'],
          'Nf3',
          isWhiteRepertoire: true,
        );

        expect(result.success, isTrue);
        final lines = service.parseRepertoirePgn(result.updatedContent);
        expect(lines, hasLength(2));
        expect(lines[0].moves, ['e4', 'e5']);
        expect(lines[1].moves, ['e4', 'c5', 'Nf3']);
      },
    );
  });

  group('updateLineContent', () {
    late Directory tempDir;
    late RepertoireService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('repertoire_svc_test');
      service = RepertoireService();
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('preserves headers the editor does not serialize', () async {
      final filePath = '${tempDir.path}/line.pgn';
      await File(filePath).writeAsString('''
[Event "Old Title"]
[White "Me"]
[Black "Training"]
[Result "*"]
[LineID "line_abc123"]
[LastReview "2026-07-01T00:00:00.000Z"]

1. e4 e5 2. Nf3 *
''');

      // The editor writes only the standard headers, like MoveTree.toPgn.
      final ok = await service.updateLineContent(
        filePath,
        'line_abc123',
        '[Event "New Title"]\n[Date "2026.07.09"]\n[White "Me"]\n'
            '[Black "Training"]\n[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6',
      );
      expect(ok, isTrue);

      final disk = await File(filePath).readAsString();
      expect(disk, contains('[Event "New Title"]'));
      expect(disk, contains('[LineID "line_abc123"]'));
      expect(disk, contains('[LastReview "2026-07-01T00:00:00.000Z"]'));
      expect(disk, isNot(contains('Old Title')));

      // The line must still be findable by its id afterwards.
      final renamed = await service.updateLineTitle(
        filePath,
        'line_abc123',
        'Renamed',
      );
      expect(renamed, isTrue);
      expect(
        await File(filePath).readAsString(),
        contains('[Event "Renamed"]'),
      );
    });
  });
}
