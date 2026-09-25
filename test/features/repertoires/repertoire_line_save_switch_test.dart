import 'package:chess_auto_prep/utils/atomic_file.dart';
import '../../support/repertoire_dependencies.dart';
import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_controller.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';

const _pgn = '// Color: White\n\n[Event "Line"]\n[Result "*"]\n\n1. e4 e5 *\n';

void main() {
  late Directory directory;
  late RepertoireController controller;
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
    controller = testRepertoireController();
    await controller.setRepertoire(first);
    controller.loadPgnLine(controller.repertoireLines.single);
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
        controller.updateSelectedLineContent(
          _pgn.replaceFirst('e5', 'e5 {my note}'),
        ),
        throwsA(isA<AtomicWriteConflict>()),
      );
      expect(await File(first.filePath).readAsString(), external);
      await expectLater(controller.flushDocumentForClose(), throwsStateError);
    },
  );

  test(
    'queued saves from old and refreshed callbacks advance the acknowledged line',
    () async {
      final save = controller.selectedLineSaver!;
      final firstSave = save(_pgn.replaceFirst('e5', 'e5 {first note}'));
      final newerSave = controller.selectedLineSaver!;
      final secondSave = newerSave(_pgn.replaceFirst('e5', 'e5 {second note}'));
      expect(await firstSave, isTrue);
      expect(await secondSave, isTrue);
      expect(
        await File(first.filePath).readAsString(),
        contains('{second note}'),
      );
      expect(controller.selectedPgnLine!.fullPgn, contains('{second note}'));
      expect(await save(_pgn.replaceFirst('e5', 'e5 {third note}')), isTrue);
      expect(
        await File(first.filePath).readAsString(),
        contains('{third note}'),
      );
      await controller.flushDocumentForClose();
    },
  );

  test('a failed edit survives successful edits elsewhere and refused reloads', () async {
    final twoLines = '$_pgn\n[Event "Second line"]\n[Result "*"]\n\n1. d4 d5 *\n';
    await File(first.filePath).writeAsString(twoLines);
    await controller.loadRepertoire();
    controller.loadPgnLine(controller.repertoireLines.first);
    final saveFirst = controller.selectedLineSaver!;
    final intended = _pgn.replaceFirst('e5', 'e5 {unsaved first}');
    await File(first.filePath).writeAsString(twoLines.replaceFirst('e5', 'e5 {external}'));
    await expectLater(saveFirst(intended), throwsA(isA<AtomicWriteConflict>()));
    controller.loadPgnLine(controller.repertoireLines.last);
    await controller.updateSelectedLineContent(
      controller.selectedPgnLine!.fullPgn.replaceFirst('d5', 'd5 {saved second}'),
    );
    final board = controller.tree;
    final lines = controller.repertoireLines;
    await controller.setRepertoire(second);
    expect(controller.currentRepertoire, first);
    expect(controller.tree, same(board));
    expect(controller.repertoireLines, same(lines));
    expect(controller.loadError, contains('pending line edits'));
    expect(controller.pendingLineDrafts.single.content, intended);
    await controller.loadRepertoire();
    expect(controller.tree, same(board));
    await expectLater(controller.flushDocumentForClose(), throwsStateError);
    final saved = await File(first.filePath).readAsString();
    await File(first.filePath).writeAsString(saved.replaceFirst(' {external}', ''));
    expect(await saveFirst(intended), isTrue);
    expect(controller.pendingLineDrafts, isEmpty);
    await controller.flushDocumentForClose();
    expect(await File(first.filePath).readAsString(), contains('saved second'));
  });

  test(
    'a pending chapter keeps its loaded tree until atomic replacement',
    () async {
      final tree = controller.tree;
      final lines = controller.repertoireLines;
      final gate = Completer<void>();
      controller.debugBeforeRepertoireApply = () => gate.future;
      final load = controller.setRepertoire(second);
      expect(controller.isLoading, isTrue);
      expect(controller.tree, same(tree));
      expect(controller.repertoireLines, same(lines));
      expect(await controller.updateSelectedLineContent(_pgn), isFalse);
      gate.complete();
      await load;
      expect(controller.isLoading, isFalse);
      expect(controller.tree, isNot(same(tree)));
    },
  );

  test(
    'same-file reload flushes pending edits before reading the PGN',
    () async {
      final save = controller.selectedLineSaver!;
      Future<bool>? write;
      controller.setPendingLineSave(() {
        write = save(_pgn.replaceFirst('e5', 'e5 {Pending comment}'));
      });
      controller.debugAfterRepertoireRead = () async {
        expect(
          await File(first.filePath).readAsString(),
          contains('Pending comment'),
        );
      };
      await controller.loadRepertoire();
      expect(await write, isTrue);
      expect(
        controller.repertoireLines.single.fullPgn,
        contains('Pending comment'),
      );
      expect(controller.loadError, isNull);
    },
  );

  test('rapid A to B to A waits for original chapter edits', () async {
    final save = controller.selectedLineSaver!;
    Future<bool>? write;
    controller.setPendingLineSave(() {
      write = save(_pgn.replaceFirst('e5', 'e5 {Saved before returning}'));
    });
    final loadB = controller.setRepertoire(second);
    final loadA = controller.setRepertoire(first);
    await Future.wait([loadB, loadA]);
    expect(await write, isTrue);
    expect(controller.currentRepertoire, first);
    expect(
      controller.repertoireLines.single.fullPgn,
      contains('Saved before returning'),
    );
    expect(await File(second.filePath).readAsString(), _pgn);
  });

  test(
    'a debounced save stays with its original chapter after a switch',
    () async {
      final saveFirst = controller.selectedLineSaver!;
      await controller.setRepertoire(second);
      controller.loadPgnLine(controller.repertoireLines.single);
      final selectedSecond = controller.selectedPgnLine;
      final secondTree = controller.tree;
      final secondLines = controller.repertoireLines;
      final saved = await saveFirst(
        _pgn.replaceFirst('e5', 'e5 {First comment}'),
      );
      expect(saved, isTrue);
      expect(
        await File(first.filePath).readAsString(),
        contains('First comment'),
      );
      expect(await File(second.filePath).readAsString(), _pgn);
      expect(controller.repertoireLines, same(secondLines));
      expect(controller.selectedPgnLine, same(selectedSecond));
      expect(controller.tree, same(secondTree));
    },
  );

  test(
    'a save already in flight cannot overwrite the next chapter state',
    () async {
      final save = controller.updateSelectedLineContent(
        _pgn.replaceFirst('e5', 'e5 {Original chapter}'),
      );
      await controller.setRepertoire(second);
      expect(await save, isTrue);
      expect(controller.currentRepertoire, second);
      expect(
        controller.repertoireLines.single.fullPgn,
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
      final save = controller.selectedLineSaver!;
      Future<bool>? write;
      controller.setPendingLineSave(() {
        write = save(_pgn.replaceFirst('e5', 'e5 {close note}'));
      });
      await controller.flushDocumentForClose();
      expect(await write, isTrue);
      expect(await File(first.filePath).readAsString(), contains('close note'));
      // Remove the selected source game so its captured writer cannot apply.
      await File(first.filePath).writeAsString('[Event "Other"]\n\n1. d4 d5 *');
      expect(await controller.updateSelectedLineContent(_pgn), isFalse);
      await expectLater(controller.flushDocumentForClose(), throwsStateError);
      await expectLater(controller.flushDocumentForClose(), throwsStateError);
    },
  );
}
