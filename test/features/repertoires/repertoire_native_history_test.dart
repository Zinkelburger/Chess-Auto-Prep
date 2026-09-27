import 'dart:io';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/repertoires/controllers/builder_workspace_controller.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/document_repertoire_repository.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/isolate_repertoire_decoder.dart';
import 'package:chess_auto_prep/utils/atomic_file.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late File file;
  late NativePgnDocumentStore store;
  late BuilderWorkspaceController owner;
  var failFlush = false;
  var failStage = false;
  const original =
      '// Color: White\n\n[Event "Line"]\n[LineID "one"]\n\n1. e4 e5 *\n';
  Future<PgnSnapshot> current() async =>
      (await store.open(file.path) as PgnOpened).snapshot;
  Future<void> append(List<String> prefix, List<String> moves) =>
      owner.writer.addMovesAtPosition(pathFromRoot: prefix, sans: moves);
  setUp(() async {
    root = Directory.systemTemp.createTempSync('builder-native-history-');
    file = File('${root.path}/chapter.pgn')..writeAsStringSync(original);
    failFlush = false;
    failStage = false;
    store = NativePgnDocumentStore(
      writer: AtomicFileWriter(
        testHook: (step) async {
          if (failStage && step == AtomicWriteStep.tempFlushed) {
            throw const FileSystemException('stage failed');
          }
        },
      ),
      flushDirectory: (path) async {
        if (failFlush && path == root.path) {
          throw const FileSystemException('ack flush failed');
        }
        await syncDirectory(path);
      },
    );
    owner = BuilderWorkspaceController(
      checkpoint: () async {},
      documents: DocumentRepertoireRepository(store),
      decoder: const IsolateRepertoireDecoder(),
    );
    await owner.document.setRepertoire(
      RepertoireMetadata(
        name: 'Native',
        filePath: file.path,
        lastModified: DateTime(2026),
      ),
    );
  });
  tearDown(() {
    owner.dispose();
    root.deleteSync(recursive: true);
  });

  test('successive undo arms only actual replacement revisions', () async {
    final a = await current();
    await append(['e4', 'e5'], ['Nf3']);
    final b = await current();
    await append(['e4', 'e5', 'Nf3'], ['Nc6']);
    final c = await current();
    expect(await owner.writer.undo(), isTrue);
    final b2 = await current();
    expect(b2.content, b.content);
    expect(b2.revision, isNot(b.revision));
    expect(b2.revision, isNot(c.revision));
    expect(await owner.writer.undo(), isTrue);
    final a2 = await current();
    expect(a2.content, a.content);
    expect(a2.revision, isNot(a.revision));
    expect(owner.document.repertoirePgn, a.content);
    expect(owner.writer.canUndo, isFalse);
  });

  for (final moves in [
    ['Nf3'],
    ['Nf3', 'Nc6', 'Bb5'],
  ]) {
    test(
      'external-before content survives ${moves.length} logical undos',
      () async {
        final external = original.replaceFirst(
          'e5',
          'e5 {external annotation}',
        );
        await store.save(await current(), external);
        await append(['e4', 'e5'], moves);
        for (var remaining = moves.length - 1; remaining >= 0; remaining--) {
          expect(await owner.writer.undo(), isTrue);
          expect(file.readAsStringSync(), contains('{external annotation}'));
          expect(owner.document.repertoirePgn, file.readAsStringSync());
          expect(owner.document.repertoireLines.single.moves, [
            'e4',
            'e5',
            ...moves.take(remaining),
          ]);
        }
        expect(file.readAsStringSync(), external);
      },
    );
  }

  for (final between in [false, true]) {
    test(
      'equal-text external replacement ${between ? 'between undos' : 'after append'} conflicts',
      () async {
        await append(['e4', 'e5'], ['Nf3', 'Nc6']);
        if (between) expect(await owner.writer.undo(), isTrue);
        final beforeExternal = await current();
        final external =
            await store.save(beforeExternal, beforeExternal.content)
                as PgnSaved;
        expect(external.after.revision, isNot(beforeExternal.revision));
        await expectLater(
          owner.writer.undo(),
          throwsA(isA<AtomicWriteConflict>()),
        );
        expect((await current()).revision, external.after.revision);
        expect(owner.writer.canUndo, isTrue);
      },
    );
  }

  test(
    'external edit between mutations permanently breaks predecessor linkage',
    () async {
      await append(['e4', 'e5'], ['Nf3']);
      final externalText = (await current()).content.replaceFirst(
        'Nf3',
        'Nf3 {external}',
      );
      await store.save(await current(), externalText);
      await append(['e4', 'e5', 'Nf3'], ['Nc6']);
      expect(await owner.writer.undo(), isTrue);
      expect(file.readAsStringSync(), externalText);
      await expectLater(
        owner.writer.undo(),
        throwsA(isA<AtomicWriteConflict>()),
      );
      expect(file.readAsStringSync(), externalText);
      expect(owner.writer.canUndo, isTrue);
    },
  );

  test(
    'proven installed undo reconciles once and arms its native predecessor',
    () async {
      await append(['e4', 'e5'], ['Nf3', 'Nc6']);
      failFlush = true;
      expect(await owner.writer.undo(), isTrue);
      expect(owner.document.repertoireLines.single.moves, ['e4', 'e5', 'Nf3']);
      failFlush = false;
      expect(await owner.writer.undo(), isTrue);
      expect(file.readAsStringSync(), original);
      expect(owner.writer.canUndo, isFalse);
    },
  );

  test(
    'failed native batch and undo retain history and expectations for retry',
    () async {
      failStage = true;
      await expectLater(
        append(['e4', 'e5'], ['Nf3', 'Nc6']),
        throwsA(isA<FileSystemException>()),
      );
      expect(file.readAsStringSync(), original);
      expect(owner.writer.canUndo, isFalse);
      failStage = false;
      await append(['e4', 'e5'], ['Nf3']);
      final saved = await current();
      failStage = true;
      await expectLater(
        owner.writer.undo(),
        throwsA(isA<FileSystemException>()),
      );
      expect((await current()).revision, saved.revision);
      expect(owner.writer.canUndo, isTrue);
      failStage = false;
      expect(await owner.writer.undo(), isTrue);
      expect(file.readAsStringSync(), original);
    },
  );

  test(
    'proven installed append produces one history chain without replay',
    () async {
      failFlush = true;
      await append(['e4', 'e5'], ['Nf3', 'Nc6']);
      failFlush = false;
      expect(owner.document.repertoireLines.single.moves, [
        'e4',
        'e5',
        'Nf3',
        'Nc6',
      ]);
      expect(await owner.writer.undo(), isTrue);
      expect(await owner.writer.undo(), isTrue);
      expect(file.readAsStringSync(), original);
      expect(owner.writer.canUndo, isFalse);
    },
  );

  test('duplicate append leaves no native commit or phantom undo', () async {
    final before = await current();
    await append(['e4'], ['e5']);
    expect((await current()).revision, before.revision);
    expect(owner.writer.canUndo, isFalse);
  });
}
