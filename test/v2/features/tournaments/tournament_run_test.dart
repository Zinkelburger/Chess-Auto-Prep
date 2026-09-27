import 'dart:async';
import 'dart:io';
import 'package:chess_auto_prep/v2/chess/tournament/config.dart';
import 'package:chess_auto_prep/v2/chess/tournament/result.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/features/tournaments/tournament_run.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/tournaments.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import '../../storage/store_fixture.dart';
import 'game_runner_test.dart' show ScriptEngine, config;

final class FallibleTournaments implements TournamentStore {
  FallibleTournaments(this.base);
  final TournamentStore base;
  bool fail = false;
  Completer<void>? creating;
  @override
  Future<TournamentResult<Tournament>> create(Tournament initial) async {
    await creating?.future;
    return base.create(initial);
  }

  @override
  Future<TournamentResult<Tournament>> save(
    Tournament before,
    Tournament after,
    String pgn, {
    required String? expectedPgn,
  }) async => fail
      ? const TournamentFailed('Disk unavailable')
      : base.save(before, after, pgn, expectedPgn: expectedPgn);
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

void main() {
  late StoreFixture files;
  late TournamentRun run;
  late FallibleTournaments store;
  late PendingWrites pending;
  final launched = <ScriptEngine>[];
  final active = <bool>[];
  setUp(() async {
    files = await StoreFixture.create();
    pending = PendingWrites();
    launched.clear();
    active.clear();
    store = FallibleTournaments(
      FileTournaments(
        root: Directory(p.join(files.documents.path, 'engine_tournaments')),
        support: files.support,
        documents: files.store,
      ),
    );
    run = TournamentRun(
      store: store,
      pending: pending,
      activityChanged: active.add,
      launch: (_) async {
        final engine = ScriptEngine([launched.length.isEven ? 'e2e4' : 'e7e5']);
        launched.add(engine);
        return Started(engine);
      },
    );
  });
  tearDown(() async {
    run.dispose();
    await files.dispose();
  });
  test(
    'run commits complete results and all engines exit before idle',
    () async {
      await run.start(config(rules: {'maxMoves': 1}));
      expect(run.selected!.status, 'completed');
      expect(run.selected!.games.length, 2);
      expect(run.running, isFalse);
      expect(run.canRetry, isFalse);
      expect(active, [true, false]);
      expect(launched.every((e) => e.quitCalled), isTrue);
      expect(await pending.settle(), isNull);
      expect(
        await File(store.games(run.selected!.id).path).readAsString(),
        contains('1. e4 e5'),
      );
    },
  );
  test(
    'failed checkpoint stops new games, remains owned, and retry is exact',
    () async {
      store.fail = true;
      await run.start(config(rules: {'maxMoves': 1}));
      expect(run.canRetry, isTrue);
      expect(launched.length, 2);
      expect(await pending.settle(), contains('Disk unavailable'));
      final id = run.selected!.id;
      store.fail = false;
      await run.retrySave();
      expect(run.selected!.id, id);
      expect(run.selected!.status, 'stopped');
      expect(run.selected!.games.length, 1);
      expect(await pending.settle(), isNull);
      expect(run.canRetry, isFalse);
      final saved = await store.list() as TournamentSaved<List<Tournament>>;
      expect(saved.value.single.games.length, 1);
    },
  );
  test('close while initial save is pending starts no engine', () async {
    store.creating = Completer<void>();
    final work = run.start(config());
    await pumpEventQueue();
    run.stop();
    store.creating!.complete();
    await work;
    expect(launched, isEmpty);
    expect(run.selected!.status, 'stopped');
    expect(await pending.settle(), isNull);
  });
}
