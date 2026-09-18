import 'dart:io';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';

import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/app/builder_lifetime.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/board_helpers.dart';
import 'helpers/tactics_helpers.dart';

Future<void> _wait(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 120 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(done(), isTrue);
}

Future<void> _undo(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Builder native per-move undo rejects an equal-text replacement', (
    tester,
  ) async {
    expect(Platform.environment['XDG_DATA_HOME'], contains('/profile/'));
    final root = await AppPaths.repertoiresDirectory(create: true);
    final folder = await Directory(
      p.join(
        root.path,
        'Native history ${DateTime.now().microsecondsSinceEpoch}',
      ),
    ).create();
    addTearDown(() => folder.delete(recursive: true));
    final file = File(p.join(folder.path, 'Main.pgn'));
    const original =
        '// Color: White\n\n[Event "Native history"]\n[Result "*"]\n\n1. e4 e5 *\n';
    await file.writeAsString(original);
    await pumpApp(tester);
    getAppState(tester).switchToBuilder(repertoirePath: file.path);
    await _wait(
      tester,
      () => find.text('Native history').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Native history').first);
    await _wait(
      tester,
      () => find.byType(InteractivePgnEditor).evaluate().isNotEmpty,
    );
    final owner = tester
        .element(find.byType(InteractivePgnEditor))
        .read<BuilderLifetime>()
        .workspace;
    expect(owner.document.openingGraph, isNot(isA<OpeningTree>()));

    await owner.writer.addMovesAtPosition(
      pathFromRoot: ['e4', 'e5'],
      sans: ['Nf3', 'Nc6'],
    );
    await tester.pump();
    expect(
      owner.document.openingGraph!.nodeAtPath(['e4', 'e5', 'Nf3', 'Nc6']),
      isNotNull,
    );
    await _undo(tester);
    await _wait(tester, () => !owner.document.repertoirePgn!.contains('Nc6'));
    expect(await file.readAsString(), contains('Nf3'));
    expect(
      owner.document.openingGraph!.nodeAtPath(['e4', 'e5', 'Nf3', 'Nc6']),
      isNull,
    );
    await _undo(tester);
    await _wait(tester, () => !owner.writer.canUndo);
    expect(await file.readAsString(), original);

    await owner.writer.addMovesAtPosition(
      pathFromRoot: ['e4', 'e5'],
      sans: ['Nf3'],
    );
    await tester.pump();
    final committed = await file.readAsString();
    final board = owner.board.fen;
    final graph = owner.document.openingGraph;
    final replacement = File(p.join(folder.path, 'external.pgn'));
    await replacement.writeAsString(committed);
    await replacement.rename(file.path);
    await _undo(tester);
    await _wait(
      tester,
      () => find.textContaining('Undo failed:').evaluate().isNotEmpty,
    );
    expect(await file.readAsString(), committed);
    expect(owner.document.repertoirePgn, committed);
    expect(owner.document.currentRepertoire!.filePath, file.path);
    expect(owner.board.fen, board);
    expect(owner.document.openingGraph, same(graph));
    expect(owner.writer.canUndo, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
