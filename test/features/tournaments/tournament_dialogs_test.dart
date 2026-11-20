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

  for (final openFirst in [true, false]) {
    testWidgets(
      'engine editor preserves arguments refreshed ${openFirst ? 'after' : 'before'} opening',
      (tester) async {
        final engine = TournamentEngine({
          'id': 'external',
          'name': 'Club engine',
          'executablePath': '/engines/club',
          'arguments': ['old'],
        });
        final store = ScriptedTournaments()..registry = [engine];
        addTearDown(store.dispose);
        final run = TournamentRun(
          store: store,
          pending: PendingWrites(),
          jobs: await engineJobsFixture(),
          launch: (_, _) async => Started(_OpeningEngine()),
        );
        addTearDown(run.dispose);
        await run.refresh();
        final context = await _host(tester);
        unawaited(manageTournamentEngines(context, run));
        await tester.pumpAndSettle();

        Future<void> edit() async {
          await tester.tap(find.byTooltip('Edit Club engine…'));
          await tester.pumpAndSettle();
        }

        if (openFirst) await edit();
        final newer = TournamentEngine({
          ...engine.json,
          'arguments': ['new'],
        });
        await store.saveEngines([engine], [newer]);
        await run.refresh();
        expect(run.engines.single.arguments, ['new']);
        // The registry changed, but Flutter has not rebuilt the old row.
        if (!openFirst) await edit();
        await tester.enterText(
          find.widgetWithText(TextField, 'Name'),
          'Renamed',
        );
        await tester.tap(find.text('Test and save'));
        await tester.pumpAndSettle();
        final saved = store.registry.single;
        expect(saved.arguments, ['new']);
        expect(saved.name, engine.name);
        expect(
          find.textContaining(
            RegExp('changed|conflict|stale', caseSensitive: false),
          ),
          findsWidgets,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(await run.pending.settle(), isNull);
      },
    );
  }

  for (final remove in [false, true]) {
    testWidgets(
      'an unrelated refresh permits engine ${remove ? 'removal' : 'editing'}',
      (tester) async {
        final engine = TournamentEngine({'id': 'a', 'name': 'Club engine'});
        final store = ScriptedTournaments()..registry = [engine];
        addTearDown(store.dispose);
        final run = TournamentRun(
          store: store,
          pending: PendingWrites(),
          jobs: await engineJobsFixture(),
          launch: (_, _) async => Started(_OpeningEngine()),
        );
        addTearDown(run.dispose);
        await run.refresh();
        final context = await _host(tester);
        unawaited(manageTournamentEngines(context, run));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byTooltip(remove ? 'Remove Club engine…' : 'Edit Club engine…'),
        );
        await tester.pumpAndSettle();
        final other = TournamentEngine({'id': 'b', 'name': 'Added elsewhere'});
        store.registry = [TournamentEngine(engine.json), other];
        await run.refresh();
        if (!remove) {
          await tester.enterText(
            find.widgetWithText(TextField, 'Name'),
            'Renamed',
          );
        }
        await tester.tap(find.text(remove ? 'Remove' : 'Test and save'));
        await tester.pumpAndSettle();
        expect(store.registry.map((e) => e.name), [
          if (!remove) 'Renamed',
          'Added elsewhere',
        ]);
        expect(await run.pending.settle(), isNull);
      },
    );
  }

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
