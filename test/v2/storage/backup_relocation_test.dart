import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/backups.dart';
import 'package:chess_auto_prep/v2/storage/backup_relocation.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late BackupArchive archive;
  const from = '1111111111111111';
  const to = '2222222222222222';
  const operation = 'move-123';
  const destination = '/Documents/repertoires/New.pgn';

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('backup-relocation-');
    archive = BackupArchive(Directory(p.join(temporary.path, 'backups')));
  });
  tearDown(() => temporary.delete(recursive: true));

  Future<void> keep(String id, String text) async {
    final bytes = utf8.encode(text);
    expect(
      await archive.record(
        id: id,
        documentPath: '/old/$id.pgn',
        bytes: bytes,
        hash: sha256.convert(bytes).toString(),
      ),
      isA<BackupRecorded>(),
    );
  }

  Future<BackupMove> planned() => archive.planMove(
    fromId: from,
    toId: to,
    documentPath: destination,
    operationId: operation,
  );
  BackupMove reloaded(BackupMove plan) => BackupMove.fromJson(
    jsonDecode(jsonEncode(plan.toJson())) as Map<String, Object?>,
  );
  File index(String id) =>
      File(p.join(archive.folderFor(id).path, 'index.json'));
  Future<Map<String, Object?>> readIndex(String id) async =>
      jsonDecode(await index(id).readAsString()) as Map<String, Object?>;
  Future<List<String>> texts(String id) async => [
    await for (final file in archive.folderFor(id).list())
      if (file is File && file.path.endsWith('.pgn')) await file.readAsString(),
  ];

  test(
    'absent histories plan and apply without creating a directory',
    () async {
      final plan = reloaded(await planned());
      expect(archive.root.existsSync(), isFalse);
      await archive.validateMove(plan);
      await archive.applyMove(plan);
      await archive.applyMove(plan);
      expect(archive.root.existsSync(), isFalse);
    },
  );

  test(
    'planning preserves bytes and unknown index fields; replay is exact',
    () async {
      await keep(from, 'my history');
      final original = await readIndex(from);
      original['future'] = {
        'tag': [1, false],
      };
      (original['versions'] as List).first['futureVersion'] = 'preserved';
      final raw = const JsonEncoder.withIndent('  ').convert(original);
      await index(from).writeAsString(raw);
      final plan = reloaded(await planned());
      expect(await index(from).readAsString(), raw);
      expect(archive.folderFor(to).existsSync(), isFalse);
      await archive.applyMove(plan);
      await archive.applyMove(plan);
      expect(await readIndex(to), {...original, 'path': destination});
      expect(await texts(to), ['my history']);
      expect(archive.folderFor(from).existsSync(), isFalse);
    },
  );

  for (final step in BackupMoveStep.values) {
    test(
      'lost $step acknowledgement recovers both histories forward',
      () async {
        await keep(from, 'incoming');
        await keep(to, 'occupant');
        final plan = reloaded(await planned());
        await expectLater(
          archive.applyMove(
            plan,
            testHook: (at) async {
              if (at == step) throw StateError('lost acknowledgement');
            },
          ),
          throwsA(isA<RecoveryRequired>()),
        );
        await archive.validateMove(plan);
        await archive.applyMove(reloaded(plan));
        await archive.applyMove(reloaded(plan));
        expect(await texts(to), ['incoming']);
        expect(await texts(plan.asideName), ['occupant']);
        expect((await readIndex(to))['path'], destination);
        expect((await readIndex(plan.asideName))['path'], '/old/$to.pgn');
        expect(archive.folderFor(from).existsSync(), isFalse);
      },
    );
  }

  test(
    'lost namespace flush retains the moved history for exact retry',
    () async {
      await keep(from, 'incoming');
      await keep(to, 'occupant');
      final plan = await planned();
      var calls = 0;
      final failing = BackupRelocation(
        archive.root,
        synchronize: (_) async {
          if (++calls == 2) throw StateError('flush failed');
        },
      );
      await expectLater(
        failing.applyMove(plan),
        throwsA(isA<RecoveryRequired>()),
      );
      expect(archive.folderFor(plan.asideName).existsSync(), isTrue);
      await archive.applyMove(reloaded(plan));
      expect(await texts(to), ['incoming']);
      expect(await texts(plan.asideName), ['occupant']);
    },
    skip: Platform.isWindows
        ? 'Directory flush is unavailable on Windows.'
        : false,
  );

  test(
    'missing index is derived read-only from plain and gzip version bytes',
    () async {
      final folder = archive.folderFor(from);
      await folder.create(recursive: true);
      await File(
        p.join(folder.path, '20260101T000000000Z-a.pgn'),
      ).writeAsString('plain');
      await File(
        p.join(folder.path, '20260102T000000000Z-b.pgn.gz'),
      ).writeAsBytes(gzip.encode(utf8.encode('compressed')));
      final plan = reloaded(await planned());
      expect(index(from).existsSync(), isFalse);
      await archive.applyMove(plan);
      expect((await readIndex(to))['versions'], hasLength(2));
      expect((await readIndex(to))['path'], destination);
    },
  );

  for (final changed in [
    'source index',
    'destination index',
    'version',
    'new entry',
    'directory',
  ]) {
    test(
      'foreign $changed change blocks before any ownership mutation',
      () async {
        await keep(from, 'incoming');
        await keep(to, 'occupant');
        final plan = await planned();
        if (changed.endsWith('index')) {
          final id = changed.startsWith('source') ? from : to;
          final value = await readIndex(id);
          value['external'] = true;
          await index(id).writeAsString(jsonEncode(value));
        } else if (changed == 'version') {
          final file = archive
              .folderFor(from)
              .listSync()
              .whereType<File>()
              .firstWhere((f) => f.path.endsWith('.pgn'));
          await file.writeAsString('foreign');
        } else if (changed == 'new entry') {
          await File(
            p.join(archive.folderFor(from).path, 'foreign.txt'),
          ).writeAsString('foreign');
        } else {
          await archive
              .folderFor(from)
              .rename('${archive.folderFor(from).path}-external');
          await archive.folderFor(from).create();
        }
        await expectLater(
          archive.applyMove(plan),
          throwsA(isA<RecoveryRequired>()),
        );
        expect(archive.folderFor(plan.asideName).existsSync(), isFalse);
        expect(await texts(to), ['occupant']);
      },
    );
  }

  test(
    'foreign aside index blocks recovery without moving the source',
    () async {
      await keep(from, 'incoming');
      await keep(to, 'occupant');
      final plan = await planned();
      await expectLater(
        archive.applyMove(
          plan,
          testHook: (step) async {
            if (step == BackupMoveStep.destinationAside)
              throw StateError('stop');
          },
        ),
        throwsA(isA<RecoveryRequired>()),
      );
      final value = await readIndex(plan.asideName);
      value['external'] = true;
      await index(plan.asideName).writeAsString(jsonEncode(value));
      await expectLater(
        archive.applyMove(plan),
        throwsA(isA<RecoveryRequired>()),
      );
      expect(await texts(from), ['incoming']);
      expect(archive.folderFor(to).existsSync(), isFalse);
    },
  );

  for (final kind in ['malformed index', 'symlink file', 'symlink directory']) {
    test('$kind refuses planning and preserves foreign entries', () async {
      await keep(from, 'incoming');
      if (kind == 'malformed index') {
        await index(from).writeAsString('{');
      } else if (kind == 'symlink file') {
        await Link(
          p.join(archive.folderFor(from).path, 'link.pgn'),
        ).create(index(from).path);
      } else {
        await Link(
          archive.folderFor(to).path,
        ).create(archive.folderFor(from).path);
      }
      await expectLater(planned(), throwsA(isA<RecoveryRequired>()));
      expect(archive.folderFor(from).existsSync(), isTrue);
    });
  }

  for (final step in BackupMoveStep.values) {
    test('initial preflight refuses backup state already past $step', () async {
      await keep(from, 'incoming');
      await keep(to, 'occupant');
      final plan = await planned();
      await archive.validateMove(plan, allowAfter: false);
      await expectLater(
        archive.applyMove(
          plan,
          testHook: (at) async {
            if (at == step) throw StateError('interrupted');
          },
        ),
        throwsA(isA<RecoveryRequired>()),
      );
      await expectLater(
        archive.validateMove(plan, allowAfter: false),
        throwsA(isA<RecoveryRequired>()),
      );
      await archive.validateMove(plan);
      await archive.applyMove(plan);
    });
  }

  test(
    'plans preserve marked index beforeimages and keep aside bytes exact',
    () async {
      await keep(from, 'incoming');
      await keep(to, 'occupant');
      final sourceRaw = '\ufeff${await index(from).readAsString()}';
      final targetRaw = '\ufeff${await index(to).readAsString()}';
      await index(from).writeAsString(sourceRaw);
      await index(to).writeAsString(targetRaw);
      final plan = reloaded(await planned());
      expect((plan.toJson()['source'] as Map)['index'], sourceRaw);
      expect((plan.toJson()['destination'] as Map)['index'], targetRaw);
      await archive.applyMove(plan);
      expect(await index(plan.asideName).readAsBytes(), utf8.encode(targetRaw));
      expect((await readIndex(to))['path'], destination);
    },
  );

  for (final id in [from, to]) {
    test(
      'a BOM-only external index change at $id refuses publication',
      () async {
        await keep(from, 'incoming');
        await keep(to, 'occupant');
        final plan = await planned();
        await index(
          id,
        ).writeAsString('\ufeff${await index(id).readAsString()}');
        await expectLater(
          archive.validateMove(plan),
          throwsA(isA<RecoveryRequired>()),
        );
        expect(archive.folderFor(from).existsSync(), isTrue);
        expect(archive.folderFor(plan.asideName).existsSync(), isFalse);
      },
    );
  }

  test('a completed plan never adopts later edits as its own', () async {
    await keep(from, 'incoming');
    await keep(to, 'occupant');
    final plan = await planned();
    await archive.applyMove(plan);
    final edited = await readIndex(to);
    edited['external'] = 'later';
    await index(to).writeAsString(jsonEncode(edited));
    await expectLater(
      archive.applyMove(reloaded(plan)),
      throwsA(isA<RecoveryRequired>()),
    );
    expect(await readIndex(to), edited);
    expect(await texts(plan.asideName), ['occupant']);
  });

  test(
    'preflight verifies rebuilt index bytes before namespace changes',
    () async {
      await keep(from, 'incoming');
      await index(from).delete();
      final plan = await planned();
      final value = plan.toJson();
      final after = jsonDecode(plan.indexAfter!) as Map<String, Object?>;
      (after['versions'] as List).first['hash'] = '0' * 64;
      value['indexAfter'] = jsonEncode(after);
      final altered = BackupMove.fromJson(value);
      await expectLater(
        archive.validateMove(altered),
        throwsA(isA<RecoveryRequired>()),
      );
      expect(archive.folderFor(from).existsSync(), isTrue);
      expect(archive.folderFor(to).existsSync(), isFalse);
    },
  );

  test('a missing-index plan cannot omit any recorded version', () async {
    await keep(from, 'incoming');
    await index(from).delete();
    final plan = await planned();
    final value = plan.toJson();
    value['indexAfter'] = jsonEncode({'path': destination, 'versions': []});
    expect(() => BackupMove.fromJson(value), throwsA(isA<RecoveryRequired>()));
    expect(index(from).existsSync(), isFalse);
  });

  test(
    'deserialized plans reject altered fields and another profile',
    () async {
      await keep(from, 'incoming');
      final plan = await planned();
      for (final entry in <String, Object?>{
        'version': 2,
        'asideName': '../escape',
        'fromId': '../escape',
        'indexAfter': '{}',
        'unknown': true,
      }.entries) {
        final value = plan.toJson()..[entry.key] = entry.value;
        expect(
          () => BackupMove.fromJson(value),
          throwsA(isA<RecoveryRequired>()),
        );
      }
      final other = BackupArchive(Directory(p.join(temporary.path, 'other')));
      await expectLater(
        other.applyMove(plan),
        throwsA(isA<RecoveryRequired>()),
      );
      expect(await texts(from), ['incoming']);
    },
  );

  test(
    'a source without history does not inherit destination history',
    () async {
      await keep(to, 'unrelated old occupant');
      final plan = await planned();
      await archive.applyMove(plan);
      await archive.applyMove(plan);
      expect(archive.folderFor(to).existsSync(), isFalse);
      expect(
        Directory(
          p.join(archive.root.path, '$to.superseded-$operation'),
        ).existsSync(),
        isTrue,
      );
    },
  );
}
