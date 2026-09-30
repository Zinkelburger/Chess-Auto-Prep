import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

void main() {
  testWidgets('the viewer heads a game with Edit, Analyze game and Solitaire; '
      'solitaire takes the board\'s moves until Esc', (tester) async {
    final app = WindowFixture();
    addTearDown(app.dispose);
    final ref = collectionRef('bar');
    app.store.documents[ref] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    await app.pumpShell(tester);
    app.requests.switchTo(Mode.pgnViewer);
    await app.requests.openFile(ref);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('viewer-edit')), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-analyze')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('viewer-edit')));
    await tester.pumpAndSettle();
    expect(find.text('Done editing'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('viewer-edit')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('viewer-solitaire')));
    await tester.pumpAndSettle();
    expect(find.text('Start solitaire'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('solitaire-begin')));
    await tester.pumpAndSettle();
    final session = app.parts.session;
    final solitaire = app.parts.workspace.solitaire!;
    expect(solitaire.active, isTrue);
    expect(session.shownTo, isNotNull);
    expect(find.text('Stop solitaire'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(solitaire.active, isFalse);
    expect(session.shownTo, isNull);
    expect(tester.takeException(), isNull);
  });
}
