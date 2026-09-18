import 'package:chess_auto_prep/features/repertoires/models/repertoire_mutation_receipt.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/document_repertoire_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import '../../support/repertoire_dependencies.dart';
import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/controllers/builder_workspace_controller.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:chess_auto_prep/utils/atomic_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const original = '// Color: White\n\n[Event "Original"]\n\n1. e4 e5 *\n';

void main() {
  late GatedRepertoireDecoder decoder;
  late Directory directory;
  late File file;
  late BuilderWorkspaceController controller;
  late StorageService storage;
  late _InterleavingStorage gateway;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mutation-safety-');
    file = File(p.join(directory.path, 'chapter.pgn'));
    await file.writeAsString(original);
    storage = IOStorageService(
      documentsRoot: directory,
      supportRoot: Directory(p.join(directory.path, 'support')),
    );
    gateway = _InterleavingStorage(storage, () async {});
    decoder = GatedRepertoireDecoder();
    controller = testBuilderWorkspace(
      decoder: decoder,
      documents: DocumentRepertoireRepository(LegacyPgnDocumentStore(gateway)),
    );
    await controller.document.setRepertoire(
      RepertoireMetadata(
        name: 'Chapter',
        filePath: file.path,
        lastModified: DateTime(2026),
      ),
    );
    controller.board.loadMoveHistory(['e4', 'e5']);
  });

  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> add([List<String> moves = const ['Nf3']]) => controller.writer
      .addMovesAtPosition(pathFromRoot: ['e4', 'e5'], sans: moves);

  for (final action in ['color', 'root', 'import']) {
    test('DATA-01: $action refuses an interleaved replacement', () async {
      const newer = '$original\n{external annotation}\n';
      gateway.delegate = _InterleavingStorage(storage, () async {
        await file.writeAsString(newer);
      });
      final Future<Object?> operation;
      switch (action) {
        case 'color':
          operation = controller.document.setRepertoireColor(false);
        case 'root':
          operation = controller.document.setRootPosition();
        default:
          operation = controller.document.importPgnContent(
            '[Event "Import"]\n\n1. d4 d5 *',
          );
      }
      await expectLater(operation, throwsA(isA<AtomicWriteConflict>()));
      expect(await file.readAsString(), newer);
      expect(controller.document.isRepertoireWhite, isTrue);
      expect(controller.document.rootMoves, isEmpty);
    });
  }

  for (final action in ['color', 'root', 'import']) {
    test(
      'DATA-01: $action reports a deleted destination instead of success',
      () async {
        await file.delete();
        final Future<Object?> operation;
        switch (action) {
          case 'color':
            operation = controller.document.setRepertoireColor(false);
          case 'root':
            operation = controller.document.setRootPosition();
          default:
            operation = controller.document.importPgnContent(
              '[Event "Import"]\n\n1. d4 d5 *',
            );
        }
        await expectLater(operation, throwsStateError);
        expect(await file.exists(), isFalse);
        expect(controller.document.rootMoves, isEmpty);
        expect(controller.document.isRepertoireWhite, isTrue);
      },
    );
  }

  test(
    'DATA-03: single append undo restores external-before-append content',
    () async {
      final newer = original.replaceFirst('e5', 'e5 {keep this annotation}');
      await file.writeAsString(newer);
      await controller.writer.addMoveAtPosition(
        fen: controller.board.fen,
        san: 'Nf3',
        pathFromRoot: ['e4', 'e5'],
      );
      expect(await controller.writer.undo(), isTrue);
      expect(await file.readAsString(), newer);
      expect(controller.document.repertoirePgn, newer);
    },
  );

  test(
    'DATA-03: each batch undo preserves external-before-append content',
    () async {
      final newer = original.replaceFirst('e5', 'e5 {keep this annotation}');
      await file.writeAsString(newer);
      await add(['Nf3', 'Nc6', 'Bb5']);
      for (var i = 0; i < 3; i++) {
        expect(await controller.writer.undo(), isTrue);
        expect(await file.readAsString(), contains('{keep this annotation}'));
      }
      expect(await file.readAsString(), newer);
      expect(controller.writer.canUndo, isFalse);
    },
  );

  test(
    'DATA-03: external-after-append conflicts without consuming history',
    () async {
      await add();
      final committed = await file.readAsString();
      final newer = '$committed\n{external annotation}\n';
      await file.writeAsString(newer);
      await expectLater(
        controller.writer.undo(),
        throwsA(isA<AtomicWriteConflict>()),
      );
      expect(await file.readAsString(), newer);
      expect(controller.writer.canUndo, isTrue);
    },
  );

  test('DATA-03: external edit between successive undos conflicts', () async {
    await add(['Nf3', 'Nc6']);
    expect(await controller.writer.undo(), isTrue);
    final newer = '${await file.readAsString()}\n{external annotation}\n';
    await file.writeAsString(newer);
    await expectLater(
      controller.writer.undo(),
      throwsA(isA<AtomicWriteConflict>()),
    );
    expect(await file.readAsString(), newer);
    expect(controller.writer.canUndo, isTrue);
  });

  test('DATA-03: undo cannot bridge an intervening external edit', () async {
    await add();
    final newer = '${await file.readAsString()}\n{external annotation}\n';
    await file.writeAsString(newer);
    await controller.writer.addMovesAtPosition(
      pathFromRoot: ['e4', 'e5', 'Nf3'],
      sans: ['Nc6'],
    );
    expect(await controller.writer.undo(), isTrue);
    expect(await file.readAsString(), newer);
    await expectLater(
      controller.writer.undo(),
      throwsA(isA<AtomicWriteConflict>()),
    );
    expect(await file.readAsString(), newer);
  });

  test('DATA-03: failed undo keeps history for a successful retry', () async {
    await add();
    final committed = await file.readAsString();
    gateway.delegate = _InterleavingStorage(storage, () async {
      throw const FileSystemException('injected disk failure');
    });
    await expectLater(
      controller.writer.undo(),
      throwsA(isA<FileSystemException>()),
    );
    expect(controller.writer.canUndo, isTrue);
    expect(await file.readAsString(), committed);
    gateway.delegate = storage;
    expect(await controller.writer.undo(), isTrue);
    expect(await file.readAsString(), original);
  });
  test(
    'STATE-01: an in-flight append cannot acknowledge success to a new chapter',
    () async {
      final editor = _PausedRepository(LegacyPgnDocumentStore(gateway));
      controller.dispose();
      decoder = GatedRepertoireDecoder();
      controller = testBuilderWorkspace(decoder: decoder, documents: editor);
      await controller.document.setRepertoire(
        RepertoireMetadata(
          name: 'Chapter',
          filePath: file.path,
          lastModified: DateTime(2026),
        ),
      );
      final writer = controller.writer;
      final other = File(p.join(directory.path, 'other.pgn'));
      await other.writeAsString(original);
      final append = writer.addMovesAtPosition(
        pathFromRoot: ['e4', 'e5'],
        sans: ['Nf3'],
      );
      final rejected = expectLater(append, throwsStateError);
      await editor.committed.future;
      final switched = controller.document.setRepertoire(
        RepertoireMetadata(
          name: 'Other',
          filePath: other.path,
          lastModified: DateTime(2026),
        ),
      );
      editor.resume.complete();
      await rejected;
      await switched;
      expect(await file.readAsString(), contains('Nf3'));
      expect(await other.readAsString(), original);
      expect(controller.document.repertoirePgn, original);
      expect(writer.canUndo, isFalse);
    },
  );

  test(
    'bulk cut renews only its successful refresh and supports another cut',
    () async {
      await file.writeAsString(
        '$original\n[Event "Second"]\n\n1. d4 d5 *\n\n[Event "Third"]\n\n1. c4 e5 *\n',
      );
      await controller.document.loadRepertoire();
      final initialGeneration = controller.document.loadGeneration;
      final first = await controller.document.deleteLines([
        controller.document.repertoireLines.first,
      ], expectedGeneration: initialGeneration);
      expect(first!.removed, 1);
      expect(first.refreshedGeneration, greaterThan(initialGeneration));
      expect(first.remainingLines, hasLength(2));
      final second = await controller.document.deleteLines([
        first.remainingLines!.first,
      ], expectedGeneration: first.refreshedGeneration!);
      expect(second!.removed, 1);
      expect(second.remainingLines, hasLength(1));
      expect(await file.readAsString(), contains('[Event "Third"]'));
      final generation = controller.document.loadGeneration;
      final noOp = await controller.document.deleteLines(
        [],
        expectedGeneration: generation,
      );
      expect(noOp!.removed, 0);
      expect(noOp.refreshedGeneration, isNull);
      expect(noOp.remainingLines, hasLength(1));
      expect(controller.document.loadGeneration, generation);
    },
  );

  for (final missing in [false, true]) {
    test(
      'bulk cut does not renew after ${missing ? 'missing source' : 'failed refresh'}',
      () async {
        final generation = controller.document.loadGeneration;
        final line = controller.document.repertoireLines.single;
        if (missing) {
          await file.delete();
        } else {
          decoder.beforeBuild = () async =>
              throw StateError('refresh unavailable');
        }
        final receipt = await controller.document.deleteLines([
          line,
        ], expectedGeneration: generation);
        expect(receipt, isNotNull);
        expect(receipt!.removed, missing ? 0 : 1);
        expect(receipt.refreshedGeneration, isNull);
        expect(receipt.remainingLines, isNull);
        expect(
          await controller.document.deleteLines([
            line,
          ], expectedGeneration: controller.document.loadGeneration),
          isNull,
        );
      },
    );
  }

  test(
    'superseded own cut refresh never returns another chapter projection',
    () async {
      final other = File(p.join(directory.path, 'other.pgn'));
      await other.writeAsString(original.replaceFirst('Original', 'Other'));
      decoder.afterBuild = () async {
        decoder.afterBuild = null;
        await controller.document.setRepertoire(
          RepertoireMetadata(
            name: 'Other',
            filePath: other.path,
            lastModified: DateTime(2026),
          ),
        );
      };
      final receipt = await controller.document.deleteLines([
        controller.document.repertoireLines.single,
      ], expectedGeneration: controller.document.loadGeneration);
      expect(receipt!.removed, 1);
      expect(receipt.refreshedGeneration, isNull);
      expect(receipt.remainingLines, isNull);
      expect(controller.document.currentRepertoire!.filePath, other.path);
      expect(
        controller.document.repertoireLines.single.fullPgn,
        contains('[Event "Other"]'),
      );
    },
  );

  for (final bulk in [false, true]) {
    test(
      'a late ${bulk ? 'bulk' : 'single'} deletion cannot clear a new chapter',
      () async {
        final repository = _PausedDeletionRepository(
          LegacyPgnDocumentStore(gateway),
        );
        controller.dispose();
        decoder = GatedRepertoireDecoder();
        controller = testBuilderWorkspace(
          decoder: decoder,
          documents: repository,
        );
        await controller.document.setRepertoire(
          RepertoireMetadata(
            name: 'First',
            filePath: file.path,
            lastModified: DateTime(2026),
          ),
        );
        final line = controller.document.repertoireLines.single;
        final deletion = bulk
            ? controller.document.deleteLines([
                line,
              ], expectedGeneration: controller.document.loadGeneration)
            : controller.document.deleteLine(line);
        await repository.committed.future;
        final other = File(p.join(directory.path, 'other.pgn'));
        await other.writeAsString(original);
        final switched = controller.document.setRepertoire(
          RepertoireMetadata(
            name: 'Other',
            filePath: other.path,
            lastModified: DateTime(2026),
          ),
        );
        expect(controller.document.isLoading, isTrue);
        repository.resume.complete();
        final receipt = await deletion;
        if (bulk) {
          expect(receipt, isNotNull);
          final result =
              receipt
                  as ({
                    int removed,
                    int? refreshedGeneration,
                    List<dynamic>? remainingLines,
                  });
          expect(result.removed, 1);
          expect(result.refreshedGeneration, isNull);
          expect(result.remainingLines, isNull);
        }
        await switched;
        controller.selectLine(controller.document.repertoireLines.single);
        final tree = controller.board.tree;
        final selected = controller.document.selectedPgnLine;
        expect(controller.board.tree, same(tree));
        expect(controller.document.selectedPgnLine, same(selected));
        expect(controller.document.currentRepertoire!.filePath, other.path);
        expect(await other.readAsString(), original);
        expect(
          await file.readAsString(),
          isNot(contains('[Event "Original"]')),
        );
      },
    );
  }

  test('TEST-01: transposed book moves remain no-ops', () async {
    const pgn =
        '// Color: White\n\n[Event "Transposition"]\n\n1. Nf3 d5 2. g3 Nf6 *\n';
    await file.writeAsString(pgn);
    await controller.document.loadRepertoire();
    controller.board.loadMoveHistory(['g3', 'd5', 'Nf3']);
    await controller.writer.addMoveAtPosition(
      fen: controller.board.fen,
      san: 'Nf6',
      pathFromRoot: ['g3', 'd5', 'Nf3'],
    );
    expect(await file.readAsString(), pgn);
    expect(controller.writer.canUndo, isFalse);
  });

  test('DATA-03: a disk duplicate creates no phantom undo', () async {
    final newer = original.replaceFirst('e5 *', 'e5 2. Nf3 *');
    await file.writeAsString(newer);
    await add();
    expect(controller.writer.canUndo, isFalse);
    expect(await file.readAsString(), newer);
    expect(controller.document.repertoireLines.single.moves, [
      'e4',
      'e5',
      'Nf3',
    ]);
  });

  test(
    'DATA-03: scratch deletion undo never replaces the stored chapter',
    () async {
      final newer = original.replaceFirst('e5', 'e5 {external annotation}');
      await file.writeAsString(newer);
      controller.deleteDraftBranch(const TreePath([0, 0]));
      expect(controller.board.moveHistory, ['e4']);
      expect(await controller.writer.undo(), isTrue);
      expect(controller.board.moveHistory, ['e4', 'e5']);
      expect(await file.readAsString(), newer);
    },
  );

  test(
    'DATA-03: successive scratch deletion undos restore the editable tree',
    () async {
      controller.board.loadMoveHistory(['e4', 'e5', 'Nf3']);
      controller.deleteDraftBranch(const TreePath([0, 0, 0]));
      controller.deleteDraftBranch(const TreePath([0, 0]));
      expect(await controller.writer.undo(), isTrue);
      expect(controller.board.moveHistory, ['e4', 'e5']);
      expect(await controller.writer.undo(), isTrue);
      expect(controller.board.moveHistory, ['e4', 'e5', 'Nf3']);
      expect(await file.readAsString(), original);
    },
  );

  test(
    'DATA-03: fileless batches have distinct logical per-move undo',
    () async {
      final memory = testBuilderWorkspace(
        documents: DocumentRepertoireRepository(
          LegacyPgnDocumentStore(gateway),
        ),
      );
      addTearDown(memory.dispose);
      await memory.document.restoreRepertoireFromPgn(original);
      await memory.writer.addMovesAtPosition(
        pathFromRoot: ['e4', 'e5'],
        sans: ['Nf3', 'Nc6'],
      );
      expect(await memory.writer.undo(), isTrue);
      expect(memory.document.repertoireLines.single.moves, ['e4', 'e5', 'Nf3']);
      expect(await memory.writer.undo(), isTrue);
      expect(memory.document.repertoirePgn, original);
      expect(await file.readAsString(), original);
    },
  );

  test(
    'DATA-03: legacy post-install uncertainty cannot rearm native history',
    () async {
      await add(['Nf3', 'Nc6']);
      gateway.delegate = _AfterWriteFailure(storage);
      await expectLater(
        controller.writer.undo(),
        throwsA(isA<FileSystemException>()),
      );
      expect(controller.writer.canUndo, isTrue);
      gateway.delegate = storage;
      await expectLater(
        controller.writer.undo(),
        throwsA(isA<AtomicWriteConflict>()),
      );
      expect(await file.readAsString(), contains('Nf3'));
      expect(await file.readAsString(), isNot(contains('Nc6')));
    },
  );

  test(
    'DATA-03: presentation failure does not replay the committed undo',
    () async {
      await add(['Nf3', 'Nc6']);
      decoder.afterBuild = () async => throw StateError('refresh failed');
      await expectLater(controller.writer.undo(), throwsStateError);
      expect(await file.readAsString(), contains('Nf3'));
      expect(await file.readAsString(), isNot(contains('Nc6')));
      decoder.afterBuild = null;
      expect(await controller.writer.undo(), isTrue);
      expect(await file.readAsString(), original);
    },
  );

  test(
    'failed chapter switch retains destination, board and saved undo',
    () async {
      await add(['Nf3']);
      controller.selectLine(controller.document.repertoireLines.single);
      controller.board.goToEnd();
      final board = controller.board.tree;
      final fen = controller.board.fen;
      final line = controller.document.selectedPgnLine;
      final color = controller.document.isRepertoireWhite;
      final root = controller.document.rootMoves;
      final other = File(p.join(directory.path, 'other.pgn'));
      await other.writeAsString(original);
      decoder.afterBuild = () async => throw StateError('decode interrupted');
      await controller.document.setRepertoire(
        RepertoireMetadata(
          name: 'Other',
          filePath: other.path,
          lastModified: DateTime(2026),
        ),
      );
      expect(controller.document.loadError, isNotNull);
      expect(controller.document.currentRepertoire!.filePath, file.path);
      expect(controller.board.tree, same(board));
      expect(controller.board.fen, fen);
      expect(controller.document.selectedPgnLine, same(line));
      expect(controller.document.isRepertoireWhite, color);
      expect(controller.document.rootMoves, root);
      expect(controller.writer.canUndo, isTrue);
      decoder.afterBuild = null;
      expect(await controller.writer.undo(), isTrue);
      expect(await file.readAsString(), original);
      expect(await other.readAsString(), original);
    },
  );

  test('failed reload preserves a scratch deletion undo receipt', () async {
    controller.composeMoves(['e4', 'e5', 'Nf3']);
    controller.deleteDraftBranch(const TreePath([0, 0]));
    final board = controller.board.tree;
    decoder.afterBuild = () async => throw StateError('decode interrupted');
    await controller.document.loadRepertoire();
    expect(controller.board.tree, same(board));
    expect(controller.writer.canUndo, isTrue);
    expect(await controller.writer.undo(), isTrue);
    controller.board.goToEnd();
    expect(controller.board.moveHistory, ['e4', 'e5', 'Nf3']);
    expect(await file.readAsString(), original);
  });

  test('STATE-01: a queued add cannot land on a switched chapter', () async {
    final other = File(p.join(directory.path, 'other.pgn'));
    await other.writeAsString(original);
    final operation = controller.writer.addMovesAtPosition(
      pathFromRoot: ['e4', 'e5'],
      sans: ['Nf3'],
    );
    final rejection = expectLater(operation, throwsStateError);
    await controller.document.setRepertoire(
      RepertoireMetadata(
        name: 'Other',
        filePath: other.path,
        lastModified: DateTime(2026),
      ),
    );
    await rejection;
    expect(await file.readAsString(), original);
    expect(await other.readAsString(), original);
    expect(controller.writer.canUndo, isFalse);
  });
}

class _InterleavingStorage implements StorageService {
  _InterleavingStorage(this.delegate, this.beforeWrite);
  StorageService delegate;
  final Future<void> Function() beforeWrite;

  @override
  Future<bool> fileExists(String path) => delegate.fileExists(path);
  @override
  Future<String?> readFile(String path) => delegate.readFile(path);
  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    await beforeWrite();
    await delegate.writeFile(
      path,
      content,
      createOnly: createOnly,
      expectedContent: expectedContent,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AfterWriteFailure extends _InterleavingStorage {
  _AfterWriteFailure(StorageService storage) : super(storage, () async {});

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    await delegate.writeFile(
      path,
      content,
      createOnly: createOnly,
      expectedContent: expectedContent,
    );
    throw const FileSystemException('injected post-install failure');
  }
}

class _PausedRepository extends DocumentRepertoireRepository {
  _PausedRepository(super.documents);
  final committed = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<RepertoireMutationReceipt> append(
    String filePath,
    List<String> pathFromRoot,
    List<String> newSans, {
    String? startingFen,
    bool isWhiteRepertoire = true,
  }) async {
    final result = await super.append(
      filePath,
      pathFromRoot,
      newSans,
      startingFen: startingFen,
      isWhiteRepertoire: isWhiteRepertoire,
    );
    committed.complete();
    await resume.future;
    return result;
  }
}

class _PausedDeletionRepository extends DocumentRepertoireRepository {
  _PausedDeletionRepository(super.documents);
  final committed = Completer<void>();
  final resume = Completer<void>();
  @override
  Future<bool> deleteLine(
    String path,
    String lineId, {
    required String expectedContent,
  }) async {
    final result = await super.deleteLine(
      path,
      lineId,
      expectedContent: expectedContent,
    );
    committed.complete();
    await resume.future;
    return result;
  }

  @override
  Future<int> deleteLinesAt(String path, Map<int, String> expectedGames) async {
    final result = await super.deleteLinesAt(path, expectedGames);
    committed.complete();
    await resume.future;
    return result;
  }
}
