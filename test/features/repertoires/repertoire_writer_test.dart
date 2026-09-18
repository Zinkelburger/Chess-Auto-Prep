import 'package:chess_auto_prep/infrastructure/repertoires/document_repertoire_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import '../../support/repertoire_dependencies.dart';
import 'dart:io';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/builder_workspace_controller.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_writer.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';

void main() {
  group('RepertoireWriter', () {
    late Directory tempDir;
    late String filePath;
    late BuilderWorkspaceController controller;
    late RepertoireWriter writer;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('repertoire_writer_test');
      StorageFactory.instanceForTest = IOStorageService(
        documentsRoot: tempDir,
        supportRoot: tempDir,
        repertoiresRoot: tempDir,
      );
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

      controller = testBuilderWorkspace();
      await controller.document.setRepertoire(
        RepertoireMetadata(
          name: 'Test',
          filePath: filePath,
          lastModified: DateTime(2026, 1, 1),
        ),
      );
      writer = controller.writer;
    });

    tearDown(() async {
      controller.dispose();
      StorageFactory.instanceForTest = null;
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'addMoveAtPosition extends matching line on disk and in memory',
      () async {
        controller.board.loadMoveHistory(['e4', 'e5']);

        final path = await writer.addMoveAtPosition(
          fen: controller.board.fen,
          san: 'Nf3',
          pathFromRoot: ['e4', 'e5'],
        );

        expect(path, ['e4', 'e5', 'Nf3']);
        expect(
          controller.document.openingGraph!.hasMove(
            controller.board.fen,
            'Nf3',
          ),
          isTrue,
        );
        expect(controller.document.repertoireLines.first.moves, [
          'e4',
          'e5',
          'Nf3',
        ]);

        final disk = await File(filePath).readAsString();
        expect(disk, contains('Nf3'));
      },
    );

    test(
      'addMoveAtPosition is no-op when move already in repertoire',
      () async {
        controller.board.loadMoveHistory(['e4']);

        final before = await File(filePath).readAsString();
        final path = await writer.addMoveAtPosition(
          fen: controller.board.fen,
          san: 'e5',
          pathFromRoot: ['e4'],
        );

        expect(path, ['e4', 'e5']);
        expect(await File(filePath).readAsString(), before);
      },
    );

    test(
      'repository append creates new game when no exact prefix match',
      () async {
        final result = await DocumentRepertoireRepository(
          NativePgnDocumentStore(),
        ).append(filePath, ['e4', 'c5'], ['Nf3'], isWhiteRepertoire: true);
        expect(result.after.content, contains('[Event "Repertoire Line"]'));
        expect(result.after.content, contains('Nf3'));
      },
    );
  });
}
