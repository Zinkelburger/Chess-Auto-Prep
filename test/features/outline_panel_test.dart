// The outline column itself: what a user sees in it and what their clicks
// do. The owners are scripted, so no file is read or written.
import 'package:chess_auto_prep/chess/pgn/chapter_heading.dart';
import 'package:chess_auto_prep/features/library/chapter_outline.dart';
import 'package:chess_auto_prep/features/library/outline_panel.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart'
    show IoFailure, Opened;
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';

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

  testWidgets('a chapter that starts after some moves says so under its '
      'name, and a draft says Proposed', (tester) async {
    fixture = await openLibrary(
      [
        RepertoireFolder(
          name: 'KID',
          path: '/repertoires/KID',
          modified: DateTime.now(),
          chapters: [
            main,
            ChapterRef(
              repertoire: 'KID',
              name: 'Gambit',
              path: '/repertoires/KID/Gambit.pgn',
              heading: const ChapterHeading(
                rootMoves: ['e4', 'e5', 'f4'],
                draft: true,
              ),
            ),
          ],
        ),
      ],
      text: twoLines,
      open: main,
    );
    outline = ChapterOutline(
      library: fixture.library,
      session: fixture.session,
      debounce: Duration.zero,
    );
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
              onOpen: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1.e4 e5 2.f4'), findsOneWidget);
    expect(find.text('Proposed'), findsOneWidget);
    expect(
      tester
          .getSize(
            find
                .ancestor(
                  of: find.text('Gambit'),
                  matching: find.byType(InkWell),
                )
                .first,
          )
          .height,
      outlineRowHeight + outlineRootHeight,
    );
  });

  testWidgets('rooted chapter rows grow with text and reveal their full name', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    const name = "King's Indian Defence — Classical main line with 9.Ne1";
    const chapter = ChapterRef(
      repertoire: 'KID',
      name: name,
      path: '/repertoires/KID/long.pgn',
      heading: ChapterHeading(rootMoves: ['d4', 'Nf6', 'c4', 'g6']),
    );
    ChapterRef? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: listColumnWidth,
              child: ChapterRow(
                chapter: const OutlineChapter(ref: chapter, open: true),
                onOpen: (ref) => picked = ref,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final row = tester.getRect(find.byType(ChapterRow));
    final root = tester.getRect(find.text(chapter.heading.rootText));
    expect(row.bottom, greaterThanOrEqualTo(root.bottom));
    expect(row.height, greaterThan(outlineRowHeight + outlineRootHeight));
    await tester.longPress(find.text(name));
    await tester.pumpAndSettle();
    expect(find.text(name), findsNWidgets(2));
    await tester.tap(find.byType(ChapterRow));
    expect(picked, chapter);
  });

  testWidgets('line names and moves are available beyond a compact rail', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    const name = "Queen's Gambit Declined — exchange variation development";
    await show(tester, text: twoLines.replaceFirst("Queen's", name));
    final line = find.ancestor(
      of: find.text(name),
      matching: find.byType(LineRow),
    );
    expect(line, findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip(name), findsOneWidget);
    await tester.longPress(find.text(name));
    await tester.pumpAndSettle();
    expect(find.text(name), findsNWidgets(2));
  });

  testWidgets('the ⋯ menu moves a line to a chapter picked by name', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byTooltip('Actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to chapter…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sidelines').last);
    await tester.pumpAndSettle();
    await fixture.saver.flush();
    expect(
      fixture.textAt('/repertoires/KID/Main.pgn'),
      isNot(contains('Indian')),
    );
    expect(
      fixture.textAt('/repertoires/KID/Sidelines.pgn'),
      contains('[Event "Indian"]'),
    );
  });

  testWidgets('a line move that keeps failing can be discarded', (
    tester,
  ) async {
    await show(tester);
    fixture.store.saves.add(const IoFailure('read-only disk'));
    await tester.tap(find.byTooltip('Actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to chapter…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sidelines').last);
    await tester.pumpAndSettle();
    expect(find.text('Retry line move'), findsOneWidget);

    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Retry line move'), findsNothing);
    expect(fixture.library.hasPendingLineMove, isFalse);
  });

  testWidgets('the ⋯ menu moves a line to a new chapter named there', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byTooltip('Actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to chapter…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New chapter…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Indian');
    await tester.tap(find.text('Move'));
    await tester.pumpAndSettle();
    await fixture.saver.flush();
    expect(
      fixture.textAt('/repertoires/KID/Main.pgn'),
      isNot(contains('Indian"]')),
    );
    expect(
      fixture.textAt('/repertoires/KID/Indian.pgn'),
      contains('1. d4 Nf6 *'),
    );
  });

  testWidgets('At this position lists only the lines through the board', (
    tester,
  ) async {
    await show(tester);
    fixture.session.goTo(outline.lines.first.at);
    await tester.tap(find.byTooltip('At this position'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nf6'), findsNothing);
    expect(find.textContaining('d5'), findsOneWidget);
    fixture.session.toStart();
    await tester.pumpAndSettle();
    expect(find.textContaining('Nf6'), findsOneWidget);
    expect(find.textContaining('d5'), findsOneWidget);
    await tester.tap(find.byTooltip('At this position'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nf6'), findsOneWidget);
  });

  testWidgets('a line dragged onto another chapter moves there', (
    tester,
  ) async {
    await show(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.textContaining('Nf6')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(tester.getCenter(find.text('Sidelines')));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    await fixture.saver.flush();
    expect(
      fixture.textAt('/repertoires/KID/Main.pgn'),
      isNot(contains('Indian')),
    );
    expect(
      fixture.textAt('/repertoires/KID/Sidelines.pgn'),
      contains('[Event "Indian"]'),
    );
  });

  testWidgets('a line dragged onto another line folds into it', (tester) async {
    await show(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.textContaining('Nf6')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(
      tester.getCenter(find.textContaining('1.d4 d5 2.c4 e6')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    await fixture.saver.flush();
    expect(
      fixture.textAt('/repertoires/KID/Main.pgn'),
      contains('1. d4 d5 (1... Nf6) 2. c4 e6 *'),
    );
  });

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

  testWidgets('deleting a line says nothing and undo puts it back', (
    tester,
  ) async {
    await show(tester);

    await tester.tap(find.byTooltip('Actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete line'));
    await tester.pumpAndSettle();

    expect(find.text('Indian'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);

    await fixture.session.undo();
    await tester.pumpAndSettle();

    expect(find.text('Indian'), findsOneWidget);
    expect(fixture.textAt(main.path), twoLines);
  });

  testWidgets('a delete that was refused leaves the line', (tester) async {
    await show(tester);
    fixture.store.documents[main] = Opened(
      twoLines,
      scriptedRevision(twoLines),
      readOnly: 'it is not UTF-8',
    );
    await fixture.session.open(main);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete line'));
    await tester.pumpAndSettle();

    expect(find.text('Indian'), findsOneWidget);
  });

  testWidgets('the search narrows the rows and says when nothing matches', (
    tester,
  ) async {
    await show(tester);

    await tester.enterText(find.byType(TextField), 'indian');
    await tester.pumpAndSettle();
    expect(find.text("Queen's"), findsNothing);
    expect(find.text('Indian'), findsNWidgets(2));

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
