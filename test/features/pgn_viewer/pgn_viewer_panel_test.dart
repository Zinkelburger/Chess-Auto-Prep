import 'package:chess_auto_prep/chess/game_filter.dart';
import 'package:chess_auto_prep/chess/pgn/collection_player.dart';
import 'package:chess_auto_prep/chess/pgn/reading_place.dart';
import 'package:chess_auto_prep/storage/viewer_places.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:chess_auto_prep/features/pgn_viewer/pgn_viewer_panel.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/recent_pgn_files.dart';
import 'package:chess_auto_prep/ui/search_field.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter_test/flutter_test.dart';

import '../../support/viewer_fixture.dart';

/// The search box over the games, beside the other boxes of the column.
final _searchBox = find.descendant(
  of: find.byType(SearchField),
  matching: find.byType(TextField),
);

/// About as wide as the list pane opens.
const _panelWidth = 300.0;

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
            width: _panelWidth,
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

  testWidgets('the follow box follows a player once one is picked or '
      'submitted, never a name half typed', (tester) async {
    final places = _Places();
    fixture = await viewerOver(_carlsenGames, places: places);
    await fixture.open();
    await pump(tester);
    final box = find.descendant(
      of: find.byKey(const ValueKey('follow-player')),
      matching: find.byType(TextField),
    );
    expect(fixture.viewer.followed, 'Carlsen, Magnus');

    await tester.tap(box);
    await tester.enterText(box, 'Nak');
    await tester.pump();
    expect(fixture.viewer.followed, 'Carlsen, Magnus');
    expect(fixture.session.orientation, Side.white);
    // Enter picks the one suggestion left.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(fixture.viewer.followed, 'Nakamura, Hikaru');
    expect(fixture.session.orientation, Side.black);

    // A name the file's list does not suggest is followed on Enter.
    await tester.enterText(box, 'Someone Else');
    await tester.pump();
    expect(fixture.viewer.followed, 'Nakamura, Hikaru');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(fixture.viewer.followed, 'Someone Else');

    // Cleared, then Enter: nobody.
    await tester.enterText(box, '');
    await tester.pump();
    expect(fixture.viewer.followed, 'Someone Else');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(fixture.viewer.followed, isNull);

    await tester.runAsync(pumpEventQueue);
    expect(places.perspectives, contains(const FollowPlayer('Someone Else')));
    expect(
      places.perspectives,
      everyElement(
        isIn(const [
          FollowCollectionPlayer(),
          FollowPlayer('Nakamura, Hikaru'),
          FollowPlayer('Someone Else'),
          FollowNobody(),
        ]),
      ),
      reason: 'no half-typed name is kept for the file',
    );
  });

  testWidgets('search matches a chapter name', (tester) async {
    fixture = await viewerOver(courseFile);
    await fixture.open();
    await pump(tester);
    await tester.enterText(_searchBox, 'sicilian');
    await tester.pumpAndSettle();
    expect(fixture.viewer.chapters, hasLength(1));
    expect(find.text('Najdorf'), findsOneWidget);
  });

  testWidgets('new file clears displayed search', (tester) async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    await pump(tester);
    await tester.enterText(_searchBox, 'giri');
    await tester.pumpAndSettle();
    await fixture.open();
    await tester.pumpAndSettle();
    expect(fixture.viewer.query, isEmpty);
    expect(tester.widget<TextField>(_searchBox).controller!.text, isEmpty);
  });

  testWidgets('search reveals an explicitly folded chapter', (tester) async {
    fixture = await viewerOver(courseFile);
    await fixture.open();
    await pump(tester);
    await tester.tap(find.text('Italian'));
    await tester.pumpAndSettle();
    await tester.enterText(_searchBox, 'knights');
    await tester.pumpAndSettle();
    expect(find.text('Two Knights'), findsOneWidget);
  });

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
    await tester.enterText(_searchBox, 'giri');
    await tester.pumpAndSettle();
    expect(find.text('Ding, Liren – Giri, Anish'), findsOneWidget);
    expect(find.text('Club night'), findsNothing);
    await tester.enterText(_searchBox, 'fischer');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches "fischer".'), findsOneWidget);
  });

  testWidgets('Filter games unfolds a Field / Rule / Value row; a rule '
      'narrows the list and folds to a chip that removes it', (tester) async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    await pump(tester);
    expect(find.text('Field'), findsNothing, reason: 'folded');
    await tester.tap(find.text('Filter games'));
    await tester.pumpAndSettle();
    expect(find.text('Player'), findsOneWidget, reason: 'one blank row');
    expect(find.text('contains'), findsOneWidget);
    final value = find.widgetWithText(TextField, 'Value');
    await tester.enterText(value, 'Carlsen');
    await tester.pumpAndSettle();
    expect(find.text('Carlsen, Magnus – Nakamura, Hikaru'), findsWidgets);
    expect(find.text('Ding, Liren – Giri, Anish'), findsNothing);
    expect(find.text('1 of 3'), findsOneWidget);
    await tester.tap(find.text('Filter games'));
    await tester.pumpAndSettle();
    expect(find.text('Player contains Carlsen'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove this rule'));
    await tester.pumpAndSettle();
    expect(find.text('Ding, Liren – Giri, Anish'), findsOneWidget);
    expect(fixture.filter.narrowing, isFalse);
  });

  testWidgets('a Moves rule takes a move sequence and narrows the list to '
      'the games that play it', (tester) async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    await pump(tester);
    await tester.tap(find.text('Filter games'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Player'), 'Moves');
    await tester.pumpAndSettle();
    final sequence = find.widgetWithText(TextField, 'e4 c5 … Nf3');
    expect(sequence, findsOneWidget, reason: 'the value box shows the form');
    await tester.enterText(sequence, '1.d4 … c4');
    await tester.pump(const Duration(milliseconds: 400));
    // The worker answers on the real clock; its answer lands on a pump.
    for (var i = 0; i < 500 && fixture.filter.busy; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('Ding, Liren – Giri, Anish'), findsWidgets);
    expect(find.text('Club night'), findsNothing);
    expect(find.text('1 of 3'), findsOneWidget);
  });

  testWidgets('a filter nothing passes says so and offers every game back', (
    tester,
  ) async {
    fixture = await viewerOver(threeGameFile);
    await fixture.open();
    fixture.filter.apply(
      const GameFilter(rules: [HeaderRule(value: 'Fischer')]),
    );
    await pump(tester);
    expect(find.text('No games match the filter.'), findsOneWidget);
    await tester.tap(find.text('Show all games'));
    await tester.pumpAndSettle();
    expect(find.text('Club night'), findsOneWidget);
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
    await tester.enterText(_searchBox, 'najdorf');
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

/// Three games of Carlsen's, as White, Black and White.
const _carlsenGames = '''
[Event "Open"]
[White "Carlsen, Magnus"]
[Black "Nakamura, Hikaru"]

1. e4 e5 *

[Event "Open"]
[White "Caruana, Fabiano"]
[Black "Carlsen, Magnus"]

1. d4 d5 *

[Event "Open"]
[White "Carlsen, Magnus"]
[Black "Giri, Anish"]

1. c4 e5 *
''';

/// Every reading place saved, in order.
final class _Places implements ViewerPlaces {
  final perspectives = <Perspective>[];

  @override
  Future<ReadingPlace?> load(String path) async => null;

  @override
  Future<void> save(String path, ReadingPlace place) async =>
      perspectives.add(place.perspective);
}
