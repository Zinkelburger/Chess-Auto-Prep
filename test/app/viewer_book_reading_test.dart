import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/explorer_choice.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/explorer_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

Finder _pane(int index) => find.byKey(ValueKey('action-pane-$index'));

void main() {
  Future<WindowFixture> openViewer(WidgetTester tester) async {
    final app = WindowFixture();
    addTearDown(app.dispose);
    final ref = collectionRef('book');
    app.store.documents[ref] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    await app.pumpShell(tester);
    app.requests.switchTo(Mode.pgnViewer);
    await app.requests.openFile(ref);
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('a file opens as a book: the game headed in its moves, no '
      'tab strip, no buttons over it, and nothing but the counter under '
      'the board', (tester) async {
    await openViewer(tester);
    expect(_pane(0), findsOneWidget);
    expect(_pane(1), findsNothing);
    expect(find.byKey(const ValueKey('tab-row-0')), findsNothing);
    expect(find.text('Carlsen, Magnus – Nakamura, Hikaru'), findsWidgets);
    expect(find.text('Analyze game'), findsNothing);
    expect(find.text('Solitaire'), findsNothing);
    expect(find.text('Notes'), findsNothing);
    expect(find.text('Engine').hitTestable(), findsNothing);
    expect(find.byTooltip('Open tools and arrange panes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Explorer opens under the moves, on This file', (
    tester,
  ) async {
    final app = await openViewer(tester);
    await tester.tap(find.byTooltip('Open tools and arrange panes'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Explorer'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _pane(0), matching: find.text('Moves')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _pane(1), matching: find.text('Explorer')),
      findsOneWidget,
    );
    expect(
      tester.getRect(_pane(0)).bottom,
      lessThanOrEqualTo(tester.getRect(_pane(1)).top),
    );
    final explorer = tester.widget<ExplorerPane>(find.byType(ExplorerPane));
    expect(explorer.explorer.choice.source, ExplorerSource.thisFile);
    expect(explorer.explorer.sources.first, ExplorerSource.thisFile);
    expect(
      app.parts.workspace.explorer.choice.source,
      isNot(ExplorerSource.thisFile),
      reason: 'the other modes keep the database the settings remember',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Solitaire from the Actions opens beside the moves and takes '
      'the board until Esc', (tester) async {
    final app = await openViewer(tester);
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Solitaire chess'));
    await tester.pumpAndSettle();
    expect(_pane(1), findsOneWidget);
    expect(find.text('Start solitaire'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('solitaire-begin')));
    await tester.pumpAndSettle();
    final session = app.parts.session;
    final solitaire = app.parts.workspace.solitaire!;
    expect(solitaire.active, isTrue);
    expect(session.shownTo, isNotNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(solitaire.active, isFalse);
    expect(session.shownTo, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl+E brings the note card to write in, and takes it away '
      'again', (tester) async {
    await openViewer(tester);
    expect(find.byTooltip('Edit notes (Ctrl+E)'), findsNothing);
    expect(find.byTooltip('Done editing (Ctrl+E)'), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Done editing (Ctrl+E)'), findsWidgets);
    await tester.tap(find.byTooltip('Done editing (Ctrl+E)').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Done editing (Ctrl+E)'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
