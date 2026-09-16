import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:chess_auto_prep/services/repertoire_file_editor.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:chess_auto_prep/utils/atomic_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const original = '// Color: White\n\n[Event "Original"]\n\n1. e4 e5 *\n';

void main() {
  late Directory directory;
  late File file;
  late RepertoireController controller;
  late StorageService storage;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mutation-safety-');
    file = File(p.join(directory.path, 'chapter.pgn'));
    await file.writeAsString(original);
    storage = StorageFactory.instance;
    controller = RepertoireController();
    await controller.setRepertoire(
      RepertoireMetadata(
        name: 'Chapter',
        filePath: file.path,
        lastModified: DateTime(2026),
      ),
    );
    controller.loadMoveHistory(['e4', 'e5']);
  });

  tearDown(() async {
    StorageFactory.instanceForTest = storage;
    controller.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> add([List<String> moves = const ['Nf3']]) => controller.writer
      .addMovesAtPosition(pathFromRoot: ['e4', 'e5'], sans: moves);

  for (final action in ['color', 'root', 'import']) {
    test('DATA-01: $action refuses an interleaved replacement', () async {
      const newer = '$original\n{external annotation}\n';
      StorageFactory.instanceForTest = _InterleavingStorage(storage, () async {
        await file.writeAsString(newer);
      });
      final Future<Object?> operation;
      switch (action) {
        case 'color':
          operation = controller.setRepertoireColor(false);
        case 'root':
          operation = controller.setRootPosition();
        default:
          operation = controller.importPgnContent(
            '[Event "Import"]\n\n1. d4 d5 *',
          );
      }
      await expectLater(operation, throwsA(isA<AtomicWriteConflict>()));
      expect(await file.readAsString(), newer);
      expect(controller.isRepertoireWhite, isTrue);
      expect(controller.rootMoves, isEmpty);
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
            operation = controller.setRepertoireColor(false);
          case 'root':
            operation = controller.setRootPosition();
          default:
            operation = controller.importPgnContent(
              '[Event "Import"]\n\n1. d4 d5 *',
            );
        }
        await expectLater(operation, throwsStateError);
        expect(await file.exists(), isFalse);
        expect(controller.rootMoves, isEmpty);
        expect(controller.isRepertoireWhite, isTrue);
      },
    );
  }

  test(
    'DATA-03: single append undo restores external-before-append content',
    () async {
      final newer = original.replaceFirst('e5', 'e5 {keep this annotation}');
      await file.writeAsString(newer);
      await controller.writer.addMoveAtPosition(
        fen: controller.fen,
        san: 'Nf3',
        pathFromRoot: ['e4', 'e5'],
      );
      expect(await controller.writer.undo(), isTrue);
      expect(await file.readAsString(), newer);
      expect(controller.repertoirePgn, newer);
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
    StorageFactory.instanceForTest = _InterleavingStorage(storage, () async {
      throw const FileSystemException('injected disk failure');
    });
    await expectLater(
      controller.writer.undo(),
      throwsA(isA<FileSystemException>()),
    );
    expect(controller.writer.canUndo, isTrue);
    expect(await file.readAsString(), committed);
    StorageFactory.instanceForTest = storage;
    expect(await controller.writer.undo(), isTrue);
    expect(await file.readAsString(), original);
  });
  test(
    'STATE-01: an in-flight append cannot acknowledge success to a new chapter',
    () async {
      final editor = _PausedEditor();
      controller.dispose();
      controller = RepertoireController(
        repertoireService: _PausedService(editor),
      );
      await controller.setRepertoire(
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
      await controller.setRepertoire(
        RepertoireMetadata(
          name: 'Other',
          filePath: other.path,
          lastModified: DateTime(2026),
        ),
      );
      editor.resume.complete();
      await rejected;
      expect(await file.readAsString(), contains('Nf3'));
      expect(await other.readAsString(), original);
      expect(controller.repertoirePgn, original);
      expect(writer.canUndo, isFalse);
    },
  );

  test('TEST-01: transposed book moves remain no-ops', () async {
    const pgn =
        '// Color: White\n\n[Event "Transposition"]\n\n1. Nf3 d5 2. g3 Nf6 *\n';
    await file.writeAsString(pgn);
    await controller.loadRepertoire();
    controller.loadMoveHistory(['g3', 'd5', 'Nf3']);
    await controller.writer.addMoveAtPosition(
      fen: controller.fen,
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
    expect(controller.repertoireLines.single.moves, ['e4', 'e5', 'Nf3']);
  });

  test(
    'DATA-03: scratch deletion undo never replaces the stored chapter',
    () async {
      final newer = original.replaceFirst('e5', 'e5 {external annotation}');
      await file.writeAsString(newer);
      controller.deleteAtPath(const TreePath([0, 0]));
      expect(controller.moveHistory, ['e4']);
      expect(await controller.writer.undo(), isTrue);
      expect(controller.moveHistory, ['e4', 'e5']);
      expect(await file.readAsString(), newer);
    },
  );

  test(
    'DATA-03: successive scratch deletion undos restore the editable tree',
    () async {
      controller.loadMoveHistory(['e4', 'e5', 'Nf3']);
      controller.deleteAtPath(const TreePath([0, 0, 0]));
      controller.deleteAtPath(const TreePath([0, 0]));
      expect(await controller.writer.undo(), isTrue);
      expect(controller.moveHistory, ['e4', 'e5']);
      expect(await controller.writer.undo(), isTrue);
      expect(controller.moveHistory, ['e4', 'e5', 'Nf3']);
      expect(await file.readAsString(), original);
    },
  );

  test(
    'DATA-03: fileless batches have distinct logical per-move undo',
    () async {
      final memory = RepertoireController();
      addTearDown(memory.dispose);
      await memory.restoreRepertoireFromPgn(original);
      await memory.writer.addMovesAtPosition(
        pathFromRoot: ['e4', 'e5'],
        sans: ['Nf3', 'Nc6'],
      );
      expect(await memory.writer.undo(), isTrue);
      expect(memory.repertoireLines.single.moves, ['e4', 'e5', 'Nf3']);
      expect(await memory.writer.undo(), isTrue);
      expect(memory.repertoirePgn, original);
      expect(await file.readAsString(), original);
    },
  );

  test(
    'DATA-03: post-install failure reconciles without replaying undo',
    () async {
      await add(['Nf3', 'Nc6']);
      StorageFactory.instanceForTest = _AfterWriteFailure(storage);
      expect(await controller.writer.undo(), isTrue);
      expect(controller.repertoireLines.single.moves, ['e4', 'e5', 'Nf3']);
      StorageFactory.instanceForTest = storage;
      expect(await controller.writer.undo(), isTrue);
      expect(await file.readAsString(), original);
      expect(controller.writer.canUndo, isFalse);
    },
  );

  test(
    'DATA-03: presentation failure does not replay the committed undo',
    () async {
      await add(['Nf3', 'Nc6']);
      controller.debugBeforeRepertoireApply = () async =>
          throw StateError('refresh failed');
      await expectLater(controller.writer.undo(), throwsStateError);
      expect(await file.readAsString(), contains('Nf3'));
      expect(await file.readAsString(), isNot(contains('Nc6')));
      controller.debugBeforeRepertoireApply = null;
      expect(await controller.writer.undo(), isTrue);
      expect(await file.readAsString(), original);
    },
  );

  test('STATE-01: a queued add cannot land on a switched chapter', () async {
    final other = File(p.join(directory.path, 'other.pgn'));
    await other.writeAsString(original);
    final operation = controller.writer.addMovesAtPosition(
      pathFromRoot: ['e4', 'e5'],
      sans: ['Nf3'],
    );
    final rejection = expectLater(operation, throwsStateError);
    await controller.setRepertoire(
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
  final StorageService delegate;
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

class _PausedService extends RepertoireService {
  _PausedService(this.editor);
  final RepertoireFileEditor editor;
  @override
  RepertoireFileEditor get files => editor;
}

class _PausedEditor extends RepertoireFileEditor {
  final committed = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<AppendMovesResult> appendMovesAtPath(
    String filePath,
    List<String> pathFromRoot,
    List<String> newSans, {
    String? startingFen,
    bool isWhiteRepertoire = true,
  }) async {
    final result = await super.appendMovesAtPath(
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
