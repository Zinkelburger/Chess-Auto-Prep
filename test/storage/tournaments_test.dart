import 'dart:io';
import 'dart:convert';
import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:chess_auto_prep/storage/tournaments.dart';
import 'package:crypto/crypto.dart';
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
    fail = false;
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
    'one damaged record reports its name without hiding other tournaments',
    () async {
      await store.create(initial());
      final broken = await Directory(p.join(root.path, 'broken')).create();
      await File(
        p.join(broken.path, 'tournament.json'),
      ).writeAsString('{broken');
      final result = await store.list() as TournamentSaved<List<Tournament>>;
      expect(result.value.map((t) => t.id), ['test']);
      expect(result.warnings.single, contains('broken'));
      expect(
        await File(p.join(broken.path, 'tournament.json')).readAsString(),
        '{broken',
      );
    },
  );
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
    'games that cannot be read for now keep the record for the next access',
    () async {
      final before = initial();
      final after = before.changed({'status': 'completed'});
      await store.create(before);
      fail = true;
      await store.save(before, after, pgn, expectedPgn: null);
      fail = false;
      final games = store.games('test').path;
      final record = File(p.join(root.path, 'test', '.v2-pending.json'));
      await Process.run('chmod', ['000', games]);
      final TournamentSaved<List<Tournament>> held;
      try {
        held = await store.list() as TournamentSaved<List<Tournament>>;
      } finally {
        await Process.run('chmod', ['644', games]);
      }
      expect(held.value, isEmpty);
      expect(held.warnings.single, contains('test'));
      expect(await record.exists(), isTrue);
      expect(files.quarantined(), isEmpty);

      final read = await store.list() as TournamentSaved<List<Tournament>>;
      expect(read.value.single.status, 'completed');
      expect(await File(games).readAsString(), pgn);
      expect(await record.exists(), isFalse);
      expect(files.quarantined(), isEmpty);
    },
    skip: !Platform.isLinux || Platform.environment['USER'] == 'root'
        ? 'requires Linux permissions without root'
        : false,
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
  test('checkpoints journal the new PGN once and leave no record', () async {
    var saved = initial();
    await store.create(saved);
    String? games;
    for (var n = 1; n <= 3; n++) {
      final next = saved.changed({
        'status': 'running',
        'games': [
          for (var i = 0; i < n; i++) {'gameIndex': i},
        ],
      });
      final text = [for (var i = 0; i < n; i++) pgn].join('\n');
      final result = await store.save(saved, next, text, expectedPgn: games);
      expect(result, isA<TournamentSaved<Tournament>>());
      saved = next;
      games = text;
    }
    expect(await File(store.games('test').path).readAsString(), games);
    final read = await store.list() as TournamentSaved<List<Tournament>>;
    expect(read.value.single.games.length, 3);
    final record = File(p.join(root.path, 'test', '.v2-pending.json'));
    expect(await record.exists(), isFalse);

    fail = true;
    final done = saved.changed({'status': 'completed'});
    await store.save(saved, done, '$games\n$pgn', expectedPgn: games);
    final journal = jsonDecode(await record.readAsString()) as Map;
    expect(journal['version'], 2);
    expect(journal.containsKey('pgnBefore'), isFalse);
    expect(
      journal['pgnBeforeSha256'],
      sha256.convert(utf8.encode(games!)).toString(),
    );
    expect(journal['pgnAfter'], '$games\n$pgn');
  });
  test('records left by a crash in either version recover', () async {
    final before = initial();
    final after = before.changed({'status': 'running'});
    final record = File(p.join(root.path, 'test', '.v2-pending.json'));
    final metadata = File(p.join(root.path, 'test', 'tournament.json'));
    Map<String, Object?> journal(int version, String? pgnBefore) => {
      'version': version,
      'before': metadata.readAsStringSync(),
      'after': jsonEncode({...after.json, 'timeLabel': after.config.timeLabel}),
      if (version == 1) 'pgnBefore': pgnBefore,
      if (version == 2 && pgnBefore != null)
        'pgnBeforeSha256': sha256.convert(utf8.encode(pgnBefore)).toString(),
      'pgnAfter': pgn,
    };

    const earlier = '[Event "Match"]\n[Result "*"]\n\n*\n';
    await store.create(before);
    await files.put(store.games('test'), earlier);
    await record.writeAsString(jsonEncode(journal(1, earlier)));
    final done = after.changed({'status': 'completed'});
    expect(
      await store.save(after, done, '$pgn\n$pgn', expectedPgn: pgn),
      isA<TournamentSaved<Tournament>>(),
    );
    expect(await File(store.games('test').path).readAsString(), '$pgn\n$pgn');
    expect(await record.exists(), isFalse);
    expect(await store.remove(done), isA<TournamentSaved<void>>());
    final first = await Directory(
      p.join(root.path, '.trash'),
    ).list().map((e) => e.path).toList();

    await store.create(before);
    await record.writeAsString(jsonEncode(journal(2, null)));
    expect(await store.remove(after), isA<TournamentSaved<void>>());
    final trash = await Directory(
      p.join(root.path, '.trash'),
    ).list().map((e) => e.path).where((e) => !first.contains(e)).single;
    expect(await File(p.join(trash, 'games.pgn')).readAsString(), pgn);
    expect(
      jsonDecode(await File(p.join(trash, 'tournament.json')).readAsString()),
      containsPair('status', 'running'),
    );
  });
  for (final version in [1, 2]) {
    test('a version $version record whose earlier PGN matches neither text '
        'is set aside', () async {
      final before = initial();
      await store.create(before);
      await files.put(store.games('test'), '1. d4 *\n');
      final record = File(p.join(root.path, 'test', '.v2-pending.json'));
      await record.writeAsString(
        jsonEncode({
          'version': version,
          'before': File(
            p.join(root.path, 'test', 'tournament.json'),
          ).readAsStringSync(),
          'after': jsonEncode(before.changed({'status': 'running'}).json),
          if (version == 1) 'pgnBefore': 'other',
          if (version == 2)
            'pgnBeforeSha256': sha256.convert(utf8.encode('other')).toString(),
          'pgnAfter': pgn,
        }),
      );
      await store.list();
      expect(await File(store.games('test').path).readAsString(), '1. d4 *\n');
      expect(await record.exists(), isFalse);
      final entries = await files.support
          .list(recursive: true)
          .where((e) => e is File)
          .toList();
      expect(entries.any((e) => e.path.contains('quarantine')), isTrue);
    });
  }
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
  test('tournament.json names its time control as the app does, and a file '
      'written before that is still the same tournament', () async {
    final before = initial();
    await store.create(before);
    final metadata = File(p.join(root.path, 'test', 'tournament.json'));
    Map<String, Object?> onDisk() =>
        jsonDecode(metadata.readAsStringSync()) as Map<String, Object?>;
    expect(onDisk()['timeLabel'], before.config.timeLabel);

    await metadata.writeAsString(jsonEncode(before.json));
    final after = before.changed({'status': 'completed'});
    expect(
      await store.save(before, after, pgn, expectedPgn: null),
      isA<TournamentSaved<Tournament>>(),
    );
    expect(onDisk()['status'], 'completed');
    expect(onDisk()['timeLabel'], '2 s / move');
  });
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
