import 'dart:async';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:chess_auto_prep/engines/engine.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/playing_engine.dart';
import 'package:chess_auto_prep/features/tournaments/tournament_run.dart';
import 'package:chess_auto_prep/features/tournaments/tournaments_screen.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/storage/tournaments.dart';
import 'package:chessground/chessground.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/engine_jobs_fixture.dart';
import '../../support/scripted_tournaments.dart';

/// The scripted store, whose creates can fail and which keeps a final
/// position for each game (or an error) to preview.
final class _Store implements TournamentStore, TournamentPreviews {
  final base = ScriptedTournaments();
  String? failCreate;
  TournamentResult<List<String?>> previews = const TournamentSaved([]);
  @override
  Future<TournamentResult<List<String?>>> positions(String id) async =>
      previews;
  @override
  Future<TournamentResult<Tournament>> create(Tournament initial) async =>
      switch (failCreate) {
        final message? => TournamentFailed(message),
        null => await base.create(initial),
      };
  @override
  Future<TournamentResult<Tournament>> save(
    Tournament before,
    Tournament after,
    String pgn, {
    required String? expectedPgn,
  }) => base.save(before, after, pgn, expectedPgn: expectedPgn);
  @override
  Future<TournamentResult<List<Tournament>>> list() => base.list();
  @override
  Future<TournamentResult<void>> remove(Tournament tournament) =>
      base.remove(tournament);
  @override
  Future<TournamentResult<List<TournamentEngine>>> engines() => base.engines();
  @override
  Future<TournamentResult<void>> saveEngines(
    List<TournamentEngine> before,
    List<TournamentEngine> after,
  ) => base.saveEngines(before, after);
  @override
  DocumentRef games(String id) => base.games(id);
}

/// Plays 1.e4 at once as White; its replies as Black wait for [gate].
final class _Engine implements PlayingEngine {
  _Engine(this.gate);
  final Future<void> gate;
  final _exit = Completer<EngineExit>();
  @override
  String get name => 'Gated';
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
        history.isEmpty ? Future.value('e2e4') : gate.then((_) => 'e7e5'),
      );
}

TournamentConfig _config() => TournamentConfig({
  'name': 'Club match',
  'engines': [
    TournamentEngine.bundled('Alpha').json,
    TournamentEngine.bundled('Beta').json,
  ],
  'gamesPerPairing': 2,
  'timeControl': {'kind': 'fixedDepth', 'depth': 1},
  'adjudication': {'maxMoves': 1, 'drawEnabled': false},
});

Tournament _played() => Tournament({
  'id': 'club',
  'createdAt': '2026-11-01T12:00:00Z',
  'status': 'completed',
  'error': 'Engine Beta crashed twice.',
  'config': _config().json,
  'games': [
    {
      'gameIndex': 0,
      'whiteIndex': 0,
      'blackIndex': 1,
      'whiteName': 'Alpha',
      'blackName': 'Beta',
      'result': 'whiteWins',
      'termination': 'checkmate',
    },
    {
      'gameIndex': 1,
      'whiteIndex': 1,
      'blackIndex': 0,
      'whiteName': 'Beta',
      'blackName': 'Alpha',
      'result': 'blackWins',
      'termination': 'engineFailure',
      'detail': 'missing binary',
    },
  ],
});

/// Whether the button labelled [label] takes a press.
bool enabled(WidgetTester tester, String label) => tester
    .widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    )
    .enabled;

void main() {
  late _Store store;
  late SettingsStore settings;
  late TournamentRun run;
  late Completer<void> gate;
  final opened = <(String, int)>[];
  setUp(() async {
    store = _Store();
    settings = SettingsStore();
    gate = Completer<void>();
    opened.clear();
    run = TournamentRun(
      store: store,
      pending: PendingWrites(),
      jobs: await engineJobsFixture(),
      launch: (_, _) async => Started(_Engine(gate.future)),
    );
  });
  tearDown(() async {
    if (!gate.isCompleted) gate.complete();
    run.dispose();
    settings.dispose();
    await store.base.dispose();
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: TournamentsScreen(
            run: run,
            position: Fen.initial,
            settings: settings,
            open: (t, game) => opened.add((t.id, game)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a finished run lists its games with how each ended, and '
      'each opens its own game', (tester) async {
    final t = _played();
    run
      ..history = [t]
      ..selected = t;
    await show(tester);
    expect(find.text('completed · 2/2 games'), findsWidgets);
    expect(find.text('Engine Beta crashed twice.'), findsOneWidget);
    expect(find.text('1. Alpha — Beta'), findsOneWidget);
    expect(find.text('1-0 · Checkmate'), findsOneWidget);
    expect(find.text('0-1 · Engine failure · missing binary'), findsOneWidget);
    expect(find.text(store.games('club').path), findsOneWidget);

    await tester.tap(find.text('2. Beta — Alpha'));
    await tester.tap(find.text('Browse games'));
    expect(opened, [('club', 1), ('club', 0)]);
  });

  testWidgets('final positions show beside the games while the setting is '
      'on, and a failed read says why', (tester) async {
    store.previews = const TournamentSaved([
      '8/8/8/8/8/8/4k3/6K1 w - - 0 1',
      null,
    ]);
    final t = _played();
    run
      ..history = [t]
      ..selected = t;
    await show(tester);
    expect(find.byType(StaticChessboard), findsOneWidget);

    await settings.update(
      settings.value.copyWith(tournamentFinalPositions: false),
    );
    await tester.pumpAndSettle();
    expect(find.byType(StaticChessboard), findsNothing);

    store.previews = const TournamentFailed('Positions unreadable.');
    final again = Tournament(t.json);
    run.select(again);
    await settings.update(
      settings.value.copyWith(tournamentFinalPositions: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('Positions unreadable.'), findsOneWidget);
    expect(find.byType(StaticChessboard), findsNothing);
  });

  testWidgets('a running tournament shows its live game and can be stopped '
      'after the move', (tester) async {
    await show(tester);
    late Future<void> work;
    await tester.runAsync(() async {
      work = run.start(_config());
      while (run.live == null) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();
    expect(find.text('Game 1 · 1 ply · e4'), findsOneWidget);
    expect(enabled(tester, 'New tournament…'), isFalse);
    expect(enabled(tester, 'Run again…'), isFalse);

    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(run.stopping, isTrue);
    expect(find.text('Stopping after this move…'), findsOneWidget);

    await tester.runAsync(() async {
      gate.complete();
      await work;
    });
    await tester.pump();
    expect(run.running, isFalse);
    expect(run.selected!.status, 'stopped');
    expect(find.textContaining('Game 1 ·'), findsNothing);
    expect(find.text('Stop'), findsNothing);
  });

  testWidgets('a run whose first save failed offers Retry save and nothing '
      'new until it lands', (tester) async {
    store.failCreate = 'Disk full.';
    await show(tester);
    await tester.runAsync(() => run.start(_config()));
    await tester.pump();
    expect(find.text('Disk full.'), findsOneWidget);
    expect(enabled(tester, 'New tournament…'), isFalse);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Delete tournament…'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );

    store.failCreate = null;
    gate.complete();
    await tester.runAsync(() async {
      await tester.tap(find.text('Retry save'));
      while (run.running || run.canRetry) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();
    expect(find.text('Retry save'), findsNothing);
    expect(find.text('Disk full.'), findsNothing);
    expect(run.selected!.status, 'completed');
  });

  testWidgets('a tournament is deleted only once the player confirms', (
    tester,
  ) async {
    final t = _played();
    store.base.records[t.id] = t;
    await tester.runAsync(run.refresh);
    await show(tester);
    await tester.tap(find.byTooltip('Delete tournament…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.base.records, contains('club'));

    await tester.tap(find.byTooltip('Delete tournament…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(store.base.records, isEmpty);
  });
}
