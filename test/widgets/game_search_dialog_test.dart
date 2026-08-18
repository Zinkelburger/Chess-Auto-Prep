import 'package:chess_auto_prep/utils/app_shortcuts.dart';
import 'package:chess_auto_prep/widgets/game_nav_bar.dart';
import 'package:chess_auto_prep/widgets/game_search_dialog.dart';
import 'package:chess_auto_prep/widgets/shortcut_tooltip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<GameNavItem> _games() => const [
  GameNavItem(
    label: 'Carlsen vs Nakamura',
    studyRating: 2,
    studySummary: 'Ruy Lopez',
    headers: {
      'White': 'Carlsen',
      'Black': 'Nakamura',
      'Event': 'Tata Steel',
      'ECO': 'C88',
    },
  ),
  GameNavItem(
    label: 'Kasparov vs Karpov',
    studyRating: 0,
    headers: {
      'White': 'Kasparov',
      'Black': 'Karpov',
      'Event': 'World Championship',
    },
  ),
  GameNavItem(
    label: 'Anand vs Adams',
    studyRating: 1,
    headers: {'White': 'Anand', 'Black': 'Adams', 'Event': 'Linares'},
  ),
];

Widget _navBar({void Function(int)? onGoToGame}) => MaterialApp(
  home: Scaffold(
    body: GameNavBar(
      games: _games(),
      currentIndex: 0,
      currentRating: 0,
      sortMode: GameSortMode.fileOrder,
      isAutoPlaying: false,
      autoPlayDelaySec: 1,
      autoNextGame: false,
      onGoToGame: onGoToGame,
    ),
  ),
);

void main() {
  testWidgets('Search is a labeled button at least 40px tall', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GameSearchButton(
            shortcut: AppShortcut.searchGames,
            onPressed: () {},
          ),
        ),
      ),
    );

    expect(find.text('Search'), findsOneWidget);
    final size = tester.getSize(find.byType(OutlinedButton));
    expect(size.height, greaterThanOrEqualTo(40));
    expect(size.width, greaterThanOrEqualTo(88));
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is ShortcutTooltip &&
            w.message.contains('Search games by player, event or opening') &&
            w.message.contains('/'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('nav bar Search opens the game search dialog', (tester) async {
    await tester.pumpWidget(_navBar());

    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    expect(find.text('Search games or enter game #...'), findsOneWidget);
    expect(find.text('Carlsen vs Nakamura'), findsWidgets);
  });

  testWidgets('a player-name query keeps matching games', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GameSearchDialog(games: _games(), currentIndex: 0),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'karpov');
    await tester.pump();

    expect(find.text('Kasparov vs Karpov'), findsOneWidget);
    expect(find.text('Carlsen vs Nakamura'), findsNothing);
  });

  testWidgets('a pure integer offers Go to game N as the first hit', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GameSearchDialog(games: _games(), currentIndex: 0),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '2');
    await tester.pump();

    expect(find.text('Go to game 2'), findsOneWidget);
    expect(find.text('Kasparov vs Karpov'), findsNothing);
  });
}
