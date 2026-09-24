import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/repertoire_directory_mutations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory profile;
  late Directory documents;
  late Directory support;
  late Directory notes;
  late File document;

  IOStorageService storage() =>
      IOStorageService(documentsRoot: documents, supportRoot: support);

  Map<String, Object?> record(String state) => {
    'version': 1,
    'id': 'rename-1',
    'state': state,
    'documentPath': document.path,
    'documentBefore': '1. e4 *',
    'documentAfter': '1. d4 *',
    'booksBefore': null,
    'booksAfter': '{"books":[]}',
  };

  Future<File> put(Object value) async {
    await notes.create();
    return File(p.join(notes.path, 'rename-1.json'))
      ..writeAsStringSync(jsonEncode(value));
  }

  Future<void> refuses() async {
    await expectLater(
      storage().readFile(document.path),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    await expectLater(
      storage().writeFile(document.path, 'replacement'),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    expect(await document.readAsString(), '1. e4 *');
  }

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('compound-refusal-');
    documents = await Directory(p.join(profile.path, 'Documents')).create();
    support = await Directory(p.join(profile.path, 'Support')).create();
    notes = Directory(p.join(support.path, 'compound-writes'));
    final chapter = await Directory(
      p.join(documents.path, 'repertoires', 'Course'),
    ).create(recursive: true);
    document = File(p.join(chapter.path, 'Main.pgn'));
    await document.writeAsString('1. e4 *');
  });
  tearDown(() async {
    await Process.run('chmod', ['-R', 'u+rwX', profile.path]);
    await profile.delete(recursive: true);
  });

  for (final state in ['prepared', 'committing', 'unknown']) {
    test(
      'first read and write refuse $state compound operation without changing it',
      () async {
        final note = await put(record(state));
        final original = await note.readAsString();
        await refuses();
        expect(await note.readAsString(), original);
      },
      skip: !Platform.isLinux,
    );
  }

  for (final state in ['complete', 'cancelled']) {
    test(
      'strict $state compound history permits ordinary document access',
      () async {
        final note = await put(record(state));
        final original = await note.readAsString();
        expect(await storage().readFile(document.path), '1. e4 *');
        await storage().writeFile(document.path, '1. d4 *');
        expect(await storage().readFile(document.path), '1. d4 *');
        expect(await note.readAsString(), original);
      },
      skip: !Platform.isLinux,
    );
  }

  test('compound refusal precedes native move recovery', () async {
    final interrupted = IOStorageService(
      documentsRoot: documents,
      supportRoot: support,
      repertoireMoveHook: (step) async {
        if (step == RepertoireMoveStep.moved) throw StateError('interrupted');
      },
    );
    final destination = p.join(
      document.parent.parent.path,
      'Moved',
      'Main.pgn',
    );
    await expectLater(
      interrupted.renameRepertoireDirectory(document.parent.path, 'Moved'),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    final journalDirectory = Directory(
      p.join(support.path, 'repertoire-mutations'),
    );
    final journal = (await journalDirectory.list().toList())
        .whereType<File>()
        .single;
    final nativeBefore = await journal.readAsString();
    await put(record('prepared'));
    await expectLater(
      storage().readFile(destination),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    expect(await journal.readAsString(), nativeBefore);
    expect(jsonDecode(nativeBefore)['state'], 'pending');
  }, skip: !Platform.isLinux);

  test(
    'unknown version and extra fields never count as completed history',
    () async {
      final note = await put({...record('complete'), 'version': 2});
      await refuses();
      await note.writeAsString(
        jsonEncode({...record('complete'), 'extra': true}),
      );
      await refuses();
    },
    skip: !Platform.isLinux,
  );

  test(
    'malformed nullable payload and document paths refuse completed metadata',
    () async {
      final invalid = <Map<String, Object?>>[
        {...record('complete'), 'booksBefore': 4},
        {...record('complete'), 'documentAfter': null},
        {
          ...record('complete'),
          'documentPath': p.join(profile.path, 'Outside.pgn'),
        },
        {...record('complete'), 'documentPath': documents.path},
        {...record('complete'), 'documentPath': 'relative.pgn'},
        {
          ...record('complete'),
          'documentPath': '${document.parent.path}/../Course/Main.pgn',
        },
        {
          ...record('complete'),
          'documentPath': p.join(documents.path, 'file.txt'),
        },
        {...record('complete'), 'id': 'different'},
      ];
      final note = await put(invalid.first);
      for (final value in invalid) {
        final text = jsonEncode(value);
        await note.writeAsString(text);
        await refuses();
        expect(await note.readAsString(), text);
      }
    },
    skip: !Platform.isLinux,
  );

  test(
    'malformed text and linked metadata remain preserved and refused',
    () async {
      final note = await put(record('complete'));
      await note.writeAsString('invalid-json');
      await refuses();
      expect(await note.readAsString(), 'invalid-json');
      await note.delete();
      final target = File(p.join(profile.path, 'outside.json'));
      await target.writeAsString(jsonEncode(record('complete')));
      await Link(note.path).create(target.path);
      await refuses();
      expect(await Link(note.path).target(), target.path);
    },
    skip: !Platform.isLinux,
  );

  test('linked compound namespace is refused even when empty', () async {
    final target = await Directory(p.join(profile.path, 'elsewhere')).create();
    await Link(notes.path).create(target.path);
    await refuses();
    expect(await Link(notes.path).target(), target.path);
    expect(await target.list().toList(), isEmpty);
  }, skip: !Platform.isLinux);

  test(
    'unreadable completed metadata is refused rather than treated as absent',
    () async {
      final note = await put(record('complete'));
      await Process.run('chmod', ['000', note.path]);
      await refuses();
    },
    skip: !Platform.isLinux || Platform.environment['USER'] == 'root',
  );
  test(
    'unreadable compound namespace is refused rather than ignored',
    () async {
      await notes.create();
      await Process.run('chmod', ['000', notes.path]);
      await refuses();
    },
    skip: !Platform.isLinux || Platform.environment['USER'] == 'root',
  );
}
