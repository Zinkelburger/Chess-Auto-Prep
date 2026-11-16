// What the window's Actions menu does for the mode on screen: a copy kept
// beside a file this app may write and in the collections folder for one it
// may not, and said either way; the Train tab's gear showing the Training
// settings alone; and no pane splits while the Analysis tab holds a board
// of its own.
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/features/settings/setting_rows.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  /// Actions ▸ Save a copy…, named [name].
  Future<void> saveCopy(WidgetTester tester, String name) async {
    await chooseAction(tester, 'Save a copy…');
    await tester.enterText(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      ),
      name,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save a copy'));
    await tester.pumpAndSettle();
  }

  Iterable<String> paths() => w.store.documents.keys.map((ref) => ref.path);

  testWidgets('a copy of a chapter goes beside it, and is said', (
    tester,
  ) async {
    await w.pumpShell(tester);
    await w.requests.open(kidMain);
    await tester.pumpAndSettle();
    await saveCopy(tester, 'Spare');
    expect(paths(), contains('/repertoires/KID/Spare.pgn'));
    expect(w.requests.status, isNotNull);
    expect(w.requests.statusIsProblem, isFalse);
  });

  testWidgets('a copy of a file it may not write goes in the collections', (
    tester,
  ) async {
    final ref = collectionRef('outside');
    w.store.documents[ref] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
      readOnly: 'outside Documents',
    );
    await w.pumpShell(tester);
    w.requests.switchTo(Mode.repertoires);
    await w.requests.open(ref);
    await tester.pumpAndSettle();
    expect(w.session.readOnly, isNotNull);
    await saveCopy(tester, 'Spare');
    final collections = w.parts.documents.viewer.collections;
    expect(paths(), contains('$collections/Spare.pgn'));
  });

  testWidgets("the Train tab's gear shows the Training settings alone", (
    tester,
  ) async {
    w.dispose();
    w = WindowFixture(
      settingRows: () => const [
        SettingGroup('Look', []),
        SettingGroup('Training', []),
      ],
    );
    await w.pumpShell(tester);
    await w.requests.open(kidMain);
    w.requests.switchTo(Mode.trainer);
    await tester.pumpAndSettle();
    if (find.byTooltip('Training actions').evaluate().isEmpty) {
      await tester.tap(find.text('Train'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('Training actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Training settings…'));
    await tester.pumpAndSettle();
    expect(find.text('Training'), findsWidgets);
    expect(find.text('Look'), findsNothing);
  });

  testWidgets('no pane splits while the Analysis tab holds its own board', (
    tester,
  ) async {
    await w.pumpShell(tester);
    await w.requests.open(kidMain);
    await tester.pumpAndSettle();
    Future<bool> offersSplit() async {
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      final view = find.widgetWithText(SubmenuButton, 'View');
      await tester.ensureVisible(view);
      await tester.tap(view);
      await tester.pumpAndSettle();
      final offered = find.text('Split right').evaluate().isNotEmpty;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      return offered;
    }

    expect(await offersSplit(), isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(w.parts.workspace.inspection!.active, isTrue);
    expect(await offersSplit(), isFalse);
  });
}
