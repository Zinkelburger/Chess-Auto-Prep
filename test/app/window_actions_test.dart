// What the window's Actions menu does for the mode on screen: a copy kept
// beside a file this app may write and in the collections folder for one it
// may not, and said either way; the Train tab's gear showing the Training
// settings alone; and no pane splits while the Analysis tab holds a board
// of its own.
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/features/library/library_panel.dart';
import 'package:chess_auto_prep/features/settings/setting_rows.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/app_keys.dart';
import 'package:chess_auto_prep/workspace/action_panes.dart';
import 'package:chess_auto_prep/workspace/workspace_keys.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:fake_async/fake_async.dart';
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

  testWidgets('cancelling Discard changes in Actions keeps both games’ edits '
      'and undo history', (tester) async {
    final ref = collectionRef('games');
    w.store.documents[ref] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    await w.pumpShell(tester);
    w.requests.switchTo(Mode.pgnViewer);
    await w.requests.openFile(ref, game: 0);
    await tester.pumpAndSettle();

    final session = w.session;
    final move = NodePath.of([0]);
    session.setComment(move, 'First game note');
    w.viewer.showGame(1);
    session.setComment(move, 'Second game note');
    await tester.pumpAndSettle();
    expect(session.hasHeldEdits, isTrue);

    await chooseAction(tester, 'Discard changes');
    expect(session.hasHeldEdits, isTrue);
    final cancel = find.widgetWithText(TextButton, 'Cancel');
    expect(cancel, findsOneWidget);
    await tester.tap(cancel);
    await tester.pumpAndSettle();

    expect(session.chapter!.lines[0].text, contains('First game note'));
    expect(session.chapter!.lines[1].text, contains('Second game note'));
    await session.undo();
    expect(session.chapter!.lines[0].text, contains('First game note'));
    expect(session.chapter!.lines[1].text, isNot(contains('Second game note')));
    await session.undo();
    expect(session.chapter!.lines[0].text, isNot(contains('First game note')));
    expect(session.hasHeldEdits, isFalse);
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

  // Hold the Ctrl+N action's async work on its own queue. The window can
  // paint and accept input just as it can during a large chapter's parse.
  FakeAsync startAnalysis(WidgetTester tester) {
    final keys = tester.widget<WorkspaceKeys>(find.byType(WorkspaceKeys));
    final load = FakeAsync();
    load.run((_) => keys.extra[AppKey.analysisBoard.keys.first]!());
    expect(keys.tabs.selected, WorkspaceTab.analysis);
    return load;
  }

  testWidgets('board moves leave the source chapter unchanged while Analysis '
      'loads', (tester) async {
    await w.pumpShell(tester);
    await w.requests.open(kidMain);
    await tester.pumpAndSettle();
    final original = (w.store.documents[kidMain] as Opened).text;
    final e7 = tester.getCenter(find.bySemanticsLabel('e7, Black pawn'));
    final e5 = tester.getCenter(find.bySemanticsLabel('e5, empty'));

    final load = startAnalysis(tester);
    await tester.pump();
    final keys = tester.widget<WorkspaceKeys>(find.byType(WorkspaceKeys));
    expect(keys.tabs.selected, WorkspaceTab.analysis);

    await tester.tapAt(e7);
    await tester.pump();
    await tester.tapAt(e5);
    load.flushMicrotasks();
    await tester.pumpAndSettle();
    await w.saver.flush();
    expect((w.store.documents[kidMain] as Opened).text, original);
  });

  testWidgets('a move completed before the loading frame leaves the source '
      'chapter unchanged', (tester) async {
    await w.pumpShell(tester);
    await w.requests.open(kidMain);
    await tester.pumpAndSettle();
    final e5 = tester.getCenter(find.bySemanticsLabel('e5, empty'));
    await tester.tap(find.bySemanticsLabel('e7, Black pawn'));
    // A destination click also clears the current move's saved board marks.
    w.session.setComment(w.session.cursor.value, '[%cal Ge7e5]');
    await w.saver.flush();
    await tester.pumpAndSettle();
    final original = (w.store.documents[kidMain] as Opened).text;

    final load = startAnalysis(tester);
    await tester.tapAt(e5);
    load.flushMicrotasks();
    await tester.pumpAndSettle();
    await w.saver.flush();
    expect((w.store.documents[kidMain] as Opened).text, original);
    expect(w.parts.workspace.inspection!.active, isTrue);
  });

  testWidgets('an annotation clicked before the Analysis frame leaves the '
      'source move unchanged', (tester) async {
    await w.pumpShell(tester);
    await w.requests.open(kidMain);
    w.session.cursor.goTo(NodePath.of([0]));
    await tester.pumpAndSettle();
    await chooseAction(tester, 'Edit');
    final glyph = tester.getCenter(find.byTooltip('Good move'));
    final original = (w.store.documents[kidMain] as Opened).text;

    final load = startAnalysis(tester);
    await tester.tapAt(glyph);
    load.flushMicrotasks();
    await tester.pumpAndSettle();
    await w.saver.flush();
    expect((w.store.documents[kidMain] as Opened).text, original);
  });

  testWidgets('closing a loading Analysis tab keeps the library filter and '
      'expanded chapter', (tester) async {
    await w.pumpShell(tester);
    final library = find.byType(LibraryPanel);
    final field = find.descendant(
      of: library,
      matching: find.byType(TextField),
    );
    final chapter = find.descendant(of: library, matching: find.text('Main'));
    await tester.enterText(field, 'KID');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(chapter, findsOneWidget);
    await tester.tap(chapter);
    await tester.pumpAndSettle();
    final listTab = find.widgetWithText(TextButton, 'Repertoires');
    if (listTab.evaluate().isNotEmpty) {
      await tester.tap(listTab);
      await tester.pumpAndSettle();
    }

    final load = startAnalysis(tester);
    await tester.pump();
    expect(chapter, findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, 'KID');
    final side = w.session.orientation;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    expect(w.session.orientation, side);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    final keys = tester.widget<WorkspaceKeys>(find.byType(WorkspaceKeys));
    expect(keys.tabs.isOpen(WorkspaceTab.analysis), isFalse);
    load.flushMicrotasks();
    await tester.pumpAndSettle();
    expect(w.parts.workspace.inspection!.active, isFalse);
    expect(chapter, findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, 'KID');
  });

  for (final fromActions in [true, false]) {
    final menu = fromActions ? 'Actions' : 'pane menu';
    testWidgets('the $menu opens Explorer below Moves while Analysis loads', (
      tester,
    ) async {
      await w.pumpShell(tester);
      final ref = collectionRef('analysis');
      w.store.documents[ref] = Opened(
        threeGameFile,
        scriptedRevision(threeGameFile),
      );
      w.requests.switchTo(Mode.pgnViewer);
      await w.requests.openFile(ref, game: 0);
      await tester.pumpAndSettle();
      final load = startAnalysis(tester);
      await tester.pump();
      if (fromActions) {
        await choosePanel(tester, 'Show Explorer');
      } else {
        await tester.tap(find.byTooltip('Open tools and arrange panes'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(MenuItemButton, 'Explorer'));
        await tester.pumpAndSettle();
      }
      load.flushMicrotasks();
      await tester.pumpAndSettle();
      final layout = tester
          .widget<ActionPanes>(find.byType(ActionPanes))
          .layout;
      expect(layout.count, 2);
      expect(layout.pane(0).selected, WorkspaceTab.moves);
      expect(layout.pane(1).selected, WorkspaceTab.explorer);
    });
  }

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
