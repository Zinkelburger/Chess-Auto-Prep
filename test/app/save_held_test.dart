// Save with moves held back: a file this app may write takes them without
// a question; one it may not asks where they go instead.
import 'package:chess_auto_prep/app/save_held.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
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
        navigatorKey: w.navigator,
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

  Future<ChapterRef> annotateSecondGame() async {
    final ref = collectionRef('Weekend');
    w.store.documents[ref] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
      readOnly: 'outside Documents',
    );
    await w.requests.openFile(ref, game: 1);
    w.session
      ..holdsEdits = true
      ..setComment(NodePath.of([0]), 'Remember this reply');
    expect(w.session.chapter!.lines[1].text, contains('Remember this reply'));
    return ref;
  }

  testWidgets('switching games during either dialog keeps the whole copy', (
    tester,
  ) async {
    final ref = await annotateSecondGame();
    final edited = writeChapter(w.session.chapter!);
    await save(tester);
    w.viewer.showGame(2);
    expect(w.session.game, 2);
    await tester.tap(find.text('Copy into Documents…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Weekend notes');
    await w.requests.openFile(ref);
    expect(w.session.game, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Save a copy'));
    await tester.pumpAndSettle();

    final copy = w.store.documents[collectionRef('Weekend notes')] as Opened;
    expect(copy.text, edited);
  });

  testWidgets('a study cannot take the newly displayed game', (tester) async {
    final ref = await annotateSecondGame();
    await save(tester);
    await w.requests.openFile(ref);
    expect(w.session.game, 0);
    await tester.tap(find.text('Add to a study…'));
    await tester.pumpAndSettle();
    expect(find.text('Add to study'), findsNothing);
  });

  testWidgets('a pending copy never saves the PGN opened from the desktop', (
    tester,
  ) async {
    final original = ChapterRef.at('/Downloads/Weekend.pgn');
    w.store.documents[original] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
      readOnly: 'outside Documents',
    );
    await w.settings.update(
      w.settings.value.copyWith(copyFilesIntoDocuments: false),
    );
    await w.requests.openFile(original);
    w.session
      ..holdsEdits = true
      ..setComment(NodePath.of([0]), 'My weekend preparation');
    expect(w.session.hasHeldEdits, isTrue);
    final editedPgn = writeChapter(w.session.chapter!);

    await save(tester);
    await tester.tap(find.text('Copy into Documents…'));
    await tester.pumpAndSettle();
    const name = 'Weekend annotated';
    await tester.enterText(find.byType(TextField), name);
    final confirm = find.widgetWithText(FilledButton, 'Save a copy');
    expect(confirm, findsOneWidget);

    // The desktop file-open callback uses this route even with a dialog up.
    await w.requests.openFile(kidMain);
    expect(w.session.source, kidMain);
    await tester.pumpAndSettle();
    if (confirm.evaluate().isNotEmpty) {
      await tester.tap(confirm);
      await tester.pumpAndSettle();
    }

    final copy = w.store.documents[collectionRef(name)];
    expect(
      copy,
      anyOf(
        isNull,
        isA<Opened>().having((file) => file.text, 'PGN', editedPgn),
      ),
      reason: 'Any copy under this name must contain the original held edits.',
    );
  });
}
