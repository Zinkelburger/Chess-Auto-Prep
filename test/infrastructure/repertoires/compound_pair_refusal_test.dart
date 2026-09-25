@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory profile;
  late Directory documents;
  late Directory support;
  late Directory notes;
  late File current;
  late String first;
  late String second;

  IOStorageService storage() =>
      IOStorageService(documentsRoot: documents, supportRoot: support);
  Map<String, Object?> record([String state = 'complete']) => {
    'version': 2,
    'id': 'transfer-1',
    'state': state,
    'documents': <Object?>[
      <String, Object?>{'path': first, 'before': '1. e4 *', 'after': ''},
      <String, Object?>{
        'path': second,
        'before': '1. d4 *',
        'after': '1. d4 *\n\n1. e4 *',
      },
    ],
  };
  Future<File> put(Map<String, Object?> value) async {
    await notes.create(recursive: true);
    return File(
      p.join(notes.path, 'transfer-1.json'),
    ).writeAsString(jsonEncode(value));
  }

  Future<void> refused(File note) async {
    final before = await note.readAsBytes();
    await expectLater(
      storage().readFile(current.path),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    await expectLater(
      storage().writeFile(current.path, 'must not land'),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    expect(await current.readAsString(), 'current unrelated chapter');
    expect(await note.readAsBytes(), before);
  }

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('compound-pair-refusal-');
    documents = await Directory(p.join(profile.path, 'Documents')).create();
    support = await Directory(p.join(profile.path, 'Support')).create();
    notes = Directory(p.join(support.path, 'compound-writes'));
    final course = await Directory(
      p.join(documents.path, 'repertoires', 'Course'),
    ).create(recursive: true);
    current = await File(
      p.join(course.path, 'Current.pgn'),
    ).writeAsString('current unrelated chapter');
    // Historical participants deliberately do not exist anymore.
    first = p.join(course.path, 'First.pgn');
    second = p.join(course.path, 'Second.PGN');
  });
  tearDown(() => profile.delete(recursive: true));

  for (final state in ['complete', 'cancelled']) {
    test(
      '$state two-PGN history permits access without inspecting old participants',
      () async {
        final note = await put(record(state));
        final before = await note.readAsBytes();
        expect(
          await storage().readFile(current.path),
          'current unrelated chapter',
        );
        await storage().writeFile(current.path, 'later unrelated edit');
        expect(await current.readAsString(), 'later unrelated edit');
        expect(await File(first).exists(), isFalse);
        expect(await File(second).exists(), isFalse);
        expect(await note.readAsBytes(), before);
      },
    );
  }

  test('terminal pair preserves UTF-8 BOM snapshots', () async {
    final value = record();
    for (final entry in value['documents']! as List) {
      (entry as Map)['before'] = '\ufeff${entry['before']}';
      entry['after'] = '\ufeff${entry['after']}';
    }
    final note = await put(value);
    final before = await note.readAsBytes();
    expect(await storage().readFile(current.path), 'current unrelated chapter');
    expect(await note.readAsBytes(), before);
  });

  for (final state in ['prepared', 'committing', 'unknown']) {
    test(
      '$state two-PGN receipt refuses legacy access',
      () async => refused(await put(record(state))),
    );
  }

  for (final issue in [
    'unknown version',
    'extra root field',
    'books snapshot',
    'missing documents',
    'one document',
    'three documents',
    'duplicate path',
    'unknown participant field',
    'null before',
    'non-string after',
    'relative path',
    'outside root',
    'nonnormalized path',
    'wrong extension',
    'NUL text',
    'invalid UTF8',
    'wrong id',
  ]) {
    test('two-PGN history refuses $issue without changing files', () async {
      final value = record();
      final entries = value['documents']! as List<Object?>;
      final entry = entries.last! as Map<String, Object?>;
      switch (issue) {
        case 'unknown version':
          value['version'] = 3;
        case 'extra root field':
          value['future'] = true;
        case 'books snapshot':
          value['booksBefore'] = null;
        case 'missing documents':
          value.remove('documents');
        case 'one document':
          entries.removeLast();
        case 'three documents':
          entries.add({...entry, 'path': current.path});
        case 'duplicate path':
          entry['path'] = first;
        case 'unknown participant field':
          entry['identity'] = 'unproven';
        case 'null before':
          entry['before'] = null;
        case 'non-string after':
          entry['after'] = 42;
        case 'relative path':
          entry['path'] = 'Second.pgn';
        case 'outside root':
          entry['path'] = p.join(profile.path, 'Outside.pgn');
        case 'nonnormalized path':
          entry['path'] = '${p.dirname(second)}/../Course/Second.PGN';
        case 'wrong extension':
          entry['path'] = p.join(p.dirname(second), 'Second.txt');
        case 'NUL text':
          entry['after'] = 'unsafe\u0000text';
        case 'invalid UTF8':
          entry['after'] = '\ud800';
        case 'wrong id':
          value['id'] = 'other';
      }
      await refused(await put(value));
    });
  }

  for (final phase in ['prepared', 'committing', 'complete', 'cancelled']) {
    test(
      'complete pair admits exact retained native $phase predecessor',
      () async {
        final note = await put(record());
        final copy = await File(
          p.join(notes.path, '.transfer-1.json.v2-tmp.previous-123-456'),
        ).writeAsString(jsonEncode(record(phase)));
        final old = await copy.readAsBytes();
        final settled = await note.readAsBytes();
        expect(
          await storage().readFile(current.path),
          'current unrelated chapter',
        );
        expect(await copy.readAsBytes(), old);
        expect(await note.readAsBytes(), settled);
      },
    );
  }

  for (final duplicate in [false, true]) {
    test(
      'profile aliases ${duplicate ? 'cannot repeat' : 'can name'} pair participants',
      () async {
        final original = documents;
        final alias = await Link(
          p.join(profile.path, 'DocumentsAlias'),
        ).create(original.path);
        documents = Directory(alias.path);
        final value = record();
        final entries = value['documents']! as List;
        (entries.last as Map)['path'] = p.join(
          alias.path,
          p.relative(duplicate ? first : second, from: original.path),
        );
        final note = await put(value);
        if (duplicate) {
          await refused(note);
        } else {
          final before = await note.readAsBytes();
          expect(
            await storage().readFile(current.path),
            'current unrelated chapter',
          );
          expect(await note.readAsBytes(), before);
        }
      },
    );
  }

  test('native predecessor changing only second PGN is refused', () async {
    final note = await put(record());
    final prior = record('committing');
    ((prior['documents']! as List).last as Map)['after'] =
        'different second document';
    final copy = await File(
      p.join(notes.path, '.transfer-1.json.v2-tmp.previous-123-456'),
    ).writeAsString(jsonEncode(prior));
    final before = await copy.readAsBytes();
    await refused(note);
    expect(await copy.readAsBytes(), before);
  });
}
