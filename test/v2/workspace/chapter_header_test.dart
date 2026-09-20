import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart'
    show Collision, Conflict, IoFailure, Opened;
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/chapter_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_store.dart';
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

  testWidgets('an undo that could not happen says so', (tester) async {
    await pump(tester);
    edit('one');
    await tester.pumpAndSettle();
    // The store refuses and names the revision the document already has: the
    // entry is out of date and there is nothing to take back through it.
    fixture.store.saves.add(Conflict(scriptedRevision(fixture.onDisk)));
    await tester.tap(find.widgetWithIcon(IconButton, Icons.undo));
    await tester.pumpAndSettle();
    expect(find.text('Nothing to undo right now'), findsOneWidget);
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

  testWidgets('a notice is not carried to the next chapter', (tester) async {
    await conflict(tester);
    await tester.tap(find.text('Save a copy…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Main draft');
    await tester.tap(find.widgetWithText(FilledButton, 'Save a copy'));
    await tester.pumpAndSettle();
    expect(find.text('Saved a copy as Main draft.pgn'), findsOneWidget);
    final other = chapterRef('KID', 'Other');
    fixture.store.documents[other] = Opened(
      whiteChapter,
      scriptedRevision(whiteChapter),
    );
    await fixture.session.open(other);
    await tester.pumpAndSettle();
    expect(find.text('Saved a copy as Main draft.pgn'), findsNothing);
  });

  testWidgets('says when a game could not be read at all', (tester) async {
    fixture.dispose();
    fixture = await openSession(unreadableGameChapter);
    await pump(tester);
    expect(find.text('White · 1 lines, 1 could not be read'), findsOneWidget);
  });
  testWidgets('says when a line could not be read in full', (tester) async {
    fixture.dispose();
    fixture = await openSession(partlyReadChapter);
    await pump(tester);
    expect(find.textContaining('could not be read in full'), findsNothing);
    fixture.session.setComment(NodePath.of([0]), 'mine');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Edit it in the old app.'),
      findsOneWidget,
      reason: 'an edit that quietly does nothing reads as a lost one',
    );
    expect(fixture.onDisk, partlyReadChapter);
  });
}

/// Two games from 1. d4, the second stopped by `--`, a null move this reader
/// cannot play; the moves after it are in the file and not in the tree.
const partlyReadChapter = '''
// Color: White

[Event "A"]
[Result "*"]

1. d4 d5 *

[Event "B"]
[Result "*"]

1. d4 e6 -- 2. c4 *
''';

/// A chapter of two games, the first of which names a position nothing can
/// read.
const unreadableGameChapter = '''
// Color: White

[Event "Broken"]
[FEN "not a fen"]
[Result "*"]

1. e4 *

[Event "Good"]
[Result "*"]

1. d4 d5 *
''';
