import 'package:chess_auto_prep/widgets/game_nav_bar.dart';
import 'package:chess_auto_prep/widgets/game_number_field.dart';
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
  testWidgets('Search is a compact labeled button next to the game number', (
    tester,
  ) async {
    await tester.pumpWidget(_navBar());

    expect(find.text('Search'), findsOneWidget);
    final searchSize = tester.getSize(find.byType(OutlinedButton));
    final numberSize = tester.getSize(find.byType(GameNumberField));
    expect(searchSize.height, equals(kGameNavControlHeight));
    expect(numberSize.height, equals(kGameNavControlHeight));
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
