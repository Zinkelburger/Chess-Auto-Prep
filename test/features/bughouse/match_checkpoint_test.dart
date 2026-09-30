import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/bughouse/match.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/features/bughouse/matches.dart';
import 'package:chess_auto_prep/features/bughouse/table_search.dart';
import 'package:chess_auto_prep/storage/bughouse_matches.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/scripted_bughouse.dart';

void main() {
  test(
    'one unreadable match folder is named, not hiding or blocking the rest',
    () async {
      final documents = await Directory.systemTemp.createTemp('v2-matches-');
      addTearDown(() => documents.delete(recursive: true));
      final root = p.join(documents.path, 'bughouse_matches');
      final store = MatchFolder(root);
      final made =
          await store.create(
                MatchConfig(
                  name: 'Good',
                  startDualFen: TablePosition.initial.dualFen,
                  seed: 42,
                  games: 1,
                  maxPlies: 2,
                ),
                DateTime(2026),
              )
              as MatchCreated;
      final broken = File(p.join(root, 'broken', 'match.json'));
      await broken.parent.create();
      await broken.writeAsString('not JSON');
      final outside = ScriptedBughouse();
      final lab = BughouseLab();
      final tables = TableSearch(
        lab: lab,
        book: outside.book,
        startEngine: () => outside.outside.launch(cores: 2),
      );
      final matches = Matches(
        store: store,
        lab: lab,
        tables: tables,
        startEngine: () => outside.outside.launch(cores: 2),
      );
      addTearDown(matches.dispose);
      addTearDown(tables.dispose);
      addTearDown(lab.dispose);
      await matches.load();
      expect(matches.matches.map((m) => m.id), [made.match.id]);
      expect(
        matches.problem,
        isA<UnreadableMatches>().having((u) => u.folders, 'folders', [
          'broken',
        ]),
      );
      await matches.resume(made.match.id);
      expect(matches.problem, isNot(isA<CannotLoad>()));
      expect(matches.selected!.status, MatchStatus.completed);
      expect(await broken.readAsString(), 'not JSON');
    },
  );

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
      expect(matches.canDiscard, isFalse);
      await matches.discardSave();
      expect(matches.writable, isFalse);
      await matches.start(config);
      expect(outside.starts, 1);
      outside.engine.quitting = null;
      await matches.retrySave();
      expect(await pending.settle(), isNull);
      expect(outside.engine.gone, isTrue);
      expect(matches.writable, isTrue);
    },
  );

  test(
    'discarding a failed checkpoint frees new matches without restart',
    () async {
      final outside = ScriptedBughouse();
      final store = _FailingStore(1);
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
      addTearDown(matches.dispose);
      addTearDown(tables.dispose);
      addTearDown(lab.dispose);
      final config = MatchConfig(
        name: 'Discard',
        startDualFen: TablePosition.initial.dualFen,
        seed: 42,
        games: 1,
        maxPlies: 2,
      );
      await matches.start(config);
      expect(matches.writable, isFalse);
      expect(matches.canDiscard, isTrue);
      await matches.discardSave();
      expect(matches.writable, isTrue);
      expect(await pending.settle(), isNull);
      store.blocked = false;
      await matches.start(config);
      expect(matches.problem, isNull);
      expect(matches.selected!.status, MatchStatus.completed);
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

  test(
    'a foreign write between checkpoints stops the run and is kept',
    () async {
      final documents = await Directory.systemTemp.createTemp('v2-matches-');
      addTearDown(() => documents.delete(recursive: true));
      final store = _ForeignAfterFirstGame(
        MatchFolder(p.join(documents.path, 'bughouse_matches')),
      );
      final outside = ScriptedBughouse();
      final lab = BughouseLab();
      final tables = TableSearch(
        lab: lab,
        book: outside.book,
        startEngine: () => outside.outside.launch(cores: 2),
      );
      final matches = Matches(
        store: store,
        lab: lab,
        tables: tables,
        startEngine: () => outside.outside.launch(cores: 2),
      );
      addTearDown(matches.dispose);
      addTearDown(tables.dispose);
      addTearDown(lab.dispose);
      await matches.start(
        MatchConfig(
          name: 'Foreign',
          startDualFen: TablePosition.initial.dualFen,
          seed: 42,
          games: 3,
          maxPlies: 2,
        ),
      );
      expect(store.foreign, isNotNull);
      expect(
        matches.problem,
        isA<CannotSave>().having(
          (c) => c.detail,
          'detail',
          contains('another instance'),
        ),
      );
      expect(await store.metadata!.readAsString(), store.foreign);
    },
  );

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
  Future<MatchListing> list() => delegate.list();
  @override
  Future<StoredMatch?> read(String id) => delegate.read(id);
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

/// Another writer replaces `match.json` right after the first game's
/// checkpoint.
final class _ForeignAfterFirstGame implements MatchStore {
  _ForeignAfterFirstGame(this.delegate);
  final MatchFolder delegate;
  File? metadata;
  String? foreign;
  @override
  Future<MatchCreate> create(MatchConfig config, DateTime now) =>
      delegate.create(config, now);
  @override
  Future<MatchListing> list() => delegate.list();
  @override
  Future<StoredMatch?> read(String id) => delegate.read(id);
  @override
  Future<MatchWriteProblem> delete(String id) => delegate.delete(id);
  @override
  Future<MatchWriteProblem> save(
    StoredMatch match, {
    MatchCheckpoint? checkpoint,
  }) async {
    final problem = await delegate.save(match, checkpoint: checkpoint);
    if (problem == null && match.games.length == 1 && foreign == null) {
      final file = metadata = File(
        p.join(delegate.root, match.id, 'match.json'),
      );
      await file.writeAsString(
        foreign = jsonEncode(
          match.copyWith(status: MatchStatus.failed, error: 'other').toJson(),
        ),
      );
    }
    return problem;
  }
}
