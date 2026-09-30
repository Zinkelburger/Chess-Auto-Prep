import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/bughouse/match.dart';
import 'package:chess_auto_prep/storage/bughouse_matches.dart';
import 'package:chess_auto_prep/storage/atomic_write.dart';
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
      // What the old app's store wrote for old_match.json, recorded once:
      // its match.json and games.bpgn bytes and the model's own JSON.
      final written =
          jsonDecode(
                await File(
                  'test/fixtures/legacy/bughouse_v1_match.json',
                ).readAsString(),
              )
              as Map<String, Object?>;
      final id = written['id'] as String;
      final folder = await Directory(p.join(root, id)).create(recursive: true);
      final metadata = File(p.join(folder.path, 'match.json'));
      await metadata.writeAsString(written['match.json'] as String);
      await File(
        p.join(folder.path, 'games.bpgn'),
      ).writeAsString(written['games.bpgn'] as String);
      final original = await metadata.readAsString();
      final decoded = decodeMatchCheckpoint(original);
      expect(decoded.toJson(), written['toJson']);
      final reopened = (await store.list()).matches.single;
      expect(reopened.toJson(), written['toJson']);
      expect(await metadata.readAsString(), original);
      expect(
        await File(p.join(folder.path, 'games.bpgn')).readAsString(),
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
      final updated = (await store.list()).matches.single;
      expect(
        await File(p.join(folder.path, 'games.bpgn')).readAsString(),
        matchBpgn(updated),
      );
      first['moves'] = ['1e2e5'];
      await file.writeAsString(jsonEncode(changed));
      final refused = await store.list();
      expect(refused.matches, isEmpty);
      expect(refused.unreadable, [match.id]);
    },
  );

  test('a new match is a folder named after it, never over another', () async {
    final first = await store.create(config, DateTime(2026, 9, 23));
    final second = await store.create(config, DateTime(2026, 9, 24));
    expect((first as MatchCreated).match.id, 'e4-e5');
    expect((second as MatchCreated).match.id, 'e4-e5-2');
    final listed = (await store.list()).matches;
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
    final again = (await store.list()).matches.single;
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
        final reopened = (await fresh.list()).matches.single;
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
    final listing = await MatchFolder(root).list();
    expect(listing.matches, isEmpty);
    expect(listing.unreadable, [made.match.id]);
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
        // Only match.json decides the checkpoint; the export is best effort.
        expect(
          await failing.save(saved, checkpoint: token),
          file == 'match.json' ? contains('ack lost') : isNull,
        );
        final reopened = (await MatchFolder(root).list()).matches.single;
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

  MatchGame game(int number) => (
    number: number,
    whiteIndex: 0,
    blackIndex: 1,
    whiteName: 'Hivemind A',
    blackName: 'Hivemind B',
    result: MatchResult.draw,
    ending: MatchEnding.maxMoves,
    detail: 'board 1',
    moves: const ['1e2e4'],
    startedAt: DateTime(2026),
    durationMs: 10,
  );

  test(
    'a chained checkpoint refuses a foreign edit made since the last write',
    () async {
      final made = await store.create(config, DateTime(2026)) as MatchCreated;
      final running = made.match.copyWith(status: MatchStatus.running);
      final first = MatchCheckpoint();
      expect(
        await store.save(running.copyWith(games: [game(1)]), checkpoint: first),
        isNull,
      );
      final metadata = File(p.join(root, made.match.id, 'match.json'));
      final foreign = jsonEncode(
        made.match
            .copyWith(status: MatchStatus.failed, error: 'other writer')
            .toJson(),
      );
      await metadata.writeAsString(foreign);
      expect(
        await store.save(
          running.copyWith(games: [game(1), game(2)]),
          checkpoint: MatchCheckpoint(following: first),
        ),
        contains('another instance'),
      );
      expect(await metadata.readAsString(), foreign);
    },
  );

  test('a chained checkpoint refuses a match folder replaced since', () async {
    final made = await store.create(config, DateTime(2026)) as MatchCreated;
    final running = made.match.copyWith(status: MatchStatus.running);
    final first = MatchCheckpoint();
    expect(
      await store.save(running.copyWith(games: [game(1)]), checkpoint: first),
      isNull,
    );
    final folder = Directory(p.join(root, made.match.id));
    final metadata = File(p.join(folder.path, 'match.json'));
    final written = await metadata.readAsString();
    await folder.rename('${folder.path}.away');
    await folder.create();
    await metadata.writeAsString(written);
    expect(
      await store.save(
        running.copyWith(games: [game(1), game(2)]),
        checkpoint: MatchCheckpoint(following: first),
      ),
      contains('directory changed'),
    );
    expect(await metadata.readAsString(), written);
  });

  test(
    'a chained checkpoint over its own last write saves and retries',
    () async {
      final made = await store.create(config, DateTime(2026)) as MatchCreated;
      final running = made.match.copyWith(status: MatchStatus.running);
      final first = MatchCheckpoint();
      expect(
        await store.save(running.copyWith(games: [game(1)]), checkpoint: first),
        isNull,
      );
      final second = MatchCheckpoint(following: first);
      final two = running.copyWith(games: [game(1), game(2)]);
      expect(await store.save(two, checkpoint: second), isNull);
      expect(await store.save(two, checkpoint: second), isNull);
      expect((await store.read(made.match.id))!.games, hasLength(2));
      var fail = true;
      final failing = MatchFolder(
        root,
        publish: (path, bytes) async {
          await replaceFile(path, bytes);
          if (fail) throw const FileSystemException('ack lost');
        },
      );
      final third = MatchCheckpoint(following: second);
      final three = two.copyWith(games: [...two.games, game(3)]);
      expect(
        await failing.save(three, checkpoint: third),
        contains('ack lost'),
      );
      fail = false;
      expect(await failing.save(three, checkpoint: third), isNull);
      expect((await store.read(made.match.id))!.games, hasLength(3));
    },
  );

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
        // A linked export is skipped and logged; a staged link is only a
        // leftover and is removed as a link.
        expect((await MatchFolder(root).list()).matches, hasLength(1));
        expect(await target.readAsString(), 'keep');
        expect(await store.save(made.match), isNull);
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
    final listing = await MatchFolder(root).list();
    expect(listing.matches, isEmpty);
    expect(listing.unreadable, [made.match.id]);
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

  test('a damaged or newer match is named and skipped, never moved', () async {
    final made = await store.create(config, DateTime(2026)) as MatchCreated;
    final broken = File(p.join(root, 'broken', 'match.json'));
    await broken.parent.create();
    await broken.writeAsString('not JSON');
    final future = File(p.join(root, 'future', 'match.json'));
    await future.parent.create();
    final newer = jsonEncode({...made.match.toJson(), 'version': 2});
    await future.writeAsString(newer);
    final export = File(p.join(root, 'future', 'games.bpgn'));
    await export.writeAsString('future export');
    final listing = await store.list();
    expect(listing.matches.map((m) => m.id), ['e4-e5']);
    expect(listing.unreadable, unorderedEquals(['broken', 'future']));
    expect(await broken.readAsString(), 'not JSON');
    expect(await future.readAsString(), newer);
    expect(await export.readAsString(), 'future export');
    expect(await File(p.join(root, 'broken', 'games.bpgn')).exists(), isFalse);
    expect(await store.read('e4-e5'), isNotNull);
    await expectLater(
      store.read('broken'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await store.read('missing'), isNull);
  });

  test(
    'an undecodable games.bpgn never hides the match or refuses its save',
    () async {
      final made = await store.create(config, DateTime(2026)) as MatchCreated;
      final export = File(p.join(root, made.match.id, 'games.bpgn'));
      await export.writeAsBytes([0xC3, 0x28, 0xFF]);
      expect((await MatchFolder(root).list()).matches, hasLength(1));
      final completed = made.match.copyWith(status: MatchStatus.completed);
      expect(await store.save(completed), isNull);
      final metadata = File(p.join(root, made.match.id, 'match.json'));
      expect(
        decodeMatchCheckpoint(await metadata.readAsString()).status,
        MatchStatus.completed,
      );
      expect(await export.readAsBytes(), [0xC3, 0x28, 0xFF]);
      await export.delete();
      final reopened = (await MatchFolder(root).list()).matches.single;
      expect(await export.readAsString(), matchBpgn(reopened));
    },
  );

  test('a failing export publish is logged, not a failed checkpoint', () async {
    final made = await store.create(config, DateTime(2026)) as MatchCreated;
    await File(p.join(root, made.match.id, 'games.bpgn')).writeAsString('old');
    var fail = true;
    final failing = MatchFolder(
      root,
      publish: (path, bytes) async {
        if (fail && p.basename(path) == 'games.bpgn') {
          throw const FileSystemException('disk full');
        }
        await replaceFile(path, bytes);
      },
    );
    final completed = made.match.copyWith(status: MatchStatus.completed);
    expect(await failing.save(completed), isNull);
    final listed = (await failing.list()).matches.single;
    expect(listed.status, MatchStatus.completed);
    fail = false;
    await failing.list();
    expect(
      await File(p.join(root, made.match.id, 'games.bpgn')).readAsString(),
      matchBpgn(listed),
    );
  });

  test('delete moves the folder to .trash, which the list skips', () async {
    await store.create(config, DateTime(2026));
    expect(await store.delete('e4-e5'), isNull);
    expect((await store.list()).matches, isEmpty);
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
      expect(
        (await MatchFolder(root).list()).matches.single.config.name,
        config.name,
      );
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
    expect((await store.list()).matches, hasLength(2));
  });

  test('a folder that cannot be made is said, and nothing is kept', () async {
    // A file where the matches folder should be.
    await File(root).writeAsString('in the way');
    final made = await store.create(config, DateTime(2026));
    expect(made, isA<MatchCreateFailed>());
    await expectLater(store.list(), throwsA(isA<FileSystemException>()));
  });
}
