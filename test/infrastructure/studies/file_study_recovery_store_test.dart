import 'package:chess_auto_prep/infrastructure/studies/study_recovery_codec.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/infrastructure/documents/file_workspace_recovery_store.dart';
import 'package:chess_auto_prep/features/studies/models/study_workspace_snapshot.dart';
import 'package:chess_auto_prep/features/documents/models/document_save_state.dart';
import 'package:chess_auto_prep/utils/atomic_file.dart';
import '../../support/scripted_document_store.dart';

StudyWorkspaceSnapshot draft({String content = '1. e4 *', bool dirty = true}) =>
    StudyWorkspaceSnapshot(
      name: 'Study',
      path: '/study.pgn',
      content: content,
      dirty: dirty,
      baseline: snapshot('1. d4 *', path: '/study.pgn'),
      retainedDrafts: [
        const RetainedDocumentDraft(
          path: '/other.pgn',
          content: '1. c4 *',
          baseline: null,
        ),
      ],
      chapter: 2,
      cursor: [0, 1],
      flipped: true,
      uncertain: true,
      uncertainPath: '/copy.pgn',
    );
Future<int> _isolatedCount(String path) => Isolate.run(() async {
  final store = FileWorkspaceRecoveryStore<StudyWorkspaceSnapshot>(
    codec: const StudyRecoveryCodec(),
    directory: () async => Directory(path),
  );
  return (await store.list()).entries.length;
});
void main() {
  late Directory root;
  late FileWorkspaceRecoveryStore<StudyWorkspaceSnapshot> store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('study-recovery-');
    store = FileWorkspaceRecoveryStore<StudyWorkspaceSnapshot>(
      codec: const StudyRecoveryCodec(),
      directory: () async => root,
    );
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  test(
    'live sessions stay hidden across stores and isolates; release exposes exact work',
    () async {
      await store.write(draft());
      final reader = FileWorkspaceRecoveryStore<StudyWorkspaceSnapshot>(
        codec: const StudyRecoveryCodec(),
        directory: () async => root,
      );
      expect((await reader.list()).entries, isEmpty);
      expect(await _isolatedCount(root.path), 0);
      await store.close();
      final entry = (await reader.list()).entries.single;
      expect(entry.snapshot.content, '1. e4 *');
      expect(entry.snapshot.baseline!.revision, draft().baseline!.revision);
      expect(entry.snapshot.retainedDrafts.single.content, '1. c4 *');
      expect(entry.snapshot.chapter, 2);
      expect(entry.snapshot.cursor, [0, 1]);
      expect(entry.snapshot.flipped, isTrue);
      expect(entry.snapshot.uncertainPath, '/copy.pgn');
      expect(await _isolatedCount(root.path), 1);
    },
  );
  test('failed replacement preserves the acknowledged checkpoint', () async {
    var fail = false;
    final writer = FileWorkspaceRecoveryStore<StudyWorkspaceSnapshot>(
      codec: const StudyRecoveryCodec(),
      directory: () async => root,
      writer: AtomicFileWriter(
        testHook: (step) async {
          if (fail && step == AtomicWriteStep.beforePrimaryReplace) {
            throw StateError('disk');
          }
        },
      ),
    );
    await writer.write(draft());
    fail = true;
    await expectLater(
      writer.write(draft(content: '1. e4 e5 *')),
      throwsStateError,
    );
    await writer.close();
    expect((await store.list()).entries.single.snapshot.content, '1. e4 *');
  });
  test(
    'resolving is revision guarded, idempotent and preserves archived bytes',
    () async {
      await store.write(draft());
      await store.close();
      final reader = FileWorkspaceRecoveryStore<StudyWorkspaceSnapshot>(
        codec: const StudyRecoveryCodec(),
        directory: () async => root,
      );
      final entry = (await reader.list()).entries.single;
      await reader.resolve(entry);
      await reader.resolve(entry);
      expect((await reader.list()).entries, isEmpty);
      expect(
        await File('${root.path}/${entry.id}.json').readAsString(),
        contains('1. e4 *'),
      );
    },
  );
  test(
    'corrupt and unknown schemas remain visible as problems and stay untouched',
    () async {
      await store.write(draft());
      await store.close();
      final file =
          (await root.list().where((e) => e.path.endsWith('.json')).toList())
                  .single
              as File;
      final original = await file.readAsString();
      final damaged = original.replaceFirst('1. e4 *', '1. a4 *');
      await file.writeAsString(damaged);
      var listing = await store.list();
      expect(listing.entries, isEmpty);
      expect(listing.unreadable, 1);
      expect(await file.readAsString(), damaged);
      final data = jsonDecode(original) as Map<String, dynamic>;
      data['schema'] = 999;
      await file.writeAsString(jsonEncode(data));
      listing = await store.list();
      expect(listing.unreadable, 1);
    },
  );
  test(
    'a later clean save resolves only that session, leaving another draft available',
    () async {
      final other = FileWorkspaceRecoveryStore<StudyWorkspaceSnapshot>(
        codec: const StudyRecoveryCodec(),
        directory: () async => root,
      );
      await other.write(draft(content: '1. c4 *'));
      await other.close();
      await store.write(draft());
      await store.write(
        StudyWorkspaceSnapshot(
          name: 'Saved',
          path: '/study.pgn',
          content: '1. e4 *',
          dirty: false,
        ),
      );
      await store.close();
      expect((await store.list()).entries.single.snapshot.content, '1. c4 *');
    },
  );
  test(
    'process death releases its lease without losing the acknowledged checkpoint',
    () async {
      final child = await Process.start('dart', [
        'run',
        'test/support/study_recovery_process.dart',
        root.path,
      ]);
      final errors = child.stderr.transform(utf8.decoder).join();
      addTearDown(() async {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
      });
      await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((line) => line == 'checkpoint-ready')
          .timeout(const Duration(seconds: 60));
      expect((await store.list()).entries, isEmpty);
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
      expect(
        (await store.list()).entries.single.snapshot.content,
        contains('e4 e5'),
      );
      expect(
        (await errors).replaceAll('Running build hooks...', '').trim(),
        isEmpty,
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test('a stale recovery receipt cannot resolve a changed record', () async {
    await store.write(draft());
    await store.close();
    final entry = (await store.list()).entries.single;
    final file = File('${root.path}/${entry.id}.json');
    final record =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    record['updatedAt'] = DateTime(2030).toUtc().toIso8601String();
    await file.writeAsString(jsonEncode(record));
    await expectLater(store.resolve(entry), throwsStateError);
    expect((await store.list()).entries.single.snapshot.content, '1. e4 *');
  });
}
