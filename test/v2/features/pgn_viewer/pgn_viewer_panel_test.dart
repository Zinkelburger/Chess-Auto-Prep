import 'package:chess_auto_prep/v2/features/pgn_viewer/pgn_viewer_panel.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/recent_pgn_files.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/viewer_fixture.dart';

void main() {
  late ViewerFixture fixture;
  late List<ChapterRef> opened;
  var browsed = 0;

  tearDown(() => fixture.dispose());

  Future<void> pump(WidgetTester tester) async {
    opened = [];
    browsed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SizedBox(
            width: libraryPanelWidth,
            child: PgnViewerPanel(
              viewer: fixture.viewer,
              filter: fixture.filter,
              onOpen: opened.add,
              onBrowse: () => browsed++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('with nothing open, the recent files are offered', (
    tester,
  ) async {
    fixture = await viewerOver(
      threeGameFile,
      recent: const RecentFilesListed(['/home/me/Downloads/twic.pgn']),
    );
    await pump(tester);
    expect(find.text('Recent files'), findsOneWidget);
    expect(find.text('twic.pgn'), findsOneWidget);
    expect(find.text('/home/me/Downloads'), findsOneWidget);
    expect(find.byTooltip('Open PGN file… (Ctrl+O)'), findsOneWidget);
    await tester.tap(find.text('twic.pgn'));
    expect(opened, [ChapterRef.at('/home/me/Downloads/twic.pgn')]);
  });

  testWidgets('with no recent files, the panel says so and offers the dialog', (
    tester,
  ) async {
    fixture = await viewerOver(threeGameFile);
    await pump(tester);
    expect(find.textContaining('No PGN open'), findsOneWidget);
    await tester.tap(find.text('Open PGN file…'));
    await tester.pumpAndSettle();
    expect(browsed, 1);
    await tester.tap(find.byTooltip('Open PGN file… (Ctrl+O)'));
    expect(browsed, 2);
  });

  testWidgets('an open file lists its games, and a click shows one', (
    tester,
  ) async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    await pump(tester);
    expect(find.text('games'), findsOneWidget);
    expect(find.text('Carlsen, Magnus – Nakamura, Hikaru'), findsOneWidget);
    expect(find.text('½-½'), findsOneWidget);
    await tester.tap(find.text('Ding, Liren – Giri, Anish'));
    await tester.pumpAndSettle();
    expect(fixture.session.game, 1);
  });

  testWidgets('the search narrows the list and says when nothing matches', (
    tester,
  ) async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'giri');
    await tester.pumpAndSettle();
    expect(find.text('Ding, Liren – Giri, Anish'), findsOneWidget);
    expect(find.text('Club night'), findsNothing);
    await tester.enterText(find.byType(TextField), 'fischer');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches "fischer".'), findsOneWidget);
  });

  // Under 64 KiB, so the file is read on this isolate: a widget test's
  // clock is fake, and a read on another isolate would never come back.
  testWidgets('a long file lists only the rows on screen', (tester) async {
    final games = StringBuffer();
    for (var i = 1; i <= 400; i++) {
      games.write(
        '[Event "Round $i"]\n[White "A$i"]\n[Black "B$i"]\n\n1. e4 *\n\n',
      );
    }
    fixture = await viewerOver(games.toString());
    await fixture.open();
    await pump(tester);
    expect(find.text('A1 – B1'), findsOneWidget);
    expect(find.text('A300 – B300'), findsNothing);
  });

  testWidgets('a course lists its lines under foldable chapters, the open '
      "game's chapter unfolded, each line by its own title", (tester) async {
    fixture = await viewerOver(courseFile);
    await fixture.open();
    await pump(tester);
    expect(find.text('Italian'), findsOneWidget);
    expect(find.text('2 games'), findsNWidgets(2));
    expect(find.text('Main line'), findsOneWidget);
    expect(find.text('Two Knights'), findsOneWidget);
    expect(find.text('Sicilian'), findsOneWidget);
    expect(find.text('Najdorf'), findsNothing, reason: 'folded');
    await tester.tap(find.text('Sicilian'));
    await tester.pumpAndSettle();
    expect(find.text('Najdorf'), findsOneWidget);
    await tester.tap(find.text('Najdorf'));
    await tester.pumpAndSettle();
    expect(fixture.session.game, 2);
    expect(find.text('Main line'), findsOneWidget, reason: 'stays open');
    await tester.tap(find.text('Italian'));
    await tester.pumpAndSettle();
    expect(find.text('Main line'), findsNothing);
  });

  testWidgets('a study chapter of one game is that game\'s row', (
    tester,
  ) async {
    fixture = await viewerOver(studyFile);
    await fixture.open();
    await pump(tester);
    expect(find.text('Chapter one'), findsOneWidget);
    expect(find.text('Chapter two'), findsOneWidget);
    expect(find.text('1 game'), findsNothing);
    await tester.tap(find.text('Chapter two'));
    await tester.pumpAndSettle();
    expect(fixture.session.game, 1);
  });

  testWidgets('the search unfolds the chapters it finds lines in', (
    tester,
  ) async {
    fixture = await viewerOver(courseFile);
    await fixture.open();
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'najdorf');
    await tester.pumpAndSettle();
    expect(find.text('Sicilian'), findsOneWidget);
    expect(find.text('Najdorf'), findsOneWidget);
    expect(find.text('Italian'), findsNothing);
  });
}

/// A course export: the chapter in `White`, the line's title in `Black`.
const courseFile = """
[Event "Course"]
[White "Italian"]
[Black "Main line"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 *

[Event "Course"]
[White "Italian"]
[Black "Two Knights"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 *

[Event "Course"]
[White "Sicilian"]
[Black "Najdorf"]
[Result "*"]

1. e4 c5 2. Nf3 d6 *

[Event "Course"]
[White "Sicilian"]
[Black "Dragon"]
[Result "*"]

1. e4 c5 2. Nf3 g6 *
""";

/// A Lichess study export: one game a chapter, named in `ChapterName`.
const studyFile = """
[Event "My study: Chapter one"]
[ChapterName "Chapter one"]
[Result "*"]

1. d4 d5 *

[Event "My study: Chapter two"]
[ChapterName "Chapter two"]
[Result "*"]

1. c4 e5 *
""";
