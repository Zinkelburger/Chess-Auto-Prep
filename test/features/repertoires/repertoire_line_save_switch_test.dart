import 'package:chess_auto_prep/utils/atomic_file.dart';
import '../../support/repertoire_dependencies.dart';
import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/controllers/builder_workspace_controller.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';

const _pgn = '// Color: White\n\n[Event "Line"]\n[Result "*"]\n\n1. e4 e5 *\n';

void main() {
  late GatedRepertoireDecoder decoder;
  late Directory directory;
  late BuilderWorkspaceController controller;
  late RepertoireMetadata first;
  late RepertoireMetadata second;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chapter_save_test');
    StorageFactory.instanceForTest = IOStorageService(
      documentsRoot: directory,
      supportRoot: directory,
      repertoiresRoot: directory,
    );
    RepertoireMetadata chapter(String name) => RepertoireMetadata(
      name: name,
      filePath: p.join(directory.path, '$name.pgn'),
      lastModified: DateTime(2026),
    );
    first = chapter('First');
    second = chapter('Second');
    await File(first.filePath).writeAsString(_pgn);
    await File(second.filePath).writeAsString(_pgn);
    decoder = GatedRepertoireDecoder();
    controller = testBuilderWorkspace(decoder: decoder);
    await controller.document.setRepertoire(first);
    controller.selectLine(controller.document.repertoireLines.single);
  });
  tearDown(() async {
    controller.dispose();
    StorageFactory.instanceForTest = null;
    await directory.delete(recursive: true);
  });

  test(
    'a line save rejects an external edit made before the save begins',
    () async {
      final external = _pgn.replaceFirst('e5', 'e5 {external note}');
      await File(first.filePath).writeAsString(external);
      await expectLater(
        controller.document.updateSelectedLineContent(
          _pgn.replaceFirst('e5', 'e5 {my note}'),
        ),
        throwsA(isA<AtomicWriteConflict>()),
      );
      expect(await File(first.filePath).readAsString(), external);
      await expectLater(
        controller.document.flushDocumentForClose(),
        throwsStateError,
      );
    },
  );

  test(
    'queued saves from old and refreshed callbacks advance the acknowledged line',
    () async {
      final save = controller.document.selectedLineSaver!;
      final firstSave = save(_pgn.replaceFirst('e5', 'e5 {first note}'));
      final newerSave = controller.document.selectedLineSaver!;
      final secondSave = newerSave(_pgn.replaceFirst('e5', 'e5 {second note}'));
      expect(await firstSave, isTrue);
      expect(await secondSave, isTrue);
      expect(
        await File(first.filePath).readAsString(),
        contains('{second note}'),
      );
      expect(
        controller.document.selectedPgnLine!.fullPgn,
        contains('{second note}'),
      );
      expect(await save(_pgn.replaceFirst('e5', 'e5 {third note}')), isTrue);
      expect(
        await File(first.filePath).readAsString(),
        contains('{third note}'),
      );
      await controller.document.flushDocumentForClose();
    },
  );

  test(
    'a pending chapter keeps its loaded tree until atomic replacement',
    () async {
      final tree = controller.board.tree;
      final lines = controller.document.repertoireLines;
      final gate = Completer<void>();
      decoder.afterBuild = () => gate.future;
      final load = controller.document.setRepertoire(second);
      expect(controller.document.isLoading, isTrue);
      expect(controller.board.tree, same(tree));
      expect(controller.document.repertoireLines, same(lines));
      expect(
        await controller.document.updateSelectedLineContent(_pgn),
        isFalse,
      );
      gate.complete();
      await load;
      expect(controller.document.isLoading, isFalse);
      expect(controller.board.tree, isNot(same(tree)));
    },
  );

  test(
    'same-file reload flushes pending edits before reading the PGN',
    () async {
      final save = controller.document.selectedLineSaver!;
      Future<bool>? write;
      write = save(_pgn.replaceFirst('e5', 'e5 {Pending comment}'));
      decoder.beforeBuild = () async {
        expect(
          await File(first.filePath).readAsString(),
          contains('Pending comment'),
        );
      };
      await controller.document.loadRepertoire();
      expect(await write, isTrue);
      expect(
        controller.document.repertoireLines.single.fullPgn,
        contains('Pending comment'),
      );
      expect(controller.document.loadError, isNull);
    },
  );

  test('rapid A to B to A waits for original chapter edits', () async {
    final save = controller.document.selectedLineSaver!;
    Future<bool>? write;
    write = save(_pgn.replaceFirst('e5', 'e5 {Saved before returning}'));
    final loadB = controller.document.setRepertoire(second);
    final loadA = controller.document.setRepertoire(first);
    await Future.wait([loadB, loadA]);
    expect(await write, isTrue);
    expect(controller.document.currentRepertoire, first);
    expect(
      controller.document.repertoireLines.single.fullPgn,
      contains('Saved before returning'),
    );
    expect(await File(second.filePath).readAsString(), _pgn);
  });

  test(
    'a debounced save stays with its original chapter after a switch',
    () async {
      final saveFirst = controller.document.selectedLineSaver!;
      await controller.document.setRepertoire(second);
      controller.selectLine(controller.document.repertoireLines.single);
      final selectedSecond = controller.document.selectedPgnLine;
      final secondTree = controller.board.tree;
      final secondLines = controller.document.repertoireLines;
      final saved = await saveFirst(
        _pgn.replaceFirst('e5', 'e5 {First comment}'),
      );
      expect(saved, isTrue);
      expect(
        await File(first.filePath).readAsString(),
        contains('First comment'),
      );
      expect(await File(second.filePath).readAsString(), _pgn);
      expect(controller.document.repertoireLines, same(secondLines));
      expect(controller.document.selectedPgnLine, same(selectedSecond));
      expect(controller.board.tree, same(secondTree));
    },
  );

  test(
    'a save already in flight cannot overwrite the next chapter state',
    () async {
      final save = controller.document.updateSelectedLineContent(
        _pgn.replaceFirst('e5', 'e5 {Original chapter}'),
      );
      await controller.document.setRepertoire(second);
      expect(await save, isTrue);
      expect(controller.document.currentRepertoire, second);
      expect(
        controller.document.repertoireLines.single.fullPgn,
        isNot(contains('Original chapter')),
      );
      expect(
        await File(first.filePath).readAsString(),
        contains('Original chapter'),
      );
      expect(await File(second.filePath).readAsString(), _pgn);
    },
  );
  test(
    'close flushes pending comments and keeps repeated failures blocked',
    () async {
      final save = controller.document.selectedLineSaver!;
      Future<bool>? write;
      write = save(_pgn.replaceFirst('e5', 'e5 {close note}'));
      await controller.document.flushDocumentForClose();
      expect(await write, isTrue);
      expect(await File(first.filePath).readAsString(), contains('close note'));
      // Remove the selected source game so its captured writer cannot apply.
      await File(first.filePath).writeAsString('[Event "Other"]\n\n1. d4 d5 *');
      expect(
        await controller.document.updateSelectedLineContent(_pgn),
        isFalse,
      );
      await expectLater(
        controller.document.flushDocumentForClose(),
        throwsStateError,
      );
      await expectLater(
        controller.document.flushDocumentForClose(),
        throwsStateError,
      );
    },
  );
}
