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
}
