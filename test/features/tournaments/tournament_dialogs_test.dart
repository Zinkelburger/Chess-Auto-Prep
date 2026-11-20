import 'dart:async';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/engines/engine.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/playing_engine.dart';
import 'package:chess_auto_prep/features/tournaments/engine_manager.dart';
import 'package:chess_auto_prep/features/tournaments/setup_dialog.dart';
import 'package:chess_auto_prep/features/tournaments/tournament_run.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/ui/toggle_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/engine_jobs_fixture.dart';
import '../../support/scripted_tournaments.dart';

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
    final blitz = find.widgetWithText(ToggleChip, 'Blitz');
    expect(tester.widget<ToggleChip>(blitz).selected, isFalse);
    expect(
      tester
          .widget<ToggleChip>(find.widgetWithText(ToggleChip, '2 s / move'))
          .selected,
      isTrue,
    );
    await tester.tap(blitz);
    await tester.pumpAndSettle();
    expect(tester.widget<ToggleChip>(blitz).selected, isTrue);
    expect(find.text('Initial clock (ms)'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Test match',
    );
    await tester.tap(find.text('Start new run'));
    await tester.pumpAndSettle();
    expect((await config)!.timeLabel, 'Blitz · 60 s + 0.6 s');
  });

  testWidgets('a seat keeps the selected profile when engine names match', (
    tester,
  ) async {
    final context = await _host(tester);
    final config = tournamentSetup(
      context,
      engines: [
        for (final skill in [5, 15])
          TournamentEngine({
            'id': 'profile-$skill',
            'name': 'Stockfish 17',
            'executablePath': '/opt/engines/stockfish',
            'options': {'Skill Level': '$skill'},
          }),
      ],
      position: Fen.initial,
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Skill comparison',
    );
    await tester.tap(find.widgetWithText(TextField, 'Engine 1'));
    await tester.pumpAndSettle();
    final profiles = find.textContaining('Stockfish 17');
    expect(profiles, findsNWidgets(2));
    await tester.tap(profiles.at(1));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Engine 2'),
      'Stockfish 17',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start new run'));
    await tester.pumpAndSettle();

    final seats = (await config)!.engines;
    expect(seats.first.id, 'profile-15');
    expect(seats.first.options['Skill Level'], '15');
    expect(seats.last.id, 'profile-5');
    expect(seats.last.options['Skill Level'], '5');
  });

  testWidgets('picker suffixes skip saved and registered engine names', (
    tester,
  ) async {
    final context = await _host(tester);
    final saved = TournamentEngine({'id': 'custom', 'name': 'Stockfish (1)'});
    final config = tournamentSetup(
      context,
      engines: [
        TournamentEngine({...saved.json, 'name': 'Stockfish'}),
        TournamentEngine({'id': 'other', 'name': 'Stockfish (2)'}),
      ],
      position: Fen.initial,
      previous: TournamentConfig({
        'name': 'Earlier run',
        'engines': [saved.json, TournamentEngine.bundled().json],
      }),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextField, 'Engine 2'));
    await tester.pumpAndSettle();
    expect(find.text('Stockfish (1)'), findsOneWidget);
    expect(find.text('Stockfish (2)'), findsOneWidget);
    await tester.tap(find.text('Stockfish (3)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start new run'));
    await tester.pumpAndSettle();

    final seats = (await config)!.engines;
    expect(seats.first.json, saved.json);
    expect(seats.last.id, 'custom');
    expect(seats.last.name, 'Stockfish');
  });

  testWidgets('run again distinguishes snapshots with the same name', (
    tester,
  ) async {
    final context = await _host(tester);
    final profile = TournamentEngine({
      'id': 'custom',
      'name': 'Stockfish',
      'options': {'Skill Level': '15'},
    });
    final previous = TournamentConfig({
      'name': 'Earlier run',
      'engines': [
        {
          ...profile.json,
          'options': {'Skill Level': '5'},
        },
        profile.json,
      ],
    });
    final config = tournamentSetup(
      context,
      engines: [profile],
      position: Fen.initial,
      previous: previous,
    );
    await tester.pumpAndSettle();
    String seatText(int index) => tester
        .widget<TextField>(find.widgetWithText(TextField, 'Engine $index'))
        .controller!
        .text;
    expect(seatText(1), 'Stockfish (2)');
    expect(seatText(2), 'Stockfish (1)');
    await tester.tap(find.text('Start new run'));
    await tester.pumpAndSettle();

    expect((await config)!.json['engines'], previous.json['engines']);
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

  testWidgets('the engine kept is the one tested, under its own name, '
      'whatever the fields say by the time the test ends', (tester) async {
    final store = ScriptedTournaments();
    addTearDown(store.dispose);
    final gate = Completer<void>();
    final run = TournamentRun(
      store: store,
      pending: PendingWrites(),
      jobs: await engineJobsFixture(),
      pickExecutable: () async => '/opt/engines/berserk-13',
      launch: (spec, transcript) async {
        await gate.future;
        return Started(_OpeningEngine());
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
    await tester.tap(find.text('Test and save'));
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextField, 'UCI options (name=value, one per line)'),
      'Foo',
    );
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Could not test the engine.'), findsNothing);
    final kept = run.engines.single;
    expect(kept.name, 'Opening 1.0');
    expect(kept.executable, '/opt/engines/berserk-13');
    expect(kept.options.keys, isNot(contains('Foo')));
    await tester.tap(find.text('Close'));
    await closed;
  });

  testWidgets('an engine row counts one core as a core', (tester) async {
    final store = ScriptedTournaments();
    addTearDown(store.dispose);
    final run = TournamentRun(
      store: store,
      pending: PendingWrites(),
      jobs: await engineJobsFixture(),
      launch: (spec, transcript) async => const StartFailed('not started'),
    );
    addTearDown(run.dispose);
    await tester.runAsync(
      () => run.keepEngines([
        TournamentEngine({'id': 'weak', 'name': 'SF weak', 'threads': 1}),
        TournamentEngine({'id': 'big', 'name': 'SF big', 'threads': 4}),
      ]),
    );
    final context = await _host(tester);
    final closed = manageTournamentEngines(context, run);
    await tester.pumpAndSettle();
    expect(find.text('1 core · 128 MB · Bundled Stockfish'), findsOneWidget);
    expect(find.text('4 cores · 128 MB · Bundled Stockfish'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await closed;
  });
}

/// Answers the test with 1.e4 under the name `Opening 1.0`.
final class _OpeningEngine implements PlayingEngine {
  final _exit = Completer<EngineExit>();
  @override
  String get name => 'Opening 1.0';
  @override
  Future<EngineExit> get exited => _exit.future;
  @override
  Future<void> quit() async {
    if (!_exit.isCompleted) _exit.complete(EngineExit.ended);
  }

  @override
  Search analyse(Fen fen, {required int multiPv, int? depth}) =>
      throw UnimplementedError();
  @override
  PlayingSearch play(Fen root, List<String> history, MoveBudget budget) =>
      PlayingSearch(
        Search(lines: const Stream.empty(), stop: () async {}),
        Future.value('e2e4'),
      );
}
