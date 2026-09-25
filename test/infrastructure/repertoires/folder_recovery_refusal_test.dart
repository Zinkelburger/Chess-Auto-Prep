@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _names = [
  'repertoire_reviews.csv',
  'repertoire_move_progress.csv',
  'repertoire_review_history.csv',
  'repertoire_move_attempts.jsonl',
];
const _hash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _id = 'folder-1';

void main() {
  late Directory profile;
  late Directory documents;
  late Directory support;
  late Directory notes;
  late File chapter;
  late String from;
  late String to;
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
  Map<String, Object?> backup(String path) {
    final source = p.join(from, path);
    final target = p.join(to, path);
    return {
      'path': path,
      'plan': {
        'version': 1,
        'operationId': _id,
        'rootPath': p.join(support.path, 'backups'),
        'rootIdentity': null,
        'fromId': backupId(source),
        'toId': backupId(target),
        'documentPath': target,
        'asideName': '${backupId(target)}.superseded-$_id',
        'source': null,
        'destination': null,
        'indexAfter': null,
      },
    };
  }

  Map<String, Object?> record([String state = 'complete']) => {
    'version': 2,
    'kind': 'folder',
    'id': _id,
    'state': state,
    'from': from,
    'to': to,
    'identity': 'original-root',
    'trainingRoot': documents.path,
    'entries': <Object?>[
      <String, Object?>{
        'path': 'Main.pgn',
        'kind': 'file',
        'identity': 'main',
        'sha256': _hash,
      },
      <String, Object?>{
        'path': 'Nested',
        'kind': 'directory',
        'identity': 'nested',
      },
      <String, Object?>{
        'path': 'Nested/.cap-pgn-history',
        'kind': 'directory',
        'identity': 'quarantine',
      },
      <String, Object?>{
        'path': 'Nested/.cap-pgn-history/1-a-Old.pgn',
        'kind': 'file',
        'identity': 'old',
        'sha256': _hash,
      },
      <String, Object?>{
        'path': 'Nested/Upper.PGN',
        'kind': 'file',
        'identity': 'upper',
        'sha256': _hash,
      },
      <String, Object?>{
        'path': 'data.bin',
        'kind': 'file',
        'identity': 'opaque',
        'sha256': _hash,
      },
    ],
    'training': [
      for (final name in _names)
        <String, Object?>{'name': name, 'before': null, 'after': null},
    ],
    'rowsChanged': 0,
    'booksBefore': '{"version":1,"books":[],"future":true}',
    'booksAfter': null,
    'backups': [
      backup('Main.pgn'),
      backup('Nested/.cap-pgn-history/1-a-Old.pgn'),
      backup('Nested/Upper.PGN'),
    ],
  };
  void populateBackups(Map<String, Object?> value) {
    for (final entry in _backups(value)) {
      final relative = entry['path']! as String;
      final plan = entry['plan']! as Map<String, Object?>;
      final index = <String, Object?>{
        'path': p.join(from, relative),
        'future': {'preserve': true},
        'versions': [
          {
            'file': 'version.pgn',
            'time': '2026-01-01T00:00:00Z',
            'size': 7,
            'hash': _hash,
          },
        ],
      };
      plan['rootIdentity'] = 'archive-root';
      plan['source'] = <String, Object?>{
        'identity': 'source-$relative',
        'index': jsonEncode(index),
        'files': [
          {'name': 'version.pgn', 'sha256': _hash},
        ],
      };
      plan['indexAfter'] = jsonEncode({...index, 'path': p.join(to, relative)});
    }
  }

  Future<File> put(Map<String, Object?> value) async {
    await notes.create(recursive: true);
    return File(
      p.join(notes.path, '$_id.json'),
    ).writeAsString(jsonEncode(value));
  }

  Future<void> refused(File note) async {
    final original = await note.readAsBytes();
    await expectLater(
      storage().readFile(chapter.path),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    await expectLater(
      storage().writeFile(chapter.path, 'must not land'),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    expect(await chapter.readAsString(), '1. e4 *');
    expect(await note.readAsBytes(), original);
  }

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('folder-refusal-');
    documents = await Directory(p.join(profile.path, 'Documents')).create();
    support = await Directory(p.join(profile.path, 'Support')).create();
    notes = Directory(p.join(support.path, 'relocation-writes'));
    from = p.join(documents.path, 'repertoires', 'Before');
    to = p.join(documents.path, 'repertoires', 'After');
    chapter = File(p.join(from, 'Main.pgn'));
    await chapter.parent.create(recursive: true);
    await chapter.writeAsString('1. e4 *');
  });
  tearDown(() => profile.delete(recursive: true));

  for (final endpoint in [
    'Support',
    'Support/relocation-writes/child',
    'Support/backups',
    '.cap-reference-history',
    'repertoires/.cap-repertoire-publications/child',
  ]) {
    test('terminal folder refuses moving metadata at $endpoint', () async {
      support = await Directory(p.join(documents.path, 'Support')).create();
      notes = Directory(p.join(support.path, 'relocation-writes'));
      final value = record()
        ..['from'] = p.join(documents.path, endpoint)
        ..['entries'] = <Object?>[]
        ..['backups'] = <Object?>[];
      await refused(await put(value));
    });
  }
  test(
    'shared Documents and Support allow an ordinary folder receipt',
    () async {
      support = documents;
      notes = Directory(p.join(support.path, 'relocation-writes'));
      await put(record());
      expect(await storage().readFile(chapter.path), '1. e4 *');
    },
  );

  for (final state in ['complete', 'cancelled']) {
    test(
      'valid $state folder history permits public read and write without inspecting historical tree',
      () async {
        final note = await put(record(state));
        final original = await note.readAsBytes();
        expect(await storage().readFile(chapter.path), '1. e4 *');
        await storage().writeFile(chapter.path, '1. d4 *');
        expect(await chapter.readAsString(), '1. d4 *');
        expect(await Directory(to).exists(), isFalse);
        expect(await Directory(p.join(from, 'Nested')).exists(), isFalse);
        expect(await note.readAsBytes(), original);
      },
    );
  }
  for (final state in ['prepared', 'committing', 'future']) {
    test(
      '$state folder operation blocks public access unchanged',
      () async => refused(await put(record(state))),
    );
  }
  for (final state in ['prepared', 'committing', 'complete', 'cancelled']) {
    test('terminal folder permits exact known $state native copy', () async {
      final note = await put(record());
      final copy = await File(
        p.join(notes.path, '.$_id.json.v2-tmp.previous-123-100'),
      ).writeAsString(jsonEncode(record(state)));
      final original = await copy.readAsBytes();
      expect(await storage().readFile(chapter.path), '1. e4 *');
      expect(await copy.readAsBytes(), original);
      expect(await note.exists(), isTrue);
    });
  }
  test(
    'empty folder history and BOM training snapshots remain valid',
    () async {
      final value = record();
      value['entries'] = <Object?>[];
      value['backups'] = <Object?>[];
      value['training'] = [
        for (final name in _names)
          <String, Object?>{
            'name': name,
            'before': '\ufeff',
            'after': '\ufeff',
          },
      ];
      await put(value);
      expect(await storage().readFile(chapter.path), '1. e4 *');
    },
  );

  test('native Linux backslash in an opaque filename remains valid', () async {
    final value = record();
    (value['entries']! as List).add(<String, Object?>{
      'path': r'z\sidecar.bin',
      'kind': 'file',
      'identity': 'sidecar',
      'sha256': _hash,
    });
    await put(value);
    expect(await storage().readFile(chapter.path), '1. e4 *');
  });

  test(
    'populated backup snapshots validate without reading historical archives',
    () async {
      final value = record();
      populateBackups(value);
      await put(value);
      expect(await storage().readFile(chapter.path), '1. e4 *');
      expect(
        await Directory(p.join(support.path, 'backups')).exists(),
        isFalse,
      );
    },
  );

  for (final collision in ['another archive', 'archive root']) {
    test('folder native backup identity cannot overlap $collision', () async {
      final value = record();
      populateBackups(value);
      final first = _plan(value)['source']! as Map<String, Object?>;
      if (collision == 'archive root') {
        first['identity'] = 'archive-root';
      } else {
        final second = _backups(value)[1]['plan']! as Map<String, Object?>;
        (second['source']! as Map<String, Object?>)['identity'] =
            first['identity'];
      }
      await refused(await put(value));
    });
  }

  for (final mutation in _invalid.entries) {
    test('folder history refuses ${mutation.key} without effects', () async {
      final value = record();
      mutation.value(value);
      await refused(await put(value));
    });
  }

  test('copied folder manifest cannot change immutable inventory', () async {
    final note = await put(record());
    final prior = record('prepared');
    _entries(prior).first['identity'] = 'different';
    final copy = await File(
      p.join(notes.path, '.$_id.json.v2-tmp.previous-123-100'),
    ).writeAsString(jsonEncode(prior));
    final original = await copy.readAsBytes();
    await refused(note);
    expect(await copy.readAsBytes(), original);
  });
}

List<Map<String, Object?>> _entries(Map<String, Object?> value) =>
    (value['entries']! as List).cast<Map<String, Object?>>();
List<Map<String, Object?>> _backups(Map<String, Object?> value) =>
    (value['backups']! as List).cast<Map<String, Object?>>();
Map<String, Object?> _plan(Map<String, Object?> value) =>
    _backups(value).first['plan']! as Map<String, Object?>;
Map<String, Object?> _training(Map<String, Object?> value) =>
    (value['training']! as List).first as Map<String, Object?>;

final Map<String, void Function(Map<String, Object?>)> _invalid = {
  'version type': (v) => v['version'] = 2.0,
  'unknown version': (v) => v['version'] = 3,
  'wrong kind': (v) => v['kind'] = 'move',
  'wrong id': (v) => v['id'] = 'another',
  'extra field': (v) => v['hash'] = _hash,
  'missing entries': (v) => v.remove('entries'),
  'root identity': (v) => v['identity'] = '',
  'root identity NUL': (v) => v['identity'] = 'bad\u0000',
  'same endpoints': (v) => v['to'] = v['from'],
  'nested destination': (v) => v['to'] = p.join(v['from']! as String, 'Nested'),
  'parent destination': (v) => v['to'] = p.dirname(v['from']! as String),
  'outside root': (v) => v['from'] = '/outside',
  'unnormalized root': (v) => v['from'] = '${v['from']}/../Before',
  'relative training root': (v) => v['trainingRoot'] = 'relative',
  'entries not list': (v) => v['entries'] = {},
  'root entry': (v) => _entries(v).first['path'] = '.',
  'absolute entry': (v) => _entries(v).first['path'] = '/Main.pgn',
  'parent entry': (v) => _entries(v).first['path'] = '../Main.pgn',
  'NUL entry': (v) => _entries(v).first['path'] = 'Main\u0000.pgn',
  'unnormalized entry': (v) => _entries(v).first['path'] = './Main.pgn',
  'duplicate entry': (v) =>
      (v['entries']! as List).insert(1, {..._entries(v).first}),
  'unsorted entries': (v) => v['entries'] = _entries(v).reversed.toList(),
  'missing parent directory': (v) => (v['entries']! as List).removeAt(1),
  'file used as parent': (v) =>
      _entries(v)[1].addAll({'kind': 'file', 'sha256': _hash}),
  'unknown node kind': (v) => _entries(v).first['kind'] = 'link',
  'directory extra hash': (v) => _entries(v)[1]['sha256'] = _hash,
  'file missing hash': (v) => _entries(v).first.remove('sha256'),
  'bad file hash': (v) => _entries(v).first['sha256'] = 'bad',
  'bad file identity': (v) => _entries(v).first['identity'] = null,
  'missing training participant': (v) => (v['training']! as List).removeLast(),
  'unknown training name': (v) => _training(v)['name'] = 'other.csv',
  'unsafe training UTF-8': (v) => _training(v)['before'] = '\uD800',
  'NUL training': (v) => _training(v)['after'] = 'bad\u0000',
  'nontext training': (v) => _training(v)['before'] = 3,
  'negative row count': (v) => v['rowsChanged'] = -1,
  'floating row count': (v) => v['rowsChanged'] = 0.0,
  'malformed books': (v) => v['booksAfter'] = 'bad',
  'bad books schema': (v) => v['booksBefore'] = '{"version":3,"books":[]}',
  'missing PGN backup': (v) => (v['backups']! as List).removeLast(),
  'duplicate backup': (v) =>
      (v['backups']! as List).add({..._backups(v).first}),
  'unsorted backups': (v) => v['backups'] = _backups(v).reversed.toList(),
  'extra nonPGN backup': (v) => _backups(v).last['path'] = 'data.bin',
  'wrong backup operation': (v) => _plan(v)['operationId'] = 'other',
  'wrong backup root': (v) => _plan(v)['rootPath'] = '/outside/backups',
  'wrong backup from id': (v) => _plan(v)['fromId'] = '1111111111111111',
  'wrong backup to id': (v) => _plan(v)['toId'] = '2222222222222222',
  'wrong backup owner': (v) => _plan(v)['documentPath'] = v['from'],
  'wrong backup aside': (v) => _plan(v)['asideName'] = 'other',
  'inconsistent backup roots': (v) => _plan(v)['rootIdentity'] = 'one-only',
};
