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

    test('an export with the chapter in Black and the title in White reads '
        'the same way round', () {
      // Vigorito's Gold Standard export: one variation title per game in
      // [White], the chapter it belongs to in [Black].
      const pgn = '''
[Event "?"]
[White "Caro-Kann 4...Bf5 #1"]
[Black "31) Caro-Kann"]
[Result "*"]

1. e4 c6 2. d4 d5 3. Nc3 *

[Event "?"]
[White "Caro-Kann 4...Bf5 #2"]
[Black "31) Caro-Kann"]
[Result "*"]

1. e4 c6 2. d4 d5 3. Nc3 dxe4 *

[Event "?"]
[White "French 3...Be7 #1"]
[Black "30) French"]
[Result "*"]

1. e4 e6 2. d4 d5 3. Nc3 *
''';

      final lines = RepertoireService().parseRepertoirePgn(pgn);
      expect(lines.map((l) => l.chapter), [
        '31) Caro-Kann',
        '31) Caro-Kann',
        '30) French',
      ]);
      expect(lines.map((l) => l.name), [
        'Caro-Kann 4...Bf5 #1',
        'Caro-Kann 4...Bf5 #2',
        'French 3...Be7 #1',
      ]);
      expect(lines[0].qualifiedName, '31) Caro-Kann › Caro-Kann 4...Bf5 #1');
    });

    test('an export with the chapter in Event titles lines from both '
        'player headers', () {
      // Jones' KID part 2: [Event] is the chapter, [White] the variation,
      // [Black] a sub-variation or "?".
      const pgn = '''
[Event "12. Fianchetto Mainline"]
[White "Fianchetto, Mainline: 9.Nd2 e6"]
[Black "10.Rb1 #1"]
[Result "*"]

1. d4 Nf6 2. c4 g6 3. g3 *

[Event "12. Fianchetto Mainline"]
[White "Fianchetto, Mainline: 9.Nd2 e6"]
[Black "10.Rb1 #2"]
[Result "*"]

1. d4 Nf6 2. c4 g6 3. g3 Bg7 *

[Event "12. Fianchetto Mainline"]
[White "Fianchetto, Mainline: 9.Qd3 a6"]
[Black "?"]
[Result "*"]

1. d4 Nf6 2. c4 g6 3. g3 Bg7 4. Bg2 *

[Event "33. Veresov"]
[White "2.Nc3 d5 3.Bg5 g6 #5"]
[Black "?"]
[Result "*"]

1. d4 Nf6 2. Nc3 d5 *
''';
      final lines = RepertoireService().parseRepertoirePgn(pgn);
      expect(lines.map((l) => l.chapter), [
        '12. Fianchetto Mainline',
        '12. Fianchetto Mainline',
        '12. Fianchetto Mainline',
        '33. Veresov',
      ]);
      expect(lines.map((l) => l.name), [
        'Fianchetto, Mainline: 9.Nd2 e6 — 10.Rb1 #1',
        'Fianchetto, Mainline: 9.Nd2 e6 — 10.Rb1 #2',
        'Fianchetto, Mainline: 9.Qd3 a6',
        '2.Nc3 d5 3.Bg5 g6 #5',
      ]);
    });

    test('a file marked as one course chapter names lines by their '
        'pinned Event and never re-detects chapters', () {
      // What ChapterSplitter writes: every line of one chapter, titles in
      // [Event], the old title headers still there and repeating.
      const pgn = '''
// 31) Caro-Kann
// Color: White
// Chapter: 31) Caro-Kann 4...Bf5

[Event "Main Line #1"]
[White "Caro-Kann 4...Bf5 with 7...Nf6"]
[Black "31) Caro-Kann 4...Bf5"]
[Result "*"]

1. e4 c6 2. d4 d5 3. Nc3 *

[Event "Main Line #2"]
[White "Caro-Kann 4...Bf5 with 7...Nf6"]
[Black "31) Caro-Kann 4...Bf5"]
[Result "*"]

1. e4 c6 2. d4 d5 3. Nc3 dxe4 *

[Event "Model Games"]
[White "Model Games"]
[Black "Nikcevic vs Jones"]
[Result "*"]

1. e4 c6 2. d4 d5 3. Nc3 dxe4 4. Nxe4 *
''';
      final lines = RepertoireService().parseRepertoirePgn(pgn);
      expect(lines.map((l) => l.chapter).toSet(), {'31) Caro-Kann 4...Bf5'});
      expect(lines.map((l) => l.name), [
        'Main Line #1',
        'Main Line #2',
        'Model Games',
      ]);
      expect(lines[0].qualifiedName, '31) Caro-Kann 4...Bf5 › Main Line #1');
      expect(lines.map((l) => l.isModelGame), [
        false,
        false,
        false,
      ], reason: 'the chapter title, not the line title, says model games');
    });

    test('a course\'s "Model Games" chapter is model games', () {
      // Course exports give illustration games Result "*" like every line;
      // the chapter title is what says they are not repertoire.
      const pgn = '''
[Event "?"]
[White "1) Classical"]
[Black "8.Be3 #1"]
[Result "*"]

1. d4 Nf6 2. c4 g6 *

[Event "?"]
[White "1) Classical"]
[Black "8.Be3 #2"]
[Result "*"]

1. d4 Nf6 2. c4 g6 3. Nc3 *

[Event "?"]
[White "Model Games"]
[Black "Nikcevic, N vs. Jones, G, 2013"]
[Result "*"]

1. d4 Nf6 2. c4 g6 3. Nc3 Bg7 4. e4 d6 5. Nf3 O-O *
''';
      final lines = RepertoireService().parseRepertoirePgn(pgn);
      expect(lines.map((l) => l.isModelGame), [false, false, true]);
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

  /// `[EventDate]` starts with `[Event`, so a game-splitter that cuts on the
  /// bare prefix finds two games in every Chessable export and every
  /// index-addressed edit lands on the wrong one.
  group('courseChaptersOf', () {
    String game(String white, String moves, {Map<String, String>? extra}) => [
      '[Event "Course"]',
      '[White "$white"]',
      '[Black "Variation"]',
      '[Result "*"]',
      for (final e in (extra ?? const {}).entries) '[${e.key} "${e.value}"]',
      '',
      '$moves *',
      '',
    ].join('\n');

    test('lists a course export\'s chapters in file order with counts', () {
      final content = [
        game('Exchange', '1. d4 d5 2. c4 e6 3. cxd5'),
        game('Exchange', '1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. cxd5'),
        game('Catalan', '1. d4 d5 2. c4 e6 3. g3'),
        game('Exchange', '1. d4 d5 2. c4 e6 3. Nf3 Nf6 4. cxd5'),
      ].join('\n');
      final chapters = RepertoireService().courseChaptersOf(content);
      expect(chapters.map((c) => c.name), ['Exchange', 'Catalan']);
      expect(chapters.map((c) => c.lineCount), [3, 1]);
    });

    test('model games are listed under their chapter but not counted', () {
      final content = [
        game('Exchange', '1. d4 d5 2. c4 e6 3. cxd5'),
        game(
          'Exchange',
          '1. d4 d5 2. c4 e6 3. Nc3',
          extra: {'ModelGameWhite': 'Carlsen', 'ModelGameResult': '1-0'},
        ),
        game('Catalan', '1. d4 d5 2. c4 e6 3. g3'),
        game('Catalan', '1. d4 d5 2. c4 e6 3. g3 Nf6'),
      ].join('\n');
      final chapters = RepertoireService().courseChaptersOf(content);
      expect(chapters.map((c) => c.name), ['Exchange', 'Catalan']);
      expect(chapters.map((c) => c.lineCount), [1, 2]);
    });

    test('a hand-made chapter has no course chapters', () {
      final content = [
        '// Color: White',
        '',
        '[Event "Repertoire Line"]',
        '[White "Me"]',
        '[Black "Opponent"]',
        '[Result "*"]',
        '',
        '1. d4 d5 2. c4 *',
        '',
        '[Event "Repertoire Line"]',
        '[White "Me"]',
        '[Black "Opponent"]',
        '[Result "*"]',
        '',
        '1. d4 Nf6 2. c4 *',
      ].join('\n');
      expect(RepertoireService().courseChaptersOf(content), isEmpty);
      expect(RepertoireService().courseChaptersOf(''), isEmpty);
    });
  });

  group('game indices in a file with [EventDate] headers', () {
    late Directory tempDir;
    late String path;

    String game(String event, String moves) =>
        '[Event "$event"]\n'
        '[White "Chapter"]\n'
        '[Result "*"]\n'
        '[EventDate "2024.??.??"]\n\n'
        '$moves *\n';

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('repertoire_svc_test');
      path = '${tempDir.path}/Main.pgn';
      await File(path).writeAsString(
        '${game('First', '1. d4 d5')}\n'
        '${game('Second', '1. e4 e5')}\n'
        '${game('Third', '1. c4 e6')}\n',
      );
    });

    tearDown(() async => tempDir.delete(recursive: true));

    test('readGameTextAt returns whole games, not header fragments', () async {
      final service = RepertoireService();
      final second = await service.readGameTextAt(path, 1);
      expect(second, contains('[Event "Second"]'));
      expect(second, contains('1. e4 e5'));
      expect(await service.readGameTextAt(path, 3), isNull);
    });

    test('deleteGameAt removes the game the index names', () async {
      final service = RepertoireService();
      expect(await service.deleteGameAt(path, 1), isTrue);
      final left = service.parseRepertoirePgn(await File(path).readAsString());
      expect(left.map((l) => l.moves.first), ['d4', 'c4']);
    });
  });
}
