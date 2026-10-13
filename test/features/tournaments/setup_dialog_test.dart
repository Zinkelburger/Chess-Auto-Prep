import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/features/tournaments/setup_dialog.dart';
import 'package:chess_auto_prep/ui/theme.dart';
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

  testWidgets('sudden death is saved without movesPerSession, as v1 writes '
      'it', (tester) async {
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
        await tester.tap(find.widgetWithText(ChoiceChip, preset));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Start new run'));
      await tester.pumpAndSettle();
      return (await config)!.json['timeControl']! as Map<String, Object?>;
    }

    // A run an older v2 wrote with 0, configured again.
    final older = await started(
      previous: TournamentConfig({
        'name': 'Older run',
        'timeControl': {
          'kind': 'incremental',
          'baseMs': 60000,
          'incrementMs': 600,
          'movesPerSession': 0,
        },
      }),
    );
    expect(older.containsKey('movesPerSession'), isFalse);
    expect(older['baseMs'], 60000);
    final blitz = await started(preset: 'Blitz');
    expect(blitz.containsKey('movesPerSession'), isFalse);
    final classical = await started(preset: 'Classical');
    expect(classical['movesPerSession'], 40);
  });
}
