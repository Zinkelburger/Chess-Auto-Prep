// The outline column itself: what a user sees in it and what their clicks
// do. The owners are scripted, so no file is read or written.
import 'package:chess_auto_prep/v2/features/library/chapter_outline.dart';
import 'package:chess_auto_prep/v2/workspace/chapter_commands.dart';
import 'package:chess_auto_prep/v2/features/library/outline_panel.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';

const twoLines = '''
// Book
// Color: White

[Event "Queen's"]
[Result "*"]

1. d4 d5 2. c4 e6 *

[Event "Indian"]
[Result "*"]

1. d4 Nf6 *
''';

void main() {
  late LibraryFixture fixture;
  late ChapterOutline outline;
  late List<ChapterRef> opened;
  final main = ref('KID', 'Main');

  Future<void> show(WidgetTester tester, {String text = twoLines}) async {
    fixture = await openLibrary(
      [
        folder('KID', ['Main', 'Sidelines']),
      ],
      text: text,
      open: main,
    );
    outline = ChapterOutline(
      library: fixture.library,
      session: fixture.session,
      debounce: Duration.zero,
    );
    opened = [];
    addTearDown(() {
      outline.dispose();
      fixture.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SizedBox(
            width: outlineColumnWidth,
            child: OutlinePanel(
              outline: outline,
              library: fixture.library,
              session: fixture.session,
              onOpen: opened.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the chapters and the open chapter’s lines', (
    tester,
  ) async {
    await show(tester);

    expect(find.text('Chapters'), findsOneWidget);
    expect(find.text('Main'), findsOneWidget);
    expect(find.text('Sidelines'), findsOneWidget);
    expect(find.text('2 lines'), findsOneWidget);
    expect(find.text("Queen's"), findsOneWidget);
    expect(find.text('…1...Nf6'), findsOneWidget);
  });

  testWidgets('clicking a chapter asks the host to open it', (tester) async {
    await show(tester);

    await tester.tap(find.text('Sidelines'));

    expect(opened.single.name, 'Sidelines');
  });

  testWidgets('clicking a line puts the cursor on its last move', (
    tester,
  ) async {
    await show(tester);

    await tester.tap(find.text('Indian'));
    await tester.pump();

    expect(fixture.session.currentMove!.san, 'Nf6');
  });

  testWidgets('renaming a line from its menu writes the new name', (
    tester,
  ) async {
    await show(tester);

    await tester.tap(find.byTooltip('Actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename line…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Exchange');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(find.text('Exchange'), findsOneWidget);
    expect(fixture.textAt(main.path), contains('[Event "Exchange"]'));
  });

  testWidgets('deleting a line offers the way back', (tester) async {
    await show(tester);

    await tester.tap(find.byTooltip('Actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete line'));
    await tester.pumpAndSettle();

    expect(find.text('Indian'), findsNothing);
    expect(find.text('Deleted 1 line.'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(find.text('Indian'), findsOneWidget);
    expect(fixture.textAt(main.path), twoLines);
  });

  testWidgets('the next edit takes the offer of undo away', (tester) async {
    await show(tester);

    await tester.tap(find.byTooltip('Actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete line'));
    await tester.pumpAndSettle();
    expect(find.text('Deleted 1 line.'), findsOneWidget);

    // Something else is written while the offer is still up. Undo steps back
    // one version, so the offer would now take that back instead.
    renameLine(fixture.session, 0, 'Exchange');
    await tester.pumpAndSettle();

    expect(find.text('Deleted 1 line.'), findsNothing);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('the search narrows the rows and says when nothing matches', (
    tester,
  ) async {
    await show(tester);

    await tester.enterText(find.byType(TextField), 'indian');
    await tester.pumpAndSettle();
    expect(find.text("Queen's"), findsNothing);
    expect(find.text('Indian'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'benoni');
    await tester.pumpAndSettle();
    expect(find.text('No chapter or line matches "benoni".'), findsOneWidget);
  });

  testWidgets('a chapter with no lines says so', (tester) async {
    await show(tester, text: '// Book\n// Color: White\n\n');

    expect(
      find.text('Empty — add lines to fill this chapter.'),
      findsOneWidget,
    );
  });

  testWidgets('a new chapter can be made from the column', (tester) async {
    await show(tester);

    await tester.tap(find.byTooltip('New chapter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Advance');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(fixture.textAt('/repertoires/KID/Advance.pgn'), isNotNull);
  });
}
