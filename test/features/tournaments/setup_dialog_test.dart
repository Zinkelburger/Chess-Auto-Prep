import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/features/tournaments/setup_dialog.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/ui/toggle_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_tournaments.dart';

void main() {
  testWidgets(
    'selecting the registered Stockfish keeps its ID and executable',
    (tester) async {
      final registered = TournamentEngine({
        'id': 'custom-sf',
        'name': 'Stockfish',
        'executablePath': '/opt/engines/stockfish',
      });
      final store = ScriptedTournaments()..registry.add(registered);
      addTearDown(store.dispose);
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: const Scaffold(body: Text('host')),
        ),
      );
      final config = tournamentSetup(
        tester.element(find.text('host')),
        engines: store.registry,
        position: Fen.initial,
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'Test match',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Engine 1'),
        'Stock',
      );
      await tester.pumpAndSettle();
      final suggestions = find.descendant(
        of: find.byType(ListView),
        matching: find.textContaining('Stockfish'),
      );
      expect(suggestions, findsNWidgets(2));
      await tester.tap(suggestions.at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start new run'));
      await tester.pumpAndSettle();

      final seat = (await config)!.engines.first;
      expect(seat.id, registered.id);
      expect(seat.executable, registered.executable);
    },
  );

  testWidgets('a rerun labels saved seats and accepts typed engine names', (
    tester,
  ) async {
    final registered = TournamentEngine({
      'id': 'custom-sf',
      'name': 'Stockfish',
      'executablePath': '/opt/engines/stockfish-17',
      'options': {'Skill Level': '10'},
    });
    final saved = {
      ...registered.json,
      'options': {'Skill Level': '5'},
    };
    final berserk = TournamentEngine({'id': 'berserk', 'name': 'Berserk'});
    final exact = TournamentEngine({'id': 'sf17', 'name': 'Stockfish-17'});
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: const Scaffold(body: Text('host')),
      ),
    );
    final config = tournamentSetup(
      tester.element(find.text('host')),
      engines: [registered, exact, berserk],
      position: Fen.initial,
      previous: TournamentConfig({
        'name': 'Earlier run',
        'engines': [berserk.json, registered.json, saved],
      }),
    );
    await tester.pumpAndSettle();
    Finder field(int seat) => find.widgetWithText(TextField, 'Engine $seat');
    String label(int seat) =>
        tester.widget<TextField>(field(seat)).controller!.text;
    expect(label(2), 'Stockfish · /opt/engines/stockfish-17');
    expect(label(3), '${label(2)} (2)');

    await tester.enterText(field(1), 'Stockfish');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(label(1), 'Stockfish · Bundled');

    await tester.enterText(field(2), 'Stockfish-17');
    await tester.pumpAndSettle();
    final suggestions = tester.widgetList<Text>(
      find.descendant(of: find.byType(ListView), matching: find.byType(Text)),
    );
    expect(suggestions.map((text) => text.data), [
      exact.name,
      'Stockfish · /opt/engines/stockfish-17',
    ]);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Configure next run'), findsNothing);
    final seats = (await config)!.engines;
    expect(seats[0].json, TournamentEngine.bundled().json);
    expect(seats[1].json, exact.json);
    expect(seats[2].json, saved);
  });

  testWidgets('the start position is typed, or set up in the board editor', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => tournamentSetup(
              context,
              engines: const [],
              position: Fen.initial,
            ),
            child: const Text('Ask'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    final fen = find.widgetWithText(TextField, 'Starting FEN');
    await tester.enterText(fen, '8/8/8');
    await tester.pump();
    expect(find.text('Use a legal starting FEN.'), findsOneWidget);
    // A board dartchess's parser throws a bare ArgumentError on: the
    // dialog reads it while it builds, and must say no rather than throw.
    await tester.enterText(fen, 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/.NBQKBNR');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Use a legal starting FEN.'), findsOneWidget);

    await tester.tap(find.text('Edit position…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Black to play'));
    await tester.pump();
    await tester.tap(find.text('Use this position'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(fen).controller!.text,
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1',
    );
    expect(find.text('Use a legal starting FEN.'), findsNothing);
  });

  testWidgets('a preset or a previous run fills the time control', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: const Scaffold(body: Text('host')),
      ),
    );
    final context = tester.element(find.text('host'));
    Future<Map<String, Object?>> started({
      TournamentConfig? previous,
      String? preset,
    }) async {
      final config = tournamentSetup(
        context,
        engines: const [],
        position: Fen.initial,
        previous: previous,
      );
      await tester.pumpAndSettle();
      if (previous == null) {
        await tester.enterText(
          find.widgetWithText(TextField, 'Name'),
          'Test match',
        );
      }
      if (preset != null) {
        await tester.tap(find.widgetWithText(ToggleChip, preset));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Start new run'));
      await tester.pumpAndSettle();
      return (await config)!.json['timeControl']! as Map<String, Object?>;
    }

    final again = await started(
      previous: TournamentConfig({
        'name': 'Earlier run',
        'timeControl': {
          'kind': 'incremental',
          'baseMs': 60000,
          'incrementMs': 600,
          'movesPerSession': 0,
        },
      }),
    );
    expect(again['baseMs'], 60000);
    expect(again['movesPerSession'], 0);
    final blitz = await started(preset: 'Blitz');
    expect(blitz['movesPerSession'], isNull);
    final classical = await started(preset: 'Classical');
    expect(classical['movesPerSession'], 40);
  });
}
