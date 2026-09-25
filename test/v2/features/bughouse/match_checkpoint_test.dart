import 'package:chess_auto_prep/v2/chess/bughouse/match.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/v2/features/bughouse/matches.dart';
import 'package:chess_auto_prep/v2/features/bughouse/table_search.dart';
import 'package:chess_auto_prep/v2/storage/bughouse_matches.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

void main() {
  test(
    'engine quit failure remains owned and blocks a new match until retry',
    () async {
      final outside = ScriptedBughouse();
      final pending = PendingWrites();
      final lab = BughouseLab();
      final tables = TableSearch(
        lab: lab,
        book: outside.book,
        startEngine: () => outside.outside.launch(cores: 2),
      );
      final matches = Matches(
        store: outside.matches,
        pendingWrites: pending,
        lab: lab,
        tables: tables,
        startEngine: () => outside.outside.launch(cores: 2),
      );
      addTearDown(matches.dispose);
      addTearDown(tables.dispose);
      addTearDown(lab.dispose);
      outside.engine.quitting = () async =>
          throw StateError('exit unconfirmed');
      final config = MatchConfig(
        name: 'Quit',
        startDualFen: TablePosition.initial.dualFen,
        seed: 42,
        games: 1,
        maxPlies: 2,
      );
      await matches.start(config);
      expect(matches.problem, isA<CannotSave>());
      expect(matches.selected!.status, isNot(MatchStatus.completed));
      expect(await pending.settle(), contains('exit unconfirmed'));
      await matches.start(config);
      expect(outside.starts, 1);
      outside.engine.quitting = null;
      await matches.retrySave();
      expect(await pending.settle(), isNull);
      expect(outside.engine.gone, isTrue);
      expect(matches.writable, isTrue);
    },
  );

  for (final factory in [true, false]) {
    test(
      'unexpected ${factory ? 'factory' : 'search'} rejection stops and settles the run',
      () async {
        final outside = ScriptedBughouse();
        final pending = PendingWrites();
        final lab = BughouseLab();
        final tables = TableSearch(
          lab: lab,
          book: outside.book,
          startEngine: () => outside.outside.launch(cores: 2),
        );
        outside.engine.answer = (_) => throw StateError('search rejected');
        final matches = Matches(
          store: outside.matches,
          pendingWrites: pending,
          lab: lab,
          tables: tables,
          startEngine: () async {
            if (factory) throw StateError('factory rejected');
            return outside.outside.launch(cores: 2);
          },
        );
        addTearDown(matches.dispose);
        addTearDown(tables.dispose);
        addTearDown(lab.dispose);
        addTearDown(outside.engine.crash);
        await expectLater(
          matches.start(
            MatchConfig(
              name: 'Unexpected',
              startDualFen: TablePosition.initial.dualFen,
              seed: 42,
              games: 1,
              maxPlies: 2,
            ),
          ),
          completes,
        );
        expect(matches.running, isNull);
        expect(matches.selected!.status, MatchStatus.failed);
        expect(matches.problem, isA<MatchEngineFailed>());
        expect(await pending.settle(), isNull);
        if (!factory) expect(outside.engine.gone, isTrue);
      },
    );
  }

  for (final failAt in [1, 2, 4]) {
    test(
      'checkpoint $failAt failure stops work and survives owner disposal',
      () async {
        final outside = ScriptedBughouse();
        final store = _FailingStore(failAt);
        final pending = PendingWrites();
        final lab = BughouseLab();
        final tables = TableSearch(
          lab: lab,
          book: outside.book,
          startEngine: () => outside.outside.launch(cores: 2),
        );
        final matches = Matches(
          store: store,
          pendingWrites: pending,
          lab: lab,
          tables: tables,
          startEngine: () => outside.outside.launch(cores: 2),
        );
        addTearDown(lab.dispose);
        addTearDown(tables.dispose);
        await matches.start(
          MatchConfig(
            name: 'Test',
            startDualFen: TablePosition.initial.dualFen,
            seed: 42,
            games: 2,
            maxPlies: 4,
          ),
        );
        expect(matches.problem, isA<CannotSave>());
        expect(store.attempted, hasLength(failAt));
        expect(matches.selected!.status, isNot(MatchStatus.completed));
        expect(matches.running, isNull);
        if (failAt == 1) expect(outside.starts, 0);
        if (failAt > 1) expect(outside.engine.gone, isTrue);
        final accepted = store.attempted.last;
        final searches = outside.engine.asked.length;
        matches.dispose();
        expect(await pending.settle(), contains('disk full'));
        store.blocked = false;
        await pending.retry(store);
        expect(await pending.settle(), isNull);
        expect(store.saved.values.single.toJson(), accepted.toJson());
        expect(outside.engine.asked.length, searches);
      },
    );
  }
}

final class _FailingStore implements MatchStore {
  _FailingStore(this.failAt);
  final int failAt;
  bool blocked = true;
  final delegate = ScriptedMatchStore();
  Map<String, StoredMatch> get saved => delegate.saved;
  final attempted = <StoredMatch>[];
  @override
  Future<MatchCreate> create(MatchConfig config, DateTime now) =>
      delegate.create(config, now);
  @override
  Future<List<StoredMatch>> list() => delegate.list();
  @override
  Future<MatchWriteProblem> delete(String id) => delegate.delete(id);
  @override
  Future<MatchWriteProblem> save(
    StoredMatch match, {
    MatchCheckpoint? checkpoint,
  }) async {
    attempted.add(match);
    if (blocked && attempted.length >= failAt) return 'disk full';
    return delegate.save(match);
  }
}
