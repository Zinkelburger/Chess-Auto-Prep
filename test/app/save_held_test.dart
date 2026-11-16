// Save with moves held back: a file this app may write takes them without
// a question; one it may not asks where they go instead.
import 'package:chess_auto_prep/app/save_held.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  Future<void> save(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => saveHeld(
              context,
              session: w.session,
              requests: w.requests,
              collections: w.parts.env.folders.collections,
            ),
            child: const Text('Save'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
  }

  testWidgets('a file it may write takes the moves, asking nothing', (
    tester,
  ) async {
    await w.requests.open(kidMain);
    w.session
      ..holdsEdits = true
      ..cursor.toEnd()
      ..playMove('f3d4');
    expect(w.session.hasHeldEdits, isTrue);
    await save(tester);
    expect(find.text('Save your moves'), findsNothing);
    expect(w.session.hasHeldEdits, isFalse);
  });

  testWidgets('a file it may not write asks where the moves go', (
    tester,
  ) async {
    final ref = collectionRef('outside');
    w.store.documents[ref] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
      readOnly: 'outside Documents',
    );
    await w.requests.openFile(ref);
    expect(w.session.readOnly, isNotNull);
    await save(tester);
    expect(find.text('Save your moves'), findsOneWidget);
    await tester.tap(find.text('Copy into Documents…'));
    await tester.pumpAndSettle();
    expect(find.text('File name'), findsOneWidget, reason: 'the copy is named');
  });
}
