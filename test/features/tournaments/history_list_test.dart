import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/tournaments/history_list.dart';
import 'package:chess_auto_prep/features/tournaments/tournament_run.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/ui/progress_line.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/engine_jobs_fixture.dart';
import '../../support/scripted_tournaments.dart';

Tournament _run(
  String id, {
  required DateTime? created,
  String status = 'completed',
  List<String> engines = const ['Alpha', 'Beta'],
  String? opening,
  int played = 2,
}) => Tournament({
  'id': id,
  'createdAt': ?created?.toUtc().toIso8601String(),
  'status': status,
  'config': {
    'name': id,
    'openingLabel': ?opening,
    'gamesPerPairing': 2,
    'engines': [for (final name in engines) TournamentEngine.bundled(name).json],
  },
  'games': [
    for (var i = 0; i < played; i++)
      {
        'gameIndex': i,
        'whiteIndex': i % 2,
        'blackIndex': 1 - i % 2,
        'result': i == 0 ? 'whiteWins' : 'draw',
      },
  ],
});

void main() {
  late ScriptedTournaments store;
  late TournamentRun run;
  setUp(() async {
    store = ScriptedTournaments();
    run = TournamentRun(
      store: store,
      pending: PendingWrites(),
      jobs: await engineJobsFixture(),
      launch: (_, _) async => const StartFailed('not launched'),
    );
  });
  tearDown(() async {
    run.dispose();
    await store.dispose();
  });

  Future<void> show(WidgetTester tester) {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: TournamentHistory(run: run)),
      ),
    );
  }

  testWidgets('runs are grouped under the day or month they were made, '
      'each heading once, with their status, count and scores', (
    tester,
  ) async {
    final now = DateTime.now();
    run.history = [
      _run('Today one', created: now),
      _run('Today two', created: now),
      _run('Yesterday one', created: DateTime(now.year, now.month, now.day - 1, 12)),
      _run('Old one', created: DateTime(2025, 3, 5, 12)),
      _run('Undated', created: null, status: 'running', played: 1),
    ];
    await show(tester);
    for (final heading in ['Today', 'Yesterday', 'March 2025', 'Unknown date']) {
      expect(find.text(heading), findsOneWidget, reason: heading);
    }
    expect(
      find.text('completed · 2/2 games\nAlpha 1.5 · Beta 0.5'),
      findsNWidgets(4),
    );
    expect(
      find.text('running · 1/2 games\nAlpha 1.0 · Beta 0.0'),
      findsOneWidget,
    );
    final progress = tester.widget<ProgressLine>(find.byType(ProgressLine));
    expect(progress.value, 0.5);

    await tester.tap(find.text('Old one'));
    expect(run.selected?.id, 'Old one');
  });

  testWidgets('the search finds a run by its name, an engine or its opening', (
    tester,
  ) async {
    final now = DateTime.now();
    run.history = [
      _run('Club match', created: now),
      _run('Gauntlet', created: now, engines: ['Stockfish', 'Berserk']),
      _run('Opening test', created: now, opening: 'Benko Gambit'),
    ];
    await show(tester);
    final search = find.byType(TextField);
    Future<List<String>> found(String query) async {
      await tester.enterText(search, query);
      await tester.pump();
      return [
        for (final name in ['Club match', 'Gauntlet', 'Opening test'])
          if (find.text(name).evaluate().isNotEmpty) name,
      ];
    }

    expect(await found('CLUB'), ['Club match']);
    expect(await found('berserk'), ['Gauntlet']);
    expect(await found('benko'), ['Opening test']);
    expect(await found('alpha'), ['Club match', 'Opening test']);
    expect(await found('nothing'), isEmpty);
    expect(find.text('Nothing matches "nothing".'), findsOneWidget);
  });

  testWidgets('an empty history says there are no tournaments yet', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('No tournaments yet.'), findsOneWidget);
  });
}
