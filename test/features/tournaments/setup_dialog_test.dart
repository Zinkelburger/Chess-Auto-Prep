import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/features/tournaments/setup_dialog.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/ui/toggle_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  for (final id in ['registered', null]) {
    testWidgets(
      'choosing registered Stockfish (id $id) seats its own executable',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: darkTheme(),
            home: const Scaffold(body: Text('host')),
          ),
        );
        final external = TournamentEngine({
          'id': ?id,
          'name': 'Stockfish',
          'executablePath': '/engines/stockfish-dev',
        });
        final config = tournamentSetup(
          tester.element(find.text('host')),
          engines: [external],
          position: Fen.initial,
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Name'),
          'Club match',
        );
        final seat = find.widgetWithText(TextField, 'Engine 1');
        await tester.enterText(seat, 'Stock');
        await tester.pumpAndSettle();
        // The bundled suggestion precedes the registered one, even when they
        // share the same display name.
        final suggestions = find.descendant(
          of: find.byType(ListView),
          matching: find.textContaining('Stockfish'),
        );
        await tester.tap(suggestions.last);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextField, 'Name'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(seat).controller!.text,
          'Stockfish (2)',
        );
        await tester.tap(find.text('Start new run'));
        await tester.pumpAndSettle();
        final saved = (await config)!;
        final picked = saved.engines.first;
        expect(
          (picked.id, picked.executable),
          (external.id, external.executable),
        );
        final reopened = tournamentSetup(
          tester.element(find.text('host')),
          engines: [
            TournamentEngine({
              ...external.json,
              'arguments': ['new'],
            }),
          ],
          position: Fen.initial,
          previous: saved,
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(seat).controller!.text,
          'Stockfish (3)',
        );
        await tester.tap(find.text('Start new run'));
        await tester.pumpAndSettle();
        expect((await reopened)!.engines.first.json, external.json);
      },
    );
  }

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
