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

    test('parseRepertoirePgn handles multi-game file correctly', () {
      final pgn = '''
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
      final whitePgn = '''
// Color: White

[Event "Line"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. d4 d5
''';

      final blackPgn = '''
// Color: Black

[Event "Line"]
[Date "2026-01-01"]
[White "Opponent"]
[Black "Me"]
[Result "0-1"]

1. e4 e5
''';

      final service = RepertoireService();
      expect(
        service.parseRepertoirePgn(whitePgn).single.color,
        'white',
      );
      expect(
        service.parseRepertoirePgn(blackPgn).single.color,
        'black',
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

    test('appendMoveAtPath extends existing game when prefix matches',
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
      expect(
        service.parseRepertoirePgn(result.updatedContent),
        hasLength(1),
      );
      expect(
        service.parseRepertoirePgn(result.updatedContent).single.moves,
        ['e4', 'e5', 'Nf3'],
      );
    });

    test('appendMoveAtPath creates sibling game when no prefix matches',
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
    });
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
      final renamed =
          await service.updateLineTitle(filePath, 'line_abc123', 'Renamed');
      expect(renamed, isTrue);
      expect(await File(filePath).readAsString(), contains('[Event "Renamed"]'));
    });
  });
}
