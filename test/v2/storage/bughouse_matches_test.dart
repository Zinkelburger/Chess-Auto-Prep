import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/bughouse/match.dart';
import 'package:chess_auto_prep/v2/storage/bughouse_matches.dart';
import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_tournament.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_tournament_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory documents;
  late String root;
  late MatchFolder store;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('v2-matches-');
    root = p.join(documents.path, 'bughouse_matches');
    store = MatchFolder(root);
  });

  tearDown(() => documents.delete(recursive: true));

  const config = MatchConfig(
    name: 'e4 e5!',
    startDualFen:
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1|'
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1',
    seed: 7,
  );

  test(
    'native v1 writer output remains readable and its JSON is unchanged',
    () async {
      final fixture =
          jsonDecode(
                await File(
                  'test/fixtures/v2_bughouse/old_match.json',
                ).readAsString(),
              )
              as Map<String, Object?>;
      final old = StoredBughouseTournament.fromJson(
        fixture,
        directoryPath: p.join(root, 'e4-d5'),
      );
      await BughouseTournamentStore(Directory(root)).save(old);
      final metadata = File(p.join(root, old.id, 'match.json'));
      final original = await metadata.readAsString();
      final decoded = decodeMatchCheckpoint(original);
      expect(decoded.toJson(), old.toJson());
      final reopened = (await store.list()).single;
      expect(reopened.toJson(), old.toJson());
      expect(await metadata.readAsString(), original);
      expect(
        await File(p.join(root, old.id, 'games.bpgn')).readAsString(),
        matchBpgn(reopened),
      );
    },
  );

  test(
    'cached replay and export never authorize changed moves or headers',
    () async {
      final raw = await File(
        'test/fixtures/v2_bughouse/old_match.json',
      ).readAsString();
      final match = decodeMatchCheckpoint(raw);
      final folder = Directory(p.join(root, match.id));
      await folder.create(recursive: true);
      final file = File(p.join(folder.path, 'match.json'));
      await file.writeAsString(raw);
      await store.list();
      final changed = jsonDecode(raw) as Map<String, Object?>;
      final first = (changed['games'] as List).first as Map<String, Object?>;
      first['whiteName'] = 'Changed player';
      await file.writeAsString(jsonEncode(changed));
      final updated = (await store.list()).single;
      expect(
        await File(p.join(folder.path, 'games.bpgn')).readAsString(),
        matchBpgn(updated),
      );
      first['moves'] = ['1e2e5'];
      await file.writeAsString(jsonEncode(changed));
      await expectLater(store.list(), throwsA(isA<FileSystemException>()));
    },
  );

  test('a new match is a folder named after it, never over another', () async {
    final first = await store.create(config, DateTime(2026, 9, 23));
    final second = await store.create(config, DateTime(2026, 9, 24));
    expect((first as MatchCreated).match.id, 'e4-e5');
    expect((second as MatchCreated).match.id, 'e4-e5-2');
    final listed = await store.list();
    expect(listed.map((m) => m.id), ['e4-e5-2', 'e4-e5']);
    expect(listed.first.status, MatchStatus.pending);
  });

  test('saving writes match.json and games.bpgn, both readable', () async {
    final created =
        (await store.create(config, DateTime(2026))) as MatchCreated;
    final game = (
      number: 1,
      whiteIndex: 0,
      blackIndex: 1,
      whiteName: 'Hivemind A',
      blackName: 'Hivemind B',
      result: MatchResult.whiteWins,
      ending: MatchEnding.checkmate,
      detail: 'board 2',
      moves: ['1e2e4', '2d2d4'],
      startedAt: DateTime(2026),
      durationMs: 10,
    );
    final saved = created.match.copyWith(
      status: MatchStatus.completed,
      games: [game],
    );
    expect(await store.save(saved), isNull);
    final json = jsonDecode(
      await File(p.join(root, 'e4-e5', 'match.json')).readAsString(),
    );
    // The keys the old app's reader looks for.
    expect(
      (json as Map).keys,
      containsAll(['version', 'id', 'config', 'games']),
    );
    expect(json['status'], 'completed');
    final bpgn = await File(p.join(root, 'e4-e5', 'games.bpgn')).readAsString();
    expect(bpgn, contains('1A. e4 1B. d4'));
    final again = (await store.list()).single;
    expect(again.games.single.moves, ['1e2e4', '2d2d4']);
  });

  for (final oldExport in [null, 'stale derived export']) {
    test(
      'reopening repairs a missing or stale derived BPGN export: $oldExport',
      () async {
        final made = await store.create(config, DateTime(2026)) as MatchCreated;
        final export = File(p.join(root, made.match.id, 'games.bpgn'));
        if (oldExport != null) await export.writeAsString(oldExport);
        final fresh = MatchFolder(root);
        final reopened = (await fresh.list()).single;
        expect(await export.readAsString(), matchBpgn(reopened));
      },
    );
  }

  test('unknown metadata version never repairs its derived export', () async {
    final made = await store.create(config, DateTime(2026)) as MatchCreated;
    final folder = p.join(root, made.match.id);
    await File(
      p.join(folder, 'match.json'),
    ).writeAsString(jsonEncode({...made.match.toJson(), 'version': 2}));
    final export = File(p.join(folder, 'games.bpgn'));
    await export.writeAsString('future export');
    await expectLater(
      MatchFolder(root).list(),
      throwsA(isA<FileSystemException>()),
    );
    expect(await export.readAsString(), 'future export');
  });

  for (final file in ['match.json', 'games.bpgn']) {
    test(
      'lost acknowledgment after $file retries the exact checkpoint',
      () async {
        final made = await store.create(config, DateTime(2026)) as MatchCreated;
        final saved = made.match.copyWith(status: MatchStatus.completed);
        var fail = true;
        final failing = MatchFolder(
          root,
          publish: (path, bytes) async {
            await replaceFile(path, bytes);
            if (fail && p.basename(path) == file) {
              throw const FileSystemException('ack lost');
            }
          },
        );
        final token = MatchCheckpoint();
        expect(
          await failing.save(saved, checkpoint: token),
          contains('ack lost'),
        );
        final reopened = (await MatchFolder(root).list()).single;
        expect(reopened.status, MatchStatus.completed);
        expect(
          await File(p.join(root, made.match.id, 'games.bpgn')).readAsString(),
          matchBpgn(reopened),
        );
        fail = false;
        expect(await failing.save(saved, checkpoint: token), isNull);
        expect(await failing.save(saved, checkpoint: token), isNull);
        expect(await failing.save(made.match, checkpoint: token), isNotNull);
      },
    );
  }

  test('unknown checkpoint outcome refuses a later foreign edit', () async {
    final made = await store.create(config, DateTime(2026)) as MatchCreated;
    final saved = made.match.copyWith(status: MatchStatus.completed);
    var fail = true;
    final failing = MatchFolder(
      root,
      publish: (path, bytes) async {
        await replaceFile(path, bytes);
        if (fail) throw const FileSystemException('ack lost');
      },
    );
    final token = MatchCheckpoint();
    expect(await failing.save(saved, checkpoint: token), isNotNull);
    final metadata = File(p.join(root, made.match.id, 'match.json'));
    final foreign = jsonEncode(
      made.match
          .copyWith(status: MatchStatus.failed, error: 'other writer')
          .toJson(),
    );
    await metadata.writeAsString(foreign);
    fail = false;
    expect(
      await failing.save(saved, checkpoint: token),
      contains('another instance'),
    );
    expect(await metadata.readAsString(), foreign);
  });

  for (final participant in [
    'games.bpgn',
    '.games.bpgn.v2-tmp',
    '.match.json.v2-tmp',
  ]) {
    test(
      'linked $participant never writes through to its target',
      () async {
        final made = await store.create(config, DateTime(2026)) as MatchCreated;
        final target = File(p.join(documents.path, 'outside'));
        await target.writeAsString('keep');
        await Link(
          p.join(root, made.match.id, participant),
        ).create(target.path);
        if (participant == 'games.bpgn') {
          await expectLater(MatchFolder(root).list(), throwsA(anything));
        } else {
          // A staged link is only a leftover: it is removed as a link.
          await MatchFolder(root).list();
        }
        expect(await target.readAsString(), 'keep');
        // A damaged export refuses; a leftover stage does not.
        expect(
          await store.save(made.match),
          participant == 'games.bpgn' ? isNotNull : isNull,
        );
        expect(await target.readAsString(), 'keep');
      },
      skip: Platform.isWindows
          ? 'Windows symbolic link privileges unavailable'
          : false,
    );
  }

  test('malformed known fields cannot authorize derived repair', () async {
    final made = await store.create(config, DateTime(2026)) as MatchCreated;
    final folder = p.join(root, made.match.id);
    await File(p.join(folder, 'match.json')).writeAsString(
      jsonEncode({
        ...made.match.toJson(),
        'games': [
          {'moves': []},
        ],
      }),
    );
    final export = File(p.join(folder, 'games.bpgn'));
    await export.writeAsString('keep');
    await expectLater(
      MatchFolder(root).list(),
      throwsA(isA<FileSystemException>()),
    );
    expect(await export.readAsString(), 'keep');
  });

  test(
    'delete waits for the same match checkpoint before retiring its directory',
    () async {
      final made = await store.create(config, DateTime(2026)) as MatchCreated;
      final entered = Completer<void>();
      final release = Completer<void>();
      final held = MatchFolder(
        root,
        publish: (path, bytes) async {
          if (p.basename(path) == 'match.json') {
            entered.complete();
            await release.future;
          }
          await replaceFile(path, bytes);
        },
      );
      final saving = held.save(made.match);
      await entered.future;
      var deleted = false;
      final deleting = store.delete(made.match.id).then((value) {
        deleted = true;
        return value;
      });
      await pumpEventQueue(times: 50);
      expect(deleted, isFalse);
      release.complete();
      expect(await saving, isNull);
      expect(await deleting, isNull);
      expect(await Directory(p.join(root, made.match.id)).exists(), isFalse);
    },
  );

  test(
    'invalid checkpoint bytes fail without exposing their decode source',
    () async {
      final made = await store.create(config, DateTime(2026)) as MatchCreated;
      final metadata = File(p.join(root, made.match.id, 'match.json'));
      final bytes = [...utf8.encode('private preparation'), 255];
      await metadata.writeAsBytes(bytes);
      final problem = await store.save(made.match);
      expect(problem, contains('Match file is not valid UTF-8.'));
      expect(problem, isNot(contains('private preparation')));
      expect(await metadata.readAsBytes(), bytes);
    },
  );

  test('an existing damaged match makes the listing unavailable', () async {
    await store.create(config, DateTime(2026));
    await Directory(p.join(root, 'broken')).create();
    await File(p.join(root, 'broken', 'match.json')).writeAsString('not JSON');
    await expectLater(store.list(), throwsA(isA<FileSystemException>()));
  });

  test('delete moves the folder to .trash, which the list skips', () async {
    await store.create(config, DateTime(2026));
    expect(await store.delete('e4-e5'), isNull);
    expect(await store.list(), isEmpty);
    final trash = Directory(p.join(root, '.trash'));
    expect(await trash.list().length, 1);
  });

  test(
    'new checkpoint flushes ancestry through only the captured existing parent',
    () async {
      final flushed = <String>[];
      final nested = p.join(documents.path, 'new', 'profile', 'matches');
      final creating = MatchFolder(
        nested,
        synchronize: (path) async => flushed.add(path),
      );
      final made =
          await creating.create(config, DateTime(2026)) as MatchCreated;
      expect(flushed, [
        p.join(nested, made.match.id),
        nested,
        p.dirname(nested),
        p.dirname(p.dirname(nested)),
        documents.path,
      ]);
    },
    skip: Platform.isWindows ? 'Directory flush unsupported on Windows' : false,
  );

  test(
    'failed ancestry flush cannot confirm creation; fresh reopen preserves JSON',
    () async {
      final creating = MatchFolder(
        root,
        synchronize: (_) async =>
            throw const FileSystemException('directory flush failed'),
      );
      expect(
        await creating.create(config, DateTime(2026)),
        isA<MatchCreateFailed>(),
      );
      expect((await MatchFolder(root).list()).single.config.name, config.name);
    },
    skip: Platform.isWindows ? 'Directory flush unsupported on Windows' : false,
  );

  test('an occupied regular file gets a new match-name suffix', () async {
    await Directory(root).create();
    final existing = File(p.join(root, 'e4-e5'));
    await existing.writeAsString('keep');
    final made = await store.create(config, DateTime(2026)) as MatchCreated;
    expect(made.match.id, 'e4-e5-2');
    expect(await existing.readAsString(), 'keep');
  });

  test('concurrent new matches allocate different owned directories', () async {
    final outcomes = await Future.wait([
      MatchFolder(root).create(config, DateTime(2026)),
      MatchFolder(root).create(config, DateTime(2026)),
    ]);
    expect(outcomes, everyElement(isA<MatchCreated>()));
    expect(
      outcomes.cast<MatchCreated>().map((value) => value.match.id).toSet(),
      hasLength(2),
    );
    expect(await store.list(), hasLength(2));
  });

  test('a folder that cannot be made is said, and nothing is kept', () async {
    // A file where the matches folder should be.
    await File(root).writeAsString('in the way');
    final made = await store.create(config, DateTime(2026));
    expect(made, isA<MatchCreateFailed>());
    await expectLater(store.list(), throwsA(isA<FileSystemException>()));
  });
}
