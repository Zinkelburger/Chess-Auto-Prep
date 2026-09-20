import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart'
    show Collision, IoFailure;
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/chapter_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';

void main() {
  late SessionFixture fixture;
  final sicilian = NodePath.of([0]);

  setUp(() async => fixture = await openSession(blackChapter));

  tearDown(() => fixture.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 600));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: ChapterHeader(session: fixture.session, saver: fixture.saver),
        ),
      ),
    );
    await tester.pump();
  }

  void edit(String words) => fixture.session.setComment(sicilian, words);

  testWidgets('names the chapter and says the file is saved', (tester) async {
    await pump(tester);
    expect(find.text('Main'), findsOneWidget);
    expect(
      find.text('Black · 2 lines, 1 from another position'),
      findsOneWidget,
    );
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('a save in flight says so, and then that it is done', (
    tester,
  ) async {
    await pump(tester);
    fixture.store.hold = true;
    edit('one');
    await tester.pump();
    expect(find.text('Saving…'), findsOneWidget);
    fixture.store.releaseAll();
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('a save that failed says what the system said', (tester) async {
    await pump(tester);
    fixture.store.saves.add(const IoFailure('No space left on device'));
    edit('one');
    await tester.pumpAndSettle();
    expect(
      find.text('Could not save: No space left on device'),
      findsOneWidget,
    );
  });

  testWidgets('undo is offered once there is an edit to take back', (
    tester,
  ) async {
    await pump(tester);
    final undo = find.widgetWithIcon(IconButton, Icons.undo);
    expect(find.byTooltip('Undo (Ctrl+Z)'), findsOneWidget);
    expect(tester.widget<IconButton>(undo).onPressed, isNull);
    edit('one');
    await tester.pumpAndSettle();
    await tester.tap(undo);
    await tester.pumpAndSettle();
    expect(fixture.session.commentAt(sicilian), 'The Sicilian [%eval 0.30]');
    expect(find.text('Saved'), findsOneWidget);
  });

  /// Somebody else writes the file, then this window saves over it.
  Future<void> conflict(WidgetTester tester) async {
    fixture.externalEdit('// Color: Black\n\n[Event "Theirs"]\n\n1. e4 *\n');
    await pump(tester);
    edit('mine');
    await tester.pumpAndSettle();
    expect(find.text('The file changed on disk'), findsOneWidget);
  }

  testWidgets('says so and offers the two ways out', (tester) async {
    await conflict(tester);
    expect(find.text('Reload'), findsOneWidget);
    expect(find.text('Save a copy…'), findsOneWidget);
  });

  testWidgets('Reload takes what is on disk', (tester) async {
    await conflict(tester);
    await tester.tap(find.text('Reload'));
    await tester.pumpAndSettle();
    expect(fixture.session.chapter?.tree.children.first.san, 'e4');
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('Save a copy asks for a name and writes one', (tester) async {
    await conflict(tester);
    await tester.tap(find.text('Save a copy…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Main draft');
    await tester.tap(find.widgetWithText(FilledButton, 'Save a copy'));
    await tester.pumpAndSettle();
    expect(find.text('Saved a copy as Main draft.pgn'), findsOneWidget);
    expect(
      fixture.store.documents.keys.map((ref) => ref.path),
      contains('/repertoires/KID/Main draft.pgn'),
    );
  });

  testWidgets('a name already taken replaces nothing and says so', (
    tester,
  ) async {
    await conflict(tester);
    fixture.store.creates.add(const Collision());
    await tester.tap(find.text('Save a copy…'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save a copy'));
    await tester.pumpAndSettle();
    expect(
      find.text('That name is taken. Nothing was replaced.'),
      findsOneWidget,
    );
  });
}
