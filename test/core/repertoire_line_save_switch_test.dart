import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/models/repertoire_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _pgn = '// Color: White\n\n[Event "Line"]\n[Result "*"]\n\n1. e4 e5 *\n';

void main() {
  late Directory directory;
  late RepertoireController controller;
  late RepertoireMetadata first;
  late RepertoireMetadata second;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chapter_save_test');
    RepertoireMetadata chapter(String name) => RepertoireMetadata(
      name: name,
      filePath: p.join(directory.path, '$name.pgn'),
      lastModified: DateTime(2026),
    );
    first = chapter('First');
    second = chapter('Second');
    await File(first.filePath).writeAsString(_pgn);
    await File(second.filePath).writeAsString(_pgn);
    controller = RepertoireController();
    await controller.setRepertoire(first);
    controller.loadPgnLine(controller.repertoireLines.single);
  });
  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
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
}
