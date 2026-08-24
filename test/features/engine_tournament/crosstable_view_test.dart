import 'package:chess_auto_prep/features/engine_tournament/models/engine_spec.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/tournament_config.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/tournament_game.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/crosstable_builder.dart';
import 'package:chess_auto_prep/features/engine_tournament/widgets/crosstable_view.dart';
import 'package:chess_auto_prep/features/engine_tournament/widgets/tournament_games_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = TournamentConfig(
  name: 'Match',
  engines: [
    EngineSpec(id: 'a', name: 'Alpha', executablePath: '/bin/a'),
    EngineSpec(id: 'b', name: 'Beta', executablePath: '/bin/b'),
  ],
);

TournamentGameRecord _game(int index, GameResult result) =>
    TournamentGameRecord(
      gameIndex: index,
      round: index + 1,
      whiteIndex: index.isEven ? 0 : 1,
      blackIndex: index.isEven ? 1 : 0,
      whiteName: index.isEven ? 'Alpha' : 'Beta',
      blackName: index.isEven ? 'Beta' : 'Alpha',
      result: result,
      termination: TerminationReason.checkmate,
      plies: 50 + index,
      startedAt: DateTime(2026, 8, 22),
      durationMs: 61000,
    );

final _games = [
  _game(0, GameResult.whiteWins),
  _game(1, GameResult.draw),
  _game(2, GameResult.draw),
];

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the crosstable shows standings and head-to-head', (
    tester,
  ) async {
    await _pump(
      tester,
      CrosstableView(
        crosstable: buildCrosstable(_config, _games),
        config: _config,
      ),
    );

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    // Alpha won one and drew two. In a two-engine match the total score and
    // the head-to-head score are the same number, so each appears twice.
    expect(find.text('2/3'), findsNWidgets(2));
    expect(find.text('1/3'), findsNWidgets(2));
    expect(find.text('vs Alpha'), findsOneWidget);
    expect(find.text('vs Beta'), findsOneWidget);
  });

  testWidgets('an empty crosstable says so rather than rendering blank', (
    tester,
  ) async {
    await _pump(
      tester,
      CrosstableView(
        crosstable: buildCrosstable(_config, const []),
        config: _config,
      ),
    );
    expect(find.textContaining('No games yet'), findsOneWidget);
  });

  testWidgets('every game is a row, and tapping one opens it', (tester) async {
    TournamentGameRecord? opened;
    await _pump(
      tester,
      TournamentGamesTable(games: _games, onOpenGame: (game) => opened = game),
    );

    expect(find.text('1-0'), findsOneWidget);
    expect(find.text('1/2-1/2'), findsNWidgets(2));
    // Game numbers are 1-based and match the position in games.pgn.
    expect(find.text('3'), findsWidgets);

    await tester.tap(find.text('1-0'));
    await tester.pump();
    expect(opened?.gameIndex, 0);
  });

  testWidgets('an empty games list says so', (tester) async {
    await _pump(
      tester,
      TournamentGamesTable(games: const [], onOpenGame: (_) {}),
    );
    expect(find.text('No games played yet.'), findsOneWidget);
  });
}
