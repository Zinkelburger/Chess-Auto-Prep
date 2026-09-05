/// The new-tournament dialog: basics first, an empty FEN field that means
/// the standard start, and everything else behind Advanced.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/engine_spec.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/tournament_config.dart';
import 'package:chess_auto_prep/features/engine_tournament/widgets/new_tournament_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _engines = [
  EngineSpec(id: 'a', name: 'Alpha', executablePath: '/bin/a'),
  EngineSpec(id: 'b', name: 'Beta', executablePath: '/bin/b'),
];

const _boardFen =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';

final _fenField = find.byKey(const ValueKey('new-tournament-fen'));

/// Opens the dialog; the config it returns on Start lands in [result].
Future<void> _openDialog(
  WidgetTester tester, {
  String boardFen = _boardFen,
  List<TournamentConfig?>? result,
}) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                final config = await showNewTournamentDialog(
                  context,
                  engines: _engines,
                  boardFen: boardFen,
                  onManageEngines: () {},
                );
                result?.add(config);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

String _fenText(WidgetTester tester) =>
    tester.widget<TextField>(_fenField).controller!.text;

void main() {
  testWidgets('an empty FEN field means the standard start', (tester) async {
    final result = <TournamentConfig?>[];
    await _openDialog(tester, result: result);

    expect(_fenText(tester), isEmpty);
    expect(find.text('Standard start — paste a FEN to change'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-tournament-start')));
    await tester.pumpAndSettle();

    expect(result.single!.startFen, kStandardStartFen);
    expect(result.single!.name, 'Engine match');
    expect(result.single!.gamesPerPairing, 10);
  });

  testWidgets('the board position is one click, and one click to undo', (
    tester,
  ) async {
    await _openDialog(tester);

    await tester.tap(find.text('Use the board position'));
    await tester.pumpAndSettle();
    expect(_fenText(tester), _boardFen);
    // Already in play, so the offer goes away.
    expect(find.text('Use the board position'), findsNothing);

    await tester.tap(find.byTooltip('Back to the standard start'));
    await tester.pumpAndSettle();
    expect(_fenText(tester), isEmpty);
    expect(find.text('Use the board position'), findsOneWidget);
  });

  testWidgets('a board already at the start is not offered', (tester) async {
    await _openDialog(tester, boardFen: kStandardStartFen);
    expect(find.text('Use the board position'), findsNothing);
  });

  testWidgets('a bad FEN blocks Start and says why', (tester) async {
    await _openDialog(tester);

    await tester.enterText(_fenField, 'not a fen');
    await tester.pumpAndSettle();

    final start = tester.widget<FilledButton>(
      find.byKey(const ValueKey('new-tournament-start')),
    );
    expect(start.onPressed, isNull);
    expect(find.text('Could not read that FEN.'), findsWidgets);
  });

  testWidgets('Edit board… opens the editor and applies its position', (
    tester,
  ) async {
    await _openDialog(tester);

    await tester.tap(find.text('Edit board…'));
    await tester.pumpAndSettle();
    expect(find.text('Set up position'), findsOneWidget);

    await tester.tap(find.text('Use this position'));
    await tester.pumpAndSettle();

    // Back in the setup dialog. The editor handed back the standard start,
    // which the field shows as empty rather than as a FEN to wade through.
    expect(find.text('Set up position'), findsNothing);
    expect(_fenText(tester), isEmpty);
  });

  testWidgets('engines and adjudication wait behind Advanced', (tester) async {
    await _openDialog(tester);

    expect(find.text('ADJUDICATION'), findsNothing);
    expect(find.text('Manage engines…'), findsNothing);
    expect(find.text('Games at once'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('new-tournament-advanced')));
    await tester.pumpAndSettle();

    expect(find.text('ADJUDICATION'), findsOneWidget);
    expect(find.text('Manage engines…'), findsOneWidget);
    expect(find.text('Games at once'), findsOneWidget);
  });
}
