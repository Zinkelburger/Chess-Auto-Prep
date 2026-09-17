import 'dart:io';
import 'package:chess_auto_prep/chess_core/moves/move_tree_snapshot.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:chess_auto_prep/widgets/pgn_with_analysis_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'helpers/board_helpers.dart';
import 'helpers/tactics_helpers.dart';

Future<void> ready(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 120 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Builder immutable annotations save, survive mode changes and reload',
    (tester) async {
      final root = await AppPaths.repertoiresDirectory();
      final folder = await Directory(
        p.join(
          root.path,
          'Builder projection ${DateTime.now().microsecondsSinceEpoch}',
        ),
      ).create(recursive: true);
      addTearDown(() => folder.delete(recursive: true));
      final file = File(p.join(folder.path, 'Main.pgn'));
      await file.writeAsString(
        '// Color: White\n\n[Event "Projection line"]\n[Result "*"]\n\n1. e4 e5 (1... c5) 2. Nf3 *',
      );
      await pumpApp(tester);
      final app = getAppState(tester);
      app.switchToBuilder(repertoirePath: file.path);
      await ready(tester, find.text('Projection line'));
      await tester.tap(find.text('Projection line').first);
      await ready(tester, find.byType(PgnWithAnalysisPane));
      final owner = tester
          .widget<PgnWithAnalysisPane>(find.byType(PgnWithAnalysisPane))
          .controller;
      final before = owner.tree;
      final cursor = owner.path;
      expect(before, isA<MoveTreeSnapshot>());
      expect(cursor.isNotEmpty, isTrue);
      expect(PgnAnnotationPanel.focusActive(), isTrue);
      await tester.pump();
      await tester.pump();
      final field = find.descendant(
        of: find.byType(PgnAnnotationPanel),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'Keep this');
      await tester.pump();
      final input = find.descendant(
        of: field,
        matching: find.byType(EditableText),
      );
      final fieldState = tester.state(input);
      await tester.enterText(field, 'Keep this annotation');
      await tester.pump();
      expect(tester.state(input), same(fieldState));
      expect(tester.widget<EditableText>(input).focusNode.hasFocus, isTrue);
      expect(before.commentAt(cursor), isNull);
      expect(owner.tree.commentAt(cursor), 'Keep this annotation');
      await tester.tap(find.byTooltip('Good move'));
      await tester.pump();
      expect(owner.tree.nodeAt(cursor)!.nags, [1]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await owner.flushDocumentForClose();
      final saved = await file.readAsString();
      expect(saved, contains('Keep this annotation'));
      expect(saved, contains('\$1'));
      expect(saved, contains('c5'));
      final annotated = owner.tree;
      app.setMode(AppMode.tactics);
      await tester.pump();
      app.setMode(AppMode.repertoire);
      await ready(tester, find.byType(InteractivePgnEditor));
      expect(owner.tree, same(annotated));
      expect(owner.path, cursor);
      await owner.loadRepertoire();
      await ready(tester, find.text('Projection line'));
      await tester.tap(find.text('Projection line').first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(owner.tree.commentAt(cursor), 'Keep this annotation');
      expect(owner.tree.nodeAt(cursor)!.nags, [1]);
      expect(owner.tree.identity, isNot(same(annotated.identity)));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
