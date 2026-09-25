import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/repertoire_directory_mutations.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const trainingFiles = [
  'repertoire_reviews.csv',
  'repertoire_move_progress.csv',
  'repertoire_review_history.csv',
  'repertoire_move_attempts.jsonl',
];
const digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  late Directory profile;
  late Directory documents;
  late Directory support;
  late Directory notes;
  late File chapter;
  late String destination;
  IOStorageService storage() =>
      IOStorageService(documentsRoot: documents, supportRoot: support);
  String backupId(String path) => sha256
      .convert(
        utf8.encode(
          p.posix.joinAll(p.split(p.relative(path, from: documents.path))),
        ),
      )
      .toString()
      .substring(0, 16);
  Map<String, Object?> record([String state = 'complete']) {
    final index = {
      'path': chapter.path,
      'versions': [
        {
          'file': 'version.pgn',
          'time': '2026-01-01T00:00:00Z',
          'size': 7,
          'hash': digest,
          'unknown': [1, 2],
        },
      ],
      'unknown': {'preserve': true},
    };
    return {
      'version': 1,
      'id': 'move-1',
      'kind': 'move',
      'state': state,
      'from': chapter.path,
      'to': destination,
      'identity': 'original-native-identity',
      'hash': digest,
      'trainingRoot': documents.path,
      'training': [
        for (final name in trainingFiles)
          <String, Object?>{'name': name, 'before': null, 'after': null},
      ],
      'rowsChanged': 0,
      'booksBefore': '{"version":1,"books":[],"unknown":true}',
      'booksAfter': null,
      'backup': {
        'version': 1,
        'operationId': 'move-1',
        'rootPath': p.join(support.path, 'backups'),
        'rootIdentity': 'backup-root',
        'fromId': backupId(chapter.path),
        'toId': backupId(destination),
        'documentPath': destination,
        'asideName': '${backupId(destination)}.superseded-move-1',
        'source': <String, Object?>{
          'identity': 'source-backups',
          'index': jsonEncode(index),
          'files': [
            {'name': 'version.pgn', 'sha256': digest},
          ],
        },
        'destination': null,
        'indexAfter': jsonEncode({...index, 'path': destination}),
      },
    };
  }

  Map<String, Object?> backup(Map<String, Object?> record) =>
      record['backup'] as Map<String, Object?>;
  Future<File> put(Object? value) async {
    await notes.create(recursive: true);
    return File(
      p.join(notes.path, 'move-1.json'),
    ).writeAsString(jsonEncode(value));
  }

  Future<void> refused() async {
    await expectLater(
      storage().readFile(chapter.path),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    await expectLater(
      storage().writeFile(chapter.path, 'overwritten'),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    expect(await chapter.readAsString(), '1. e4 *');
  }

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('relocation-refusal-');
    documents = await Directory(p.join(profile.path, 'Documents')).create();
    support = await Directory(p.join(profile.path, 'Support')).create();
    notes = Directory(p.join(support.path, 'relocation-writes'));
    chapter = File(p.join(documents.path, 'repertoires', 'Course', 'Main.pgn'));
    await chapter.parent.create(recursive: true);
    await chapter.writeAsString('1. e4 *');
    destination = p.join(chapter.parent.path, 'Moved.pgn');
  });
  tearDown(() async {
    await Process.run('chmod', ['-R', 'u+rwX', profile.path]);
    await profile.delete(recursive: true);
  });

  for (final state in ['prepared', 'committing', 'moved', 'unknown']) {
    test(
      'production reads, writes, listings and native PGN refuse $state',
      () async {
        for (final name in trainingFiles) {
          await File(p.join(documents.path, name)).writeAsString('keep $name');
        }
        final native = NativePgnDocumentStore(
          guardOperation: storage().guardDocumentOperation,
        );
        final opened = await native.open(chapter.path) as PgnOpened;
        final note = await put(record(state));
        final before = await note.readAsString();
        await refused();
        for (final action in <Future<Object?> Function()>[
          () => storage().listRepertoires(),
          () => storage().listChapters(chapter.parent.path),
          () => storage().readRepertoireReviewsCsv(),
          () => storage().updateFile(trainingFiles.last, (_) => 'overwritten'),
          () => storage().renameFile(chapter.path, destination),
          () =>
              storage().renameRepertoireDirectory(chapter.parent.path, 'Other'),
        ]) {
          await expectLater(
            action(),
            throwsA(isA<RepertoireRecoveryRequired>()),
          );
        }
        expect(await native.open(chapter.path), isA<PgnReadFailed>());
        expect(
          await native.save(opened.snapshot, '1. d4 *'),
          isA<PgnWriteFailed>(),
        );
        for (final name in trainingFiles) {
          expect(
            await File(p.join(documents.path, name)).readAsString(),
            'keep $name',
          );
        }
        expect(await note.readAsString(), before);
        expect(await File(destination).exists(), isFalse);
      },
      skip: !Platform.isLinux,
    );
  }

  for (final state in ['complete', 'cancelled']) {
    test(
      '$state history allows access without inspecting current participants',
      () async {
        final note = await put(record(state));
        final before = await note.readAsString();
        // There are no recorded backup directories, and the old source can be replaced.
        await chapter.writeAsString('1. d4 *');
        await Link(
          p.join(support.path, 'backups'),
        ).create(p.join(profile.path, 'absent-backups'));
        expect(await storage().readFile(chapter.path), '1. d4 *');
        await storage().writeFile(chapter.path, '1. c4 *');
        expect(await chapter.readAsString(), '1. c4 *');
        expect(await note.readAsString(), before);
      },
      skip: !Platform.isLinux,
    );
  }

  test('absent backup history is a valid terminal receipt', () async {
    final value = record();
    backup(
      value,
    ).addAll({'rootIdentity': null, 'source': null, 'indexAfter': null});
    await put(value);
    expect(await storage().readFile(chapter.path), '1. e4 *');
  }, skip: !Platform.isLinux);

  test(
    'captured rebuilt index and unrelated inventory metadata are accepted',
    () async {
      final value = record();
      final source = backup(value)['source'] as Map;
      source['index'] = null;
      (source['files'] as List).insert(0, {
        'name': 'notes.txt',
        'sha256': digest,
      });
      final note = await put(value);
      final before = await note.readAsString();
      expect(await storage().readFile(chapter.path), '1. e4 *');
      expect(await note.readAsString(), before);
    },
    skip: !Platform.isLinux,
  );

  test(
    'terminal history accepts captured training alias and BOM index',
    () async {
      final value = record();
      value['trainingRoot'] = p.join(profile.path, 'former-documents-alias');
      final source = backup(value)['source'] as Map;
      source['index'] = '\ufeff${source['index']}';
      final note = await put(value);
      final before = await note.readAsString();
      expect(await storage().readFile(chapter.path), '1. e4 *');
      expect(await note.readAsString(), before);
    },
    skip: !Platform.isLinux,
  );

  test(
    'completed deletion history permits legacy access without current participants',
    () async {
      final value = record();
      final target = p.join(
        chapter.parent.path,
        '.cap-pgn-history',
        'move-1-${p.basename(chapter.path)}',
      );
      value['kind'] = 'delete';
      value['to'] = target;
      final participant = backup(value);
      final toId = backupId(target);
      participant['toId'] = toId;
      participant['documentPath'] = target;
      participant['asideName'] = '$toId.superseded-move-1';
      final source = participant['source'] as Map;
      participant['indexAfter'] = jsonEncode({
        ...jsonDecode(source['index'] as String) as Map,
        'path': target,
      });
      final note = await put(value);
      final before = await note.readAsString();
      expect(await storage().readFile(chapter.path), '1. e4 *');
      expect(await note.readAsString(), before);
    },
    skip: !Platform.isLinux,
  );

  test('relocation refusal precedes existing native recovery', () async {
    final io = IOStorageService(
      documentsRoot: documents,
      supportRoot: support,
      repertoireMoveHook: (step) async {
        if (step == RepertoireMoveStep.moved) throw StateError('interrupted');
      },
    );
    await expectLater(
      io.renameRepertoireDirectory(chapter.parent.path, 'Other'),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    final journal = (await Directory(
      p.join(support.path, 'repertoire-mutations'),
    ).list().toList()).whereType<File>().single;
    final before = await journal.readAsString();
    await put(record('prepared'));
    await expectLater(
      storage().listRepertoires(),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    expect(await journal.readAsString(), before);
    expect(jsonDecode(before)['state'], 'pending');
  }, skip: !Platform.isLinux);

  final corruptions = <String, void Function(Map<String, Object?>)>{
    'missing kind': (v) => v.remove('kind'),
    'unsupported kind': (v) => v['kind'] = 'copy',
    'delete target': (v) => v['kind'] = 'delete',
    'missing training root': (v) => v.remove('trainingRoot'),
    'relative training root': (v) => v['trainingRoot'] = 'Documents',
    'unnormalized training root': (v) =>
        v['trainingRoot'] = '${documents.path}/../Documents',
    'version type': (v) => v['version'] = 1.0,
    'new version': (v) => v['version'] = 2,
    'extra field': (v) => v['future'] = true,
    'missing field': (v) => v.remove('hash'),
    'id mismatch': (v) => v['id'] = 'other',
    'unsafe id': (v) => v['id'] = '../move-1',
    'hash': (v) => v['hash'] = digest.toUpperCase(),
    'empty identity': (v) => v['identity'] = '',
    'relative from': (v) => v['from'] = 'Course/Main.pgn',
    'escaped to': (v) => v['to'] = '$destination/../Moved.pgn',
    'outside from': (v) => v['from'] = p.join(profile.path, 'External.pgn'),
    'non PGN': (v) => v['to'] = p.join(chapter.parent.path, 'text.txt'),
    'negative count': (v) => v['rowsChanged'] = -1,
    'count type': (v) => v['rowsChanged'] = 0.0,
    'missing training': (v) => (v['training'] as List).removeLast(),
    'duplicate training': (v) =>
        (v['training'] as List)[1] = (v['training'] as List)[0],
    'training order': (v) {
      final rows = v['training'] as List;
      final first = rows[0];
      rows[0] = rows[1];
      rows[1] = first;
    },
    'training extra': (v) =>
        ((v['training'] as List).first as Map)['extra'] = true,
    'training type': (v) =>
        ((v['training'] as List).first as Map)['after'] = 42,
    'invalid books': (v) => v['booksBefore'] = '{',
    'books schema': (v) => v['booksAfter'] = '{"version":2,"books":[]}',
    'books chapter': (v) => v['booksAfter'] =
        '{"version":1,"books":[{"id":"b","name":"B","chapters":[{"path":"../Main.pgn"}]}]}',
    'books folder': (v) => v['booksAfter'] =
        '{"version":1,"books":[{"id":"b","name":"B","repertoires":[4]}]}',
    'backup version': (v) => backup(v)['version'] = 1.0,
    'backup operation': (v) => backup(v)['operationId'] = 'different',
    'backup boundary': (v) =>
        backup(v)['rootPath'] = p.join(profile.path, 'backups'),
    'backup from id': (v) => backup(v)['fromId'] = '0000000000000000',
    'backup target': (v) => backup(v)['documentPath'] = chapter.path,
    'backup aside': (v) => backup(v)['asideName'] = 'other',
    'backup root identity': (v) => backup(v)['rootIdentity'] = null,
    'backup source missing': (v) => backup(v)['source'] = null,
    'backup after missing': (v) => backup(v)['indexAfter'] = null,
    'backup snapshot extra': (v) =>
        (backup(v)['source'] as Map)['future'] = true,
    'backup identity': (v) => (backup(v)['source'] as Map)['identity'] = '',
    'backup inventory escape': (v) =>
        ((backup(v)['source'] as Map)['files'] as List).add({
          'name': '../extra',
          'sha256': digest,
        }),
    'backup inventory duplicate': (v) =>
        ((backup(v)['source'] as Map)['files'] as List).add({
          'name': 'version.pgn',
          'sha256': digest,
        }),
    'backup inventory order': (v) =>
        ((backup(v)['source'] as Map)['files'] as List).add({
          'name': 'a.pgn',
          'sha256': digest,
        }),
    'backup inventory index': (v) =>
        ((backup(v)['source'] as Map)['files'] as List).add({
          'name': 'index.json',
          'sha256': digest,
        }),
    'backup rebuilt index omitted version': (v) {
      (backup(v)['source'] as Map)['index'] = null;
      final after = jsonDecode(backup(v)['indexAfter'] as String) as Map;
      after['versions'] = [];
      backup(v)['indexAfter'] = jsonEncode(after);
    },
    'backup matching directory identities': (v) =>
        backup(v)['destination'] = backup(v)['source'],
    'backup version hash': (v) {
      final after = jsonDecode(backup(v)['indexAfter'] as String) as Map;
      (after['versions'] as List).first['hash'] = 'invalid';
      backup(v)['indexAfter'] = jsonEncode(after);
    },
    'backup version missing inventory': (v) {
      final after = jsonDecode(backup(v)['indexAfter'] as String) as Map;
      (after['versions'] as List).first['file'] = 'missing.pgn';
      backup(v)['indexAfter'] = jsonEncode(after);
    },
    'backup index invalid': (v) => (backup(v)['source'] as Map)['index'] = '{}',
    'backup after path': (v) {
      final index = jsonDecode(backup(v)['indexAfter'] as String) as Map;
      index['path'] = chapter.path;
      backup(v)['indexAfter'] = jsonEncode(index);
    },
    'backup after edits': (v) {
      final index = jsonDecode(backup(v)['indexAfter'] as String) as Map;
      index['future'] = true;
      backup(v)['indexAfter'] = jsonEncode(index);
    },
  };
  for (final entry in corruptions.entries) {
    test(
      'terminal metadata refuses ${entry.key} and preserves unknown bytes',
      () async {
        final value = record();
        entry.value(value);
        final note = await put(value);
        final before = await note.readAsString();
        await refused();
        expect(await note.readAsString(), before);
      },
      skip: !Platform.isLinux,
    );
  }
  for (final text in ['{', 'null', '[]']) {
    test('malformed journal $text is preserved', () async {
      final note = await put(record());
      await note.writeAsString(text);
      await refused();
      expect(await note.readAsString(), text);
    }, skip: !Platform.isLinux);
  }
  for (final namespace in [false, true]) {
    test(
      'linked ${namespace ? 'namespace' : 'record'} is refused without following',
      () async {
        final target = namespace
            ? Directory(p.join(profile.path, 'elsewhere'))
            : File(p.join(profile.path, 'elsewhere.json'));
        if (target is Directory) {
          await target.create();
        } else {
          await (target as File).writeAsString(jsonEncode(record()));
        }
        if (!namespace) await notes.create();
        final link = Link(
          namespace ? notes.path : p.join(notes.path, 'move-1.json'),
        );
        await link.create(target.path);
        await refused();
        expect(await link.target(), target.path);
      },
      skip: !Platform.isLinux,
    );
  }
  for (final namespace in [false, true]) {
    test(
      'unreadable ${namespace ? 'namespace' : 'record'} is refused',
      () async {
        final note = await put(record());
        await Process.run('chmod', ['000', namespace ? notes.path : note.path]);
        await refused();
      },
      skip: !Platform.isLinux || Platform.environment['USER'] == 'root',
    );
  }
}
