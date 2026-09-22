import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/settings/settings_navigation.dart';
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
    'native workspace keeps picker filter, builder position and settings owner across modes',
    (tester) async {
      final root = await AppPaths.repertoiresDirectory();
      final folder = await Directory(
        p.join(root.path, 'Workspace ${DateTime.now().microsecondsSinceEpoch}'),
      ).create(recursive: true);
      addTearDown(() => folder.delete(recursive: true));
      final file = File(p.join(folder.path, 'Main.pgn'));
      await file.writeAsString(
        '// Color: White\n\n[Event "Workspace line"]\n\n1. e4 e5 2. Nf3 Nc6 *',
      );
      await pumpApp(tester);
      final app = getAppState(tester);
      app.switchToBuilder(repertoirePath: file.path);
      await ready(tester, find.byType(InteractivePgnEditor));
      final editorState = tester.state(find.byType(InteractivePgnEditor));
      final editor = tester.widget<InteractivePgnEditor>(
        find.byType(InteractivePgnEditor),
      );
      final cursor = editor.currentPath;
      final tree = editor.tree;
      final owner = ViewSettingsRegistry.forApp(
        app,
      ).entries[AppMode.repertoire]?.owner;
      expect(owner, isNotNull);
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose repertoire…'));
      await ready(tester, find.text('Select repertoire'));
      expect(find.text('Actions').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Switch mode').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Settings').hitTestable(), findsOneWidget);
      final search = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Search repertoires',
      );
      await ready(tester, search);
      await tester.enterText(search, 'Workspace');
      await tester.pumpAndSettle();
      app.setMode(AppMode.tactics);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Select repertoire'), findsNothing);
      app.setMode(AppMode.repertoire);
      await ready(tester, find.text('Select repertoire'));
      expect(tester.widget<TextField>(search).controller!.text, 'Workspace');
      expect(
        ViewSettingsRegistry.forApp(app).entries[AppMode.repertoire]?.owner,
        same(owner),
      );
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      expect(find.text('Back to previous view'), findsOneWidget);
      expect(find.text('Plan the lines…'), findsNothing);
      await tester.tap(find.text('Back to previous view'));
      await ready(tester, find.byType(InteractivePgnEditor));
      expect(
        tester.state(find.byType(InteractivePgnEditor)),
        same(editorState),
      );
      final after = tester.widget<InteractivePgnEditor>(
        find.byType(InteractivePgnEditor),
      );
      expect(after.tree, same(tree));
      expect(after.currentPath, cursor);
      expect(await file.readAsString(), contains('Workspace line'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'native creation draft stays beneath the library toolbar across a mode round trip',
    (tester) async {
      await pumpApp(tester);
      getAppState(tester).setMode(AppMode.repertoireLibrary);
      await ready(tester, find.text('Create new repertoire'));
      await tester.tap(find.text('Create new repertoire'));
      await tester.pumpAndSettle();
      final name = find.byKey(const ValueKey('repertoire-create-name'));
      await tester.enterText(name, 'Draft to retain');
      expect(find.text('Actions').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Settings').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Switch mode'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(MenuItemButton, AppMode.tactics.label),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Switch mode'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(MenuItemButton, AppMode.repertoireLibrary.label),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(name).controller!.text,
        'Draft to retain',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Create new repertoire'), findsOneWidget);
      expect(find.text('Draft to retain'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
