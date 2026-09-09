import 'package:chess_auto_prep/models/pgn_game_entry.dart';
import 'package:chess_auto_prep/widgets/game_chapter_dialog.dart';
import 'package:chess_auto_prep/widgets/game_nav_bar.dart';
import 'package:chess_auto_prep/widgets/game_number_field.dart';
import 'package:chess_auto_prep/widgets/game_search_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

List<PgnGameEntry> _course({String chapterKey = 'White'}) => [
  for (var i = 0; i < 5; i++)
    PgnGameEntry(
      headers: {
        'White': 'Variation $i',
        'Black': 'Continuation $i',
        'Event': '?',
        'Result': '*',
        chapterKey: i < 2 ? 'French Defence' : 'Caro-Kann',
      },
      pgnText: '',
    ),
];

Widget _host({
  List<GameNavItem>? games,
  int currentIndex = 0,
  bool solitaire = false,
  ValueChanged<int>? onGoToGame,
  VoidCallback? onPrev,
  VoidCallback? onNext,
}) => MaterialApp(
  home: Scaffold(
    body: GameNavBar(
      games: games ?? GameNavItem.fromEntries(_course()),
      currentIndex: currentIndex,
      isSolitaireMode: solitaire,
      onGoToGame: onGoToGame ?? (_) {},
      onPrev: onPrev,
      onNext: onNext,
    ),
  ),
);

Finder get _chapterSearch => find.descendant(
  of: find.byType(GameSearchDialog),
  matching: find.byType(TextField),
);

Future<void> _openChapters(WidgetTester tester) async {
  await tester.tap(find.text('Search'));
  await tester.pumpAndSettle();
}

void main() {
  group('whole-file chapter detection', () {
    for (final key in ['White', 'Black', 'Event']) {
      test('recognizes chapters in $key using repertoire semantics', () {
        final games = GameNavItem.fromEntries(_course(chapterKey: key));
        expect(games.map((game) => game.chapter), [
          'French Defence',
          'French Defence',
          'Caro-Kann',
          'Caro-Kann',
          'Caro-Kann',
        ]);
      });
    }

    test('one filtered game retains its full-file chapter', () {
      final all = _course(chapterKey: 'Event');
      final visible = GameNavItem.fromEntries(all, visibleGames: [all[4]]);
      expect(visible.single.chapter, 'Caro-Kann');
      expect(visible.single.headers, same(all[4].headers));
    });

    test('cached detection follows chapter and result edits in place', () {
      final all = _course();
      expect(GameNavItem.fromEntries(all).first.chapter, 'French Defence');
      all[0].headers['White'] = 'French Advance';
      expect(GameNavItem.fromEntries(all).first.chapter, 'French Advance');
      all[0].headers['Result'] = '1-0';
      expect(GameNavItem.fromEntries(all).first.chapter, isNull);
    });

    test('cached detection follows model-game markers added in place', () {
      final all = [_course()[0], _course()[4]];
      expect(GameNavItem.fromEntries(all).first.chapter, isNull);
      // Self-described tiny courses need no repeated chapter title.
      all[0].headers['ModelGameWhite'] = 'Illustrative player';
      expect(GameNavItem.fromEntries(all).first.chapter, 'French Defence');
      all[0].headers.remove('ModelGameWhite');
      expect(GameNavItem.fromEntries(all).first.chapter, isNull);
    });

    test('cached detection follows entries added and reordered in place', () {
      final all = _course();
      GameNavItem.fromEntries(all);
      final first = all.removeAt(0);
      all.add(first);
      expect(GameNavItem.fromEntries(all).last.chapter, 'French Defence');
      final extra = PgnGameEntry(
        headers: {'White': 'New chapter', 'Result': '*'},
        pgnText: '',
      );
      all.add(extra);
      expect(GameNavItem.fromEntries(all).last.chapter, 'New chapter');
    });

    test('reusing chapter detection still refreshes game display metadata', () {
      final all = _course();
      GameNavItem.fromEntries(all);
      all[0].studyRating = 5;
      all[0].studySummary = 'Review this line';
      final refreshed = GameNavItem.fromEntries(all).first;
      expect(refreshed.studyRating, 5);
      expect(refreshed.studySummary, 'Review this line');
      expect(refreshed.chapter, 'French Defence');
    });

    test('completed player games are not detected as chapters', () {
      final games = _course();
      for (final game in games) {
        game.headers['Result'] = '1-0';
      }
      expect(
        GameNavItem.fromEntries(games).every((game) => game.chapter == null),
        isTrue,
      );
    });

    test('placeholder titles do not become chapters', () {
      final games = [
        for (var i = 0; i < 5; i++)
          PgnGameEntry(
            headers: {'White': i < 2 ? 'Me' : '?', 'Black': 'Opponent'},
            pgnText: '',
          ),
      ];
      expect(
        GameNavItem.fromEntries(games).every((game) => game.chapter == null),
        isTrue,
      );
    });

    test('noncontiguous chapters keep visible indices and ungrouped games', () {
      final all = _course();
      final ungrouped = PgnGameEntry(
        headers: {'White': 'Player', 'Black': 'Rival', 'Result': '1-0'},
        pgnText: '',
      );
      all.add(ungrouped);
      final visible = GameNavItem.fromEntries(
        all,
        visibleGames: [all[3], all[0], all[4], ungrouped],
      );
      final chapters = GameNavChapter.fromGames(visible);
      expect(chapters.map((chapter) => chapter.name), [
        'Caro-Kann',
        'French Defence',
        null,
      ]);
      expect(chapters.map((chapter) => chapter.gameIndices), [
        [0, 2],
        [1],
        [3],
      ]);
    });
  });

  testWidgets('chapters select a group before opening a game', (tester) async {
    final jumps = <int>[];
    await tester.pumpWidget(_host(onGoToGame: jumps.add));
    await _openChapters(tester);
    expect(find.text('Browse Games'), findsOneWidget);
    await tester.tap(find.text('Caro-Kann').first);
    await tester.pumpAndSettle();
    expect(jumps, isEmpty);
    expect(find.text('Caro-Kann · 3 shown'), findsOneWidget);
    await tester.tap(find.text('Continuation 3'));
    await tester.pumpAndSettle();
    expect(jumps, [3]);
  });

  testWidgets('chapter search and selection preserve filtered indices', (
    tester,
  ) async {
    final all = _course();
    final visible = GameNavItem.fromEntries(
      all,
      visibleGames: [all[4], all[0], all[3]],
    );
    final jumps = <int>[];
    await tester.pumpWidget(_host(games: visible, onGoToGame: jumps.add));
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(_chapterSearch, 'French');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(jumps, [1]);
  });

  testWidgets('search all games escapes a chapter with no matches', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await _openChapters(tester);
    await tester.tap(find.text('French Defence').first);
    await tester.pumpAndSettle();
    await tester.enterText(_chapterSearch, 'Continuation 4');
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
    await tester.tap(find.text('Search all games'));
    await tester.pumpAndSettle();
    expect(find.text('Continuation 4'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(GameSearchDialog), findsNothing);
  });

  test('event groups require five games and keep years separate', () {
    final games = [
      for (var i = 0; i < 10; i++)
        GameNavItem(
          label: 'Game $i',
          studyRating: 0,
          headers: {
            'Event': 'Tata Steel',
            'Date': i < 5 ? '2020.01.01' : '2021.01.01',
          },
        ),
      const GameNavItem(
        label: 'Other',
        studyRating: 0,
        headers: {'Event': '?'},
      ),
    ];
    expect(gameBrowserGroups(games).map((g) => g.label), [
      'Tata Steel 2020',
      'Tata Steel 2021',
    ]);
    expect(gameBrowserGroups(games.take(4).toList()), isEmpty);
    expect(gameBrowserGroups(games).last.gameIndices, [5, 6, 7, 8, 9]);
  });

  testWidgets('number input and its focus shortcut jump directly to a game', (
    tester,
  ) async {
    final jumps = <int>[];
    await tester.pumpWidget(_host(onGoToGame: jumps.add));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.byType(GameSearchDialog), findsNothing);
    expect(GameNumberField.focusActive(), isTrue);
    await tester.enterText(find.byType(TextField), '4');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(jumps, [3]);
  });

  testWidgets('previous and next navigation callbacks are preserved', (
    tester,
  ) async {
    var previous = 0;
    var next = 0;
    await tester.pumpWidget(
      _host(currentIndex: 1, onPrev: () => previous++, onNext: () => next++),
    );
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.tap(find.byIcon(Icons.chevron_right));
    expect(previous, 1);
    expect(next, 1);
  });

  testWidgets('solitaire hides chapter browsing and game search', (
    tester,
  ) async {
    final jumps = <int>[];
    await tester.pumpWidget(_host(solitaire: true, onGoToGame: jumps.add));
    expect(find.byKey(const Key('game-counter-browser')), findsNothing);
    expect(find.text('Search'), findsNothing);
    expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
    await tester.tap(find.text('Game'));
    await tester.pumpAndSettle();
    expect(find.byType(GameSearchDialog), findsNothing);
    await tester.enterText(find.byType(TextField), '2');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(jumps, [1]);
  });

  testWidgets('flat collections browse games from Search', (tester) async {
    final games = _course();
    for (final game in games) {
      game.headers['Result'] = '1-0';
    }
    await tester.pumpWidget(_host(games: GameNavItem.fromEntries(games)));
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.byType(GameSearchDialog), findsOneWidget);
  });

  testWidgets('empty collection has no browser and disables number entry', (
    tester,
  ) async {
    await tester.pumpWidget(_host(games: []));
    expect(find.byKey(const Key('game-counter-browser')), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  });
}
