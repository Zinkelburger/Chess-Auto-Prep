import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/repertoire_directory_mutations.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory profile;
  late Directory documents;
  late Directory support;
  late Directory notes;
  late File document;
  late File progress;

  IOStorageService storage() =>
      IOStorageService(documentsRoot: documents, supportRoot: support);

  Map<String, Object?> record(String state) {
    final payload = jsonEncode(['write', [], [], []]);
    final core = <String, Object?>{
      'version': 1,
      'id': 'rating-1',
      'sequence': 1,
      'previous': null,
      'dependency': null,
      'documentsRoot': documents.path,
      'supportRoot': support.path,
      'trainingRoot': documents.path,
      'sources': [
        {'path': document.path, 'hash': 'a' * 64, 'identity': 'original-file'},
      ],
      'digest': sha256.convert(utf8.encode(payload)).toString(),
    };
    final files = [
      for (final name in [
        'repertoire_reviews.csv',
        'repertoire_move_progress.csv',
        'repertoire_review_history.csv',
        'repertoire_move_attempts.jsonl',
      ])
        {'name': name, 'before': null, 'after': null},
    ];
    return {
      ...core,
      'state': state,
      'payload': state == 'complete' ? null : payload,
      'files': state == 'committing' ? files : null,
      'planDigest': state == 'queued'
          ? null
          : sha256.convert(utf8.encode(jsonEncode([core, files]))).toString(),
    };
  }

  Future<File> put(Object value) => File(
    p.join(notes.path, 'rating-1.json'),
  ).writeAsString(jsonEncode(value));

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('training-refusal-');
    documents = await Directory(p.join(profile.path, 'Documents')).create();
    support = await Directory(p.join(profile.path, 'Support')).create();
    notes = await Directory(p.join(support.path, 'training-writes')).create();
    final folder = await Directory(
      p.join(documents.path, 'repertoires', 'Course'),
    ).create(recursive: true);
    document = await File(
      p.join(folder.path, 'Main.pgn'),
    ).writeAsString('1. e4 *');
    progress = await File(
      p.join(documents.path, 'repertoire_reviews.csv'),
    ).writeAsString('preserved training rows');
  });

  tearDown(() => profile.delete(recursive: true));

  for (final state in ['queued', 'committing', 'unknown']) {
    test(
      'v1 refuses $state training evidence before document or row access',
      () async {
        final note = await File(p.join(notes.path, 'rating-1.json'))
            .writeAsString(
              jsonEncode({'version': 1, 'id': 'rating-1', 'state': state}),
            );
        final before = await note.readAsBytes();
        for (final file in [document, progress]) {
          await expectLater(
            storage().readFile(file.path),
            throwsA(isA<RepertoireRecoveryRequired>()),
          );
          await expectLater(
            storage().writeFile(file.path, 'replacement'),
            throwsA(isA<RepertoireRecoveryRequired>()),
          );
        }
        expect(await document.readAsString(), '1. e4 *');
        expect(await progress.readAsString(), 'preserved training rows');
        expect(await note.readAsBytes(), before);
      },
      skip: !Platform.isLinux,
    );
  }

  test(
    'complete compact receipt permits access without consulting old sources',
    () async {
      final value = record('complete');
      await document.delete();
      await document.writeAsString('a replacement document');
      final note = await put(value);
      final before = await note.readAsString();
      expect(await storage().readFile(document.path), 'a replacement document');
      await storage().writeFile(document.path, 'later edit');
      expect(await document.readAsString(), 'later edit');
      expect(await note.readAsString(), before);
    },
    skip: !Platform.isLinux,
  );

  for (final phase in ['queued', 'committing', 'complete']) {
    test(
      'complete receipt admits a proven native $phase predecessor copy',
      () async {
        await put(record('complete'));
        final copy = await File(
          p.join(notes.path, '.rating-1.json.v2-tmp.previous-123-456'),
        ).writeAsString(jsonEncode(record(phase)));
        final before = await copy.readAsBytes();
        expect(await storage().readFile(document.path), '1. e4 *');
        expect(await copy.readAsBytes(), before);
      },
      skip: !Platform.isLinux,
    );
  }

  for (final change in <String, void Function(Map<String, Object?>)>{
    'version': (r) => r['version'] = 2,
    'state': (r) => r['state'] = 'cancelled',
    'extra field': (r) => r['extra'] = true,
    'id': (r) => r['id'] = 'different',
    'sequence type': (r) => r['sequence'] = 1.0,
    'sequence gap': (r) {
      r['sequence'] = 2;
      r['previous'] = 'missing';
    },
    'first predecessor': (r) => r['previous'] = 'missing',
    'missing dependency': (r) => r['dependency'] = 'missing',
    'self dependency': (r) => r['dependency'] = 'rating-1',
    'profile': (r) => r['documentsRoot'] = support.path,
    'support': (r) => r['supportRoot'] = documents.path,
    'alias': (r) => r['trainingRoot'] = 'relative',
    'command digest': (r) => r['digest'] = 'bad',
    'publication digest': (r) => r['planDigest'] = null,
    'terminal payload': (r) => r['payload'] = '[]',
    'terminal snapshots': (r) => r['files'] = [],
    'source identity': (r) => (r['sources'] as List).first['identity'] = '',
    'source hash': (r) => (r['sources'] as List).first['hash'] = 'bad',
    'source path': (r) => (r['sources'] as List).first['path'] = '/outside.pgn',
    'duplicate source': (r) =>
        (r['sources'] as List).add((r['sources'] as List).first),
  }.entries) {
    test('malformed ${change.key} refuses terminal training history', () async {
      final value = record('complete');
      change.value(value);
      final note = await put(value);
      final before = await note.readAsBytes();
      await expectLater(
        storage().readFile(document.path),
        throwsA(isA<RepertoireRecoveryRequired>()),
      );
      expect(await note.readAsBytes(), before);
      expect(await document.readAsString(), '1. e4 *');
    }, skip: !Platform.isLinux);
  }

  for (final issue in [
    'missing current',
    'different digest',
    'changed plan',
    'unknown phase',
  ]) {
    test('unproven native training copy $issue refuses access', () async {
      final current = await put(record('complete'));
      final previous = record('committing');
      if (issue == 'missing current') await current.delete();
      if (issue == 'different digest') previous['digest'] = 'b' * 64;
      if (issue == 'changed plan')
        (previous['files'] as List).first['after'] = 'YQ==';
      if (issue == 'unknown phase') previous['state'] = 'prepared';
      final copy = await File(
        p.join(notes.path, '.rating-1.json.v2-tmp.previous-123-456'),
      ).writeAsString(jsonEncode(previous));
      final before = await copy.readAsBytes();
      await expectLater(
        storage().readFile(document.path),
        throwsA(isA<RepertoireRecoveryRequired>()),
      );
      expect(await copy.readAsBytes(), before);
    }, skip: !Platform.isLinux);
  }

  test('training refusal precedes pending legacy move recovery', () async {
    final interrupted = IOStorageService(
      documentsRoot: documents,
      supportRoot: support,
      repertoireMoveHook: (step) async {
        if (step == RepertoireMoveStep.moved) throw StateError('interrupted');
      },
    );
    await expectLater(
      interrupted.renameRepertoireDirectory(document.parent.path, 'Moved'),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    final journals = Directory(p.join(support.path, 'repertoire-mutations'));
    final journal = (await journals.list().toList()).whereType<File>().single;
    final before = await journal.readAsBytes();
    await put(record('queued'));
    await expectLater(
      storage().readFile(
        p.join(document.parent.parent.path, 'Moved', 'Main.pgn'),
      ),
      throwsA(isA<RepertoireRecoveryRequired>()),
    );
    expect(await journal.readAsBytes(), before);
  }, skip: !Platform.isLinux);
}
