import 'package:chess_auto_prep/models/explorer_response.dart';
import 'package:chess_auto_prep/widgets/opening_explorer/explorer_games_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _game = ExplorerGame(
  id: 'g1',
  source: ExplorerGameSource.masters,
  white: 'Carlsen, Magnus',
  black: 'Nakamura, Hikaru',
  whiteElo: 2830,
  blackElo: 2790,
  result: '1-0',
  year: 2024,
  month: 3,
  san: 'Nf3',
);

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required ValueChanged<ExplorerGame> onOpen,
    String? busyId,
    List<ExplorerGame> games = const [_game],
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ExplorerGamesList(games: games, onOpen: onOpen, busyId: busyId),
      ),
    ),
  );

  testWidgets('a row names the game, its move and its result', (tester) async {
    ExplorerGame? opened;
    await pump(tester, onOpen: (g) => opened = g);
    expect(find.text('Games'), findsOneWidget);
    expect(find.text('Carlsen M. – Nakamura H.'), findsOneWidget);
    expect(find.text('Nf3 · 2830/2790 · 2024-03'), findsOneWidget);
    expect(find.text('1-0'), findsOneWidget);
    await tester.tap(find.text('Carlsen M. – Nakamura H.'));
    expect(opened?.id, 'g1');
  });

  testWidgets('a game being fetched shows it and cannot be tapped twice', (
    tester,
  ) async {
    var opens = 0;
    await pump(tester, onOpen: (_) => opens++, busyId: 'g1');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('1-0'), findsNothing);
    await tester.tap(find.text('Carlsen M. – Nakamura H.'));
    expect(opens, 0);
  });

  testWidgets('nothing is drawn for an empty list', (tester) async {
    await pump(tester, onOpen: (_) {}, games: const []);
    expect(find.text('Games'), findsNothing);
  });
}
