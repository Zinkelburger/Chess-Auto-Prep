import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/tournaments/engine_manager.dart';
import 'package:chess_auto_prep/features/tournaments/setup_dialog.dart';
import 'package:chess_auto_prep/features/tournaments/tournament_run.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_tournaments.dart';
import '../../support/engine_jobs_fixture.dart';

Future<BuildContext> _host(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: darkTheme(),
      home: const Scaffold(body: Text('host')),
    ),
  );
  return tester.element(find.text('host'));
}

void main() {
  testWidgets('a time preset fills the time control in one click and the '
      'fields still edit it', (tester) async {
    final context = await _host(tester);
    final config = tournamentSetup(
      context,
      engines: const [],
      position: Fen.initial,
    );
    await tester.pumpAndSettle();
    final blitz = find.widgetWithText(ChoiceChip, 'Blitz');
    expect(tester.widget<ChoiceChip>(blitz).selected, isFalse);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '2 s / move'))
          .selected,
      isTrue,
    );
    await tester.tap(blitz);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(blitz).selected, isTrue);
    expect(find.text('Initial clock (ms)'), findsOneWidget);
    await tester.tap(find.text('Start new run'));
    await tester.pumpAndSettle();
    expect((await config)!.timeLabel, 'Blitz · 60 s + 0.6 s');
  });

  testWidgets('a picked engine file names the engine, and a failed test '
      'shows its sentence and the engine output', (tester) async {
    final store = ScriptedTournaments();
    addTearDown(store.dispose);
    final run = TournamentRun(
      store: store,
      pending: PendingWrites(),
      jobs: await engineJobsFixture(),
      pickExecutable: () async => '/opt/engines/berserk-13',
      launch: (spec, transcript) async {
        transcript.add('berserk: cannot open network file');
        return const StartFailed(
          'berserk-13 crashed while starting (exit code 1)',
        );
      },
    );
    addTearDown(run.dispose);
    final context = await _host(tester);
    final closed = manageTournamentEngines(context, run);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add UCI engine…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose file…'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'berserk-13'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, '/opt/engines/berserk-13'),
      findsOneWidget,
    );
    await tester.tap(find.text('Test and save'));
    await tester.pumpAndSettle();
    expect(
      find.text('berserk-13 crashed while starting (exit code 1)'),
      findsWidgets,
    );
    expect(find.text('berserk: cannot open network file'), findsWidgets);
    expect(run.engines, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await closed;
  });
}
