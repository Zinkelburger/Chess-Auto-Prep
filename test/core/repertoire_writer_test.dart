import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/core/repertoire_writer.dart';
import 'package:chess_auto_prep/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';

void main() {
  group('RepertoireWriter', () {
    late Directory tempDir;
    late String filePath;
    late RepertoireController controller;
    late RepertoireWriter writer;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('repertoire_writer_test');
      filePath = '${tempDir.path}/test.pgn';
      await File(filePath).writeAsString('''
// Color: White

[Event "Line 1"]
[Date "2026-01-01"]
[White "Me"]
[Black "Opponent"]
[Result "1-0"]

1. e4 e5
''');

      controller = RepertoireController();
      await controller.setRepertoire(
        RepertoireMetadata(
          name: 'Test',
          filePath: filePath,
          lastModified: DateTime(2026, 1, 1),
        ),
      );
      writer = controller.writer;
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'addMoveAtPosition extends matching line on disk and in memory',
      () async {
        controller.loadMoveHistory(['e4', 'e5']);

        final path = await writer.addMoveAtPosition(
          fen: controller.fen,
          san: 'Nf3',
          pathFromRoot: ['e4', 'e5'],
        );

        expect(path, ['e4', 'e5', 'Nf3']);
        expect(controller.openingTree!.hasMove(controller.fen, 'Nf3'), isTrue);
        expect(controller.repertoireLines.first.moves, ['e4', 'e5', 'Nf3']);

        final disk = await File(filePath).readAsString();
        expect(disk, contains('Nf3'));
      },
    );

    test(
      'addMoveAtPosition is no-op when move already in repertoire',
      () async {
        controller.loadMoveHistory(['e4']);

        final before = await File(filePath).readAsString();
        final path = await writer.addMoveAtPosition(
          fen: controller.fen,
          san: 'e5',
          pathFromRoot: ['e4'],
        );

        expect(path, ['e4', 'e5']);
        expect(await File(filePath).readAsString(), before);
      },
    );

    test(
      'appendMoveAtPath creates new game when no exact prefix match',
      () async {
        final service = RepertoireService();
        final result = await service.appendMoveAtPath(
          filePath,
          ['e4', 'c5'],
          'Nf3',
          isWhiteRepertoire: true,
        );

        expect(result.success, isTrue);
        expect(result.updatedContent, contains('[Event "Repertoire Line"]'));
        expect(result.updatedContent, contains('Nf3'));
      },
    );
  });
}
