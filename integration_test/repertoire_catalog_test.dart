/// Native catalog journey using the production composition root and disposable
/// runner profile: create, search, rename, reopen, delete and inspect recovery.
library;

import 'dart:io';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/board_helpers.dart';
import 'helpers/tactics_helpers.dart';

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('catalog create, search, rename, restart and recoverable delete', (
    tester,
  ) async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final originalName = 'Renewal catalog $suffix';
    final renamedName = 'Renewed catalog $suffix';
    await pumpApp(tester);
    getAppState(tester).setMode(AppMode.repertoireLibrary);
    await waitFor(tester, find.text('Create new repertoire'));
    await tester.tap(find.text('Create new repertoire'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('repertoire-create-name')),
      originalName,
    );
    await tester.tap(find.text('Empty repertoire'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create repertoire'));
    await waitFor(tester, find.widgetWithText(ListTile, originalName));

    final root = await AppPaths.repertoiresDirectory();
    final original = File(p.join(root.path, originalName, 'Main.pgn'));
    final bytes = await original.readAsBytes();
    expect(bytes, isNotEmpty);
    final search = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'Search repertoires',
    );
    await tester.enterText(search, 'missing');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches "missing".'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text(originalName),
          matching: find.byType(ListTile),
        ),
        matching: find.byTooltip('Rename repertoire'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      renamedName,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await waitFor(tester, find.widgetWithText(ListTile, renamedName));
    expect(await original.exists(), isFalse);
    final renamed = File(p.join(root.path, renamedName, 'Main.pgn'));
    expect(await renamed.readAsBytes(), bytes);
    await tester.tap(find.text(renamedName));
    await waitFor(tester, find.text('Organize your repertoire'));
    await tester.tap(find.byTooltip('All repertoires'));
    await waitFor(tester, find.widgetWithText(ListTile, renamedName));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpApp(tester);
    getAppState(tester).setMode(AppMode.repertoireLibrary);
    await waitFor(tester, find.widgetWithText(ListTile, renamedName));
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text(renamedName),
          matching: find.byType(ListTile),
        ),
        matching: find.byTooltip('Delete repertoire'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Delete'),
      ),
    );
    for (
      var i = 0;
      i < 100 && find.text(renamedName).evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text(renamedName), findsNothing);
    expect(await renamed.exists(), isFalse);
    final documents = await AppPaths.documentsDirectory();
    final trash = Directory(
      p.join(documents.path, '.chess_auto_prep_trash', 'repertoires'),
    );
    final receipt = (await IOStorageService().listRepertoireRecovery())
        .singleWhere((entry) => entry.name == renamedName);
    expect(
      await File(p.join(trash.path, receipt.id, 'Main.pgn')).readAsBytes(),
      bytes,
    );

    // Simulate a newer repertoire taking the old name before reopening recovery.
    await renamed.parent.create();
    await renamed.writeAsString('newer repertoire');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpApp(tester);
    getAppState(tester).setMode(AppMode.repertoireLibrary);
    await waitFor(tester, find.text('Recovery'));
    await tester.tap(find.text('Recovery'));
    await waitFor(tester, find.text('Repertoire recovery'));
    final row = find.widgetWithText(ListTile, renamedName);
    await tester.tap(find.descendant(of: row, matching: find.text('Restore')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();
    expect(
      find.text('A repertoire with this name already exists.'),
      findsOneWidget,
    );
    final restoredName = 'Restored catalog $suffix';
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      restoredName,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    for (var i = 0; i < 100 && row.evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(row, findsNothing);
    expect(await renamed.readAsString(), 'newer repertoire');
    final restoredFile = File(p.join(root.path, restoredName, 'Main.pgn'));
    expect(await restoredFile.readAsBytes(), bytes);
    await tester.tap(find.text('Back to library'));
    await waitFor(tester, find.widgetWithText(ListTile, restoredName));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpApp(tester);
    getAppState(tester).setMode(AppMode.repertoireLibrary);
    await waitFor(tester, find.widgetWithText(ListTile, restoredName));
    expect(await restoredFile.readAsBytes(), bytes);
    expect(tester.takeException(), isNull);
  });
}
