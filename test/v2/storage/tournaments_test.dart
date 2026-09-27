import 'dart:io';
import 'dart:convert';
import 'package:chess_auto_prep/v2/chess/tournament/config.dart';
import 'package:chess_auto_prep/v2/chess/tournament/result.dart';
import 'package:chess_auto_prep/v2/storage/tournaments.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'store_fixture.dart';

void main() {
  late StoreFixture files;
  late FileTournaments store;
  late Directory root;
  var fail = false;
  Tournament initial() => Tournament({
    'version': 1,
    'id': 'test',
    'createdAt': '2026-09-27',
    'status': 'pending',
    'config': {
      'name': 'Match',
      'engines': [
        TournamentEngine.bundled().json,
        TournamentEngine.bundled().json,
      ],
    },
    'games': <Object>[],
  });
  const pgn = '[Event "Match"]\n[Result "*"]\n\n1. e4 *\n';
  setUp(() async {
    files = await StoreFixture.create();
    root = Directory(p.join(files.documents.path, 'engine_tournaments'));
    store = FileTournaments(
      root: root,
      support: files.support,
      documents: files.store,
      afterPgn: () async {
        if (fail) throw StateError('simulated crash');
      },
    );
  });
  tearDown(() => files.dispose());
  test(
    'create, save and retry are idempotent; trash retains both files',
    () async {
      final before = initial();
      final after = before.changed({'status': 'completed'});
      expect(await store.create(before), isA<TournamentSaved<Tournament>>());
      expect(await store.create(before), isA<TournamentSaved<Tournament>>());
      expect(
        await store.save(before, after, pgn, expectedPgn: null),
        isA<TournamentSaved<Tournament>>(),
      );
      expect(
        await store.save(before, after, pgn, expectedPgn: null),
        isA<TournamentSaved<Tournament>>(),
      );
      expect(await store.remove(after), isA<TournamentSaved<void>>());
      final trash = await Directory(p.join(root.path, '.trash')).list().single;
      expect(await File(p.join(trash.path, 'games.pgn')).readAsString(), pgn);
      expect(
        await File(p.join(trash.path, 'tournament.json')).exists(),
        isTrue,
      );
    },
  );
  test(
    'restart completes metadata after crash between PGN and metadata',
    () async {
      final before = initial();
      final after = before.changed({'status': 'completed'});
      await store.create(before);
      fail = true;
      expect(
        await store.save(before, after, pgn, expectedPgn: null),
        isA<TournamentFailed<Tournament>>(),
      );
      expect(await File(store.games('test').path).readAsString(), pgn);
      fail = false;
      final read = await store.list() as TournamentSaved<List<Tournament>>;
      expect(read.value.single.status, 'completed');
      expect(
        await File(p.join(root.path, 'test', '.v2-pending.json')).exists(),
        isFalse,
      );
    },
  );
  test(
    'external PGN edit blocks save without discarding either version',
    () async {
      final before = initial();
      await store.create(before);
      final after = before.changed({'status': 'running'});
      await store.save(before, after, pgn, expectedPgn: null);
      const external = '[Event "External"]\n\n1. d4 *\n';
      await File(store.games('test').path).writeAsString(external);
      expect(
        await store.save(
          after,
          after.changed({'status': 'completed'}),
          pgn,
          expectedPgn: pgn,
        ),
        isA<TournamentFailed<Tournament>>(),
      );
      expect(await File(store.games('test').path).readAsString(), external);
    },
  );
  test(
    'conflicting recovery quarantines its complete record and preserves PGN',
    () async {
      final before = initial();
      await store.create(before);
      fail = true;
      await store.save(
        before,
        before.changed({'status': 'completed'}),
        pgn,
        expectedPgn: null,
      );
      final file = File(store.games('test').path);
      await file.writeAsString('1. d4 *\n');
      fail = false;
      await store.list();
      expect(await file.readAsString(), '1. d4 *\n');
      expect(
        await File(p.join(root.path, 'test', '.v2-pending.json')).exists(),
        isFalse,
      );
      final entries = await files.support
          .list(recursive: true)
          .where((e) => e is File)
          .toList();
      expect(entries.any((e) => e.path.contains('quarantine')), isTrue);
    },
  );
  test('registry preserves unknown fields and refuses stale writes', () async {
    final engine = TournamentEngine({
      ...TournamentEngine.bundled().json,
      'future': {'preserve': true},
    });
    await store.saveEngines([], [engine]);
    final read =
        await store.engines() as TournamentSaved<List<TournamentEngine>>;
    expect(read.value.single.json['future'], {'preserve': true});
    await File(p.join(root.path, 'engines.json')).writeAsString(
      jsonEncode([
        {'id': 'external', 'name': 'External'},
      ]),
    );
    expect(
      await store.saveEngines([engine], []),
      isA<TournamentFailed<void>>(),
    );
    expect(
      await File(p.join(root.path, 'engines.json')).readAsString(),
      contains('External'),
    );
  });
}
