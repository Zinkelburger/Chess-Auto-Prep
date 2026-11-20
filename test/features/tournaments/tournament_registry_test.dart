// What TournamentRun shows of the saved runs and the engine registry: the
// selection a refresh keeps, an open request from outside the app, and
// what a failed read, removal or registry save says.
import 'dart:async';

import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/tournaments/engine_check.dart';
import 'package:chess_auto_prep/features/tournaments/tournament_run.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/tournament_inbox.dart';
import 'package:chess_auto_prep/storage/tournaments.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/engine_jobs_fixture.dart';
import '../../support/scripted_tournaments.dart';
import 'game_runner_test.dart' show ScriptEngine, config;

/// The scripted store, whose reads, removals and registry saves can fail
/// and whose open requests can throw.
final class _Store implements TournamentStore, TournamentNotifications {
  final base = ScriptedTournaments();
  final changed = StreamController<void>.broadcast();
  String? failList;
  String? failEngines;
  List<String> engineWarnings = const [];
  String? failRemove;
  String? failSaveEngines;
  Object? requestError;
  String? request;
  @override
  Stream<void> changes() => changed.stream;
  @override
  Future<String?> takeRequest() async {
    if (requestError case final error?) throw error;
    final next = request;
    request = null;
    return next;
  }

  @override
  Future<TournamentResult<List<Tournament>>> list() async => switch (failList) {
    final message? => TournamentFailed(message),
    null => await base.list(),
  };
  @override
  Future<TournamentResult<List<TournamentEngine>>> engines() async =>
      switch (failEngines) {
        final message? => TournamentFailed(message),
        null => TournamentSaved(base.registry, warnings: engineWarnings),
      };
  @override
  Future<TournamentResult<void>> remove(Tournament tournament) async =>
      switch (failRemove) {
        final message? => TournamentFailed(message),
        null => await base.remove(tournament),
      };
  @override
  Future<TournamentResult<void>> saveEngines(
    List<TournamentEngine> before,
    List<TournamentEngine> after,
  ) async => switch (failSaveEngines) {
    final message? => TournamentFailed(message),
    null => await base.saveEngines(before, after),
  };
  @override
  Future<TournamentResult<Tournament>> create(Tournament initial) =>
      base.create(initial);
  @override
  Future<TournamentResult<Tournament>> save(
    Tournament before,
    Tournament after,
    String pgn, {
    required String? expectedPgn,
  }) => base.save(before, after, pgn, expectedPgn: expectedPgn);
  @override
  DocumentRef games(String id) => base.games(id);
}

Tournament _saved(String id) => Tournament({
  'id': id,
  'status': 'completed',
  'config': {...config().json, 'name': id},
  'games': <Object>[],
});

void main() {
  late _Store store;
  late PendingWrites pending;
  late TournamentRun run;
  var opened = 0;
  setUp(() async {
    store = _Store();
    pending = PendingWrites();
    opened = 0;
    run = TournamentRun(
      store: store,
      pending: pending,
      jobs: await engineJobsFixture(),
      onOpenRequest: () => opened++,
      launch: (engine, _) async =>
          Started(ScriptEngine([engine.name == 'A' ? 'e2e4' : 'e7e5'])),
    );
  });
  tearDown(() async {
    run.dispose();
    await store.changed.close();
    await store.base.dispose();
  });

  test('a refresh keeps the run selected while it is listed, and selects '
      'the first run otherwise', () async {
    for (final id in ['first', 'second']) {
      store.base.records[id] = _saved(id);
    }
    await run.refresh();
    expect(run.selected?.id, 'first');
    run.select(run.history.last);
    await run.refresh();
    expect(run.selected?.id, 'second');
    store.base.records.remove('second');
    await run.refresh();
    expect(run.selected?.id, 'first');
  });

  test('failed reads say why, and the registry\'s first warning is '
      'reported', () async {
    store
      ..failList = 'Tournaments unreadable.'
      ..engineWarnings = ['engines.json was set aside.', 'Another.'];
    await run.refresh();
    expect(run.problem, 'Tournaments unreadable.');
    expect(run.engineReport, 'engines.json was set aside.');
    store.failEngines = 'Registry unreadable.';
    await run.refresh();
    expect(run.engineReport, 'Registry unreadable.');
  });

  test('a request from outside selects its run and brings the page up; a '
      'request that cannot be read says so', () async {
    store.base.records['outside'] = _saved('outside');
    store.base.records['other'] = _saved('other');
    store.request = 'other';
    await run.refresh();
    expect(run.selected?.id, 'other');
    expect(opened, 1);
    await run.refresh();
    expect(opened, 1, reason: 'no request, no page');

    store.requestError = StateError('inbox gone');
    await run.refresh();
    expect(run.problem, contains('could not be read'));
  });

  test('a broken watch says updates are unavailable; a change refreshes '
      'after a pause', () async {
    await run.listen();
    store.base.records['late'] = _saved('late');
    store.changed.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(run.history, isEmpty, reason: 'the refresh waits for quiet');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(run.history.single.id, 'late');

    store.changed.addError(StateError('watch lost'));
    await pumpEventQueue();
    expect(run.problem, 'Tournament updates are unavailable. Use Refresh.');
  });

  test('a setup with a problem says it and starts nothing', () async {
    await run.start(config(extra: {'name': ''}));
    expect(run.problem, 'Name the tournament.');
    expect(run.running, isFalse);
    expect(store.base.records, isEmpty);
  });

  test('a removal that fails says why and keeps the run', () async {
    store.base.records['kept'] = _saved('kept');
    await run.refresh();
    store.failRemove = 'Trash unavailable.';
    await run.remove(run.history.single);
    expect(run.problem, 'Trash unavailable.');
    expect(run.history.single.id, 'kept');
    store.failRemove = null;
    await run.remove(run.history.single);
    expect(run.history, isEmpty);
  });

  test('a registry save that fails says why and keeps the engines', () async {
    final engine = TournamentEngine({'id': 'a', 'name': 'Club engine'});
    store.failSaveEngines = 'Registry read-only.';
    await run.keepEngines([engine]);
    expect(run.engineReport, 'Registry read-only.');
    expect(run.engines, isEmpty);
    expect(run.registryBusy, isFalse);
    store.failSaveEngines = null;
    await run.keepEngines([engine]);
    expect(run.engineReport, 'Engine settings saved.');
    expect(run.engines.single.name, 'Club engine');
  });

  test('no engine is tested, and the registry is not changed, while a '
      'tournament runs', () async {
    run.running = true;
    final check = await run.verify(TournamentEngine.bundled('X'));
    expect(
      (check as EngineRejected).reason,
      'Wait for the tournament to finish.',
    );
    await run.keepEngines([TournamentEngine.bundled('X')]);
    expect(store.base.registry, isEmpty);
    run.running = false;
  });
}
