import 'package:chess_auto_prep/features/repertoires/models/repertoire_mutation_receipt.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/document_repertoire_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import '../../support/repertoire_dependencies.dart';
import 'package:chess_auto_prep/chess_core/pgn/repertoire_document_mutation.dart';
import 'dart:io';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/builder_workspace_controller.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_writer.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';

void main() {
  group('RepertoireWriter undo', () {
    late Directory tempDir;
    late String filePath;
    late BuilderWorkspaceController controller;
    late RepertoireWriter writer;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('repertoire_undo_test');
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

    test('undo reverses addMoveAtPosition on disk and in memory', () async {
      controller.board.loadMoveHistory(['e4', 'e5']);
      final before = await File(filePath).readAsString();

      await writer.addMoveAtPosition(
        fen: controller.board.fen,
        san: 'Nf3',
        pathFromRoot: ['e4', 'e5'],
      );
      controller.board.playMove('Nf3');

      expect(writer.canUndo, isTrue);
      expect(await File(filePath).readAsString(), contains('Nf3'));
      expect(controller.document.repertoireLines.first.moves, [
        'e4',
        'e5',
        'Nf3',
      ]);

      final undone = await writer.undo();
      expect(undone, isTrue);
      expect(writer.canUndo, isFalse);
      expect(await File(filePath).readAsString(), before);
      expect(controller.document.repertoireLines.first.moves, ['e4', 'e5']);
      expect(controller.board.currentMoveSequence, ['e4', 'e5']);
      expect(
        controller.document.openingGraph!.hasMove(controller.board.fen, 'Nf3'),
        isFalse,
      );
    });

    test('undo returns false when stack is empty', () async {
      expect(writer.canUndo, isFalse);
      expect(await writer.undo(), isFalse);
    });

    test(
      'draft undo cannot restore into a newly adopted equal-looking board',
      () async {
        final persisted = await File(filePath).readAsString();
        controller.board.loadMoveHistory(['e4', 'e5']);
        controller.deleteDraftBranch(const TreePath([0, 0]));
        controller.board.loadMoveHistory(['e4']);
        final adopted = controller.board.tree;
        await expectLater(writer.undo(), throwsStateError);
        expect(controller.board.tree, same(adopted));
        expect(controller.board.moveHistory, ['e4']);
        expect(await File(filePath).readAsString(), persisted);
      },
    );

    test('duplicate add does not push undo entry', () async {
      controller.board.loadMoveHistory(['e4']);

      await writer.addMoveAtPosition(
        fen: controller.board.fen,
        san: 'e5',
        pathFromRoot: ['e4'],
      );

      expect(writer.canUndo, isFalse);
    });

    test('undo stack keeps only last 20 operations', () async {
      controller.board.loadMoveHistory(['e4', 'e5']);

      const movesToAdd = [
        'Nf3',
        'Nc6',
        'Bb5',
        'a6',
        'Ba4',
        'Nf6',
        'O-O',
        'Be7',
        'Re1',
        'b5',
        'Bb3',
        'd6',
        'c3',
        'O-O',
        'h3',
        'Nb8',
        'd4',
        'Nbd7',
        'Nbd2',
        'Bc8',
        'Bc2',
      ];

      for (final san in movesToAdd) {
        await writer.addMoveAtPosition(
          fen: controller.board.fen,
          san: san,
          pathFromRoot: controller.board.currentMoveSequence,
        );
        controller.board.playMove(san);
      }

      for (var i = 0; i < 20; i++) {
        expect(await writer.undo(), isTrue, reason: 'undo #$i');
      }
      expect(writer.canUndo, isFalse);
      expect(await writer.undo(), isFalse);
    });

    test('multi-move append undo removes moves one at a time', () async {
      controller.board.loadMoveHistory(['e4', 'e5']);

      await writer.addMovesAtPosition(
        pathFromRoot: ['e4', 'e5'],
        sans: ['Nf3', 'Nc6'],
      );
      expect(controller.document.repertoireLines.first.moves, [
        'e4',
        'e5',
        'Nf3',
        'Nc6',
      ]);
      expect(writer.canUndo, isTrue);

      expect(await writer.undo(), isTrue);
      expect(controller.document.repertoireLines.first.moves, [
        'e4',
        'e5',
        'Nf3',
      ]);
      expect(controller.board.currentMoveSequence, ['e4', 'e5', 'Nf3']);

      expect(await writer.undo(), isTrue);
      expect(controller.document.repertoireLines.first.moves, ['e4', 'e5']);
      expect(controller.board.currentMoveSequence, ['e4', 'e5']);
      expect(writer.canUndo, isFalse);
    });

    test('clearUndoStack on loadRepertoire', () async {
      controller.board.loadMoveHistory(['e4', 'e5']);
      await writer.addMoveAtPosition(
        fen: controller.board.fen,
        san: 'Nf3',
        pathFromRoot: ['e4', 'e5'],
      );
      expect(writer.canUndo, isTrue);

      await controller.document.loadRepertoire();
      expect(writer.canUndo, isFalse);
    });

    test(
      'a file-backed malformed receipt never invents undo from memory',
      () async {
        controller.board.loadMoveHistory(['e4', 'e5']);
        final noSnapshots = RepertoireWriter(
          document: controller.document,
          board: controller.board,
          documents: _NoSnapshotRepository(
            LegacyPgnDocumentStore(StorageFactory.instance),
          ),
        );
        await expectLater(
          noSnapshots.addMovesAtPosition(
            pathFromRoot: ['e4', 'e5'],
            sans: ['Nf3', 'Nc6', 'Bb5'],
          ),
          throwsStateError,
        );
        expect(noSnapshots.canUndo, isFalse);
        // The deliberately broken adapter committed already. Keep its result
        // on disk for recovery, without claiming the stale session can undo it.
        expect(await File(filePath).readAsString(), contains('Bb5'));
        expect(controller.document.repertoireLines.first.moves, ['e4', 'e5']);
      },
    );
  });
}

/// A broken adapter commits but drops the logical per-ply receipt.
class _NoSnapshotRepository extends DocumentRepertoireRepository {
  _NoSnapshotRepository(super.documents);

  @override
  Future<RepertoireMutationReceipt> append(
    String filePath,
    List<String> pathFromRoot,
    List<String> newSans, {
    String? startingFen,
    bool isWhiteRepertoire = true,
  }) async {
    final real = await super.append(
      filePath,
      pathFromRoot,
      newSans,
      startingFen: startingFen,
      isWhiteRepertoire: isWhiteRepertoire,
    );
    return RepertoireMutationReceipt(
      requestedDocumentPath: real.requestedDocumentPath,
      before: real.before,
      after: real.after,
      mutation: RepertoireAppendPlan(
        previousContent: real.before.content,
        updatedContent: real.after.content,
        steps: const [],
      ),
    );
  }
}
