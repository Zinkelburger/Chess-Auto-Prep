import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/utils/atomic_file.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late File file;
  late NativePgnDocumentStore store;
  const content = '[Event "Native"]\n\n1. e4 e5 *\n';
  setUp(() {
    root = Directory.systemTemp.createTempSync('native-document-');
    file = File('${root.path}/Main.pgn');
    store = NativePgnDocumentStore();
  });
  tearDown(() => root.deleteSync(recursive: true));
  Future<PgnSnapshot> seed() async {
    final result = await store.create(file.path, content);
    expect(result, isA<PgnSaved>());
    return (result as PgnSaved).after;
  }

  test(
    'native observation binds bytes and identity, and detects absence',
    () async {
      expect((await observeFile(file.path)).status, 1);
      file.writeAsStringSync(content);
      final read = await observeFile(file.path);
      expect(read.status, 0);
      expect(read.identity, isNotEmpty);
      expect(read.bytes, utf8.encode(content));
    },
  );
  test(
    'create never replaces an existing chapter and returns committed identity',
    () async {
      final snapshot = await seed();
      expect(await store.create(file.path, 'other'), isA<PgnNameCollision>());
      expect(
        (await store.open(file.path) as PgnOpened).snapshot.revision,
        snapshot.revision,
      );
      expect(file.readAsStringSync(), content);
    },
  );
  test('save returns the validated baseline and a fresh revision', () async {
    final before = await seed();
    final saved = await store.save(before, '$content\n{annotation}');
    expect(saved, isA<PgnSaved>());
    final receipt = saved as PgnSaved;
    expect(receipt.before!.revision, before.revision);
    expect(
      receipt.after.revision.nativeIdentity,
      isNot(before.revision.nativeIdentity),
    );
    expect(receipt.after.content, '$content\n{annotation}');
    expect(File(receipt.recoveryPath!).readAsBytesSync(), utf8.encode(content));
  });
  test(
    'same-byte replacement is a conflict, even though text is unchanged',
    () async {
      final before = await seed();
      final replacement = File('${root.path}/replacement')
        ..writeAsStringSync(content);
      replacement.renameSync(file.path);
      expect(await store.save(before, 'stale'), isA<PgnConflict>());
      expect(file.readAsStringSync(), content);
    },
  );
  test(
    'BOM-only change is a conflict even when decoded text is equal',
    () async {
      final before = await seed();
      file.writeAsBytesSync([0xef, 0xbb, 0xbf, ...utf8.encode(content)]);
      expect(
        (await store.open(file.path) as PgnOpened).snapshot.content,
        before.content,
      );
      expect(await store.save(before, 'stale'), isA<PgnConflict>());
    },
  );
  test(
    'two writers with one baseline produce one save and one conflict',
    () async {
      final before = await seed();
      final results = await Future.wait([
        store.save(before, 'first'),
        NativePgnDocumentStore().save(before, 'second'),
      ]);
      expect(results.whereType<PgnSaved>(), hasLength(1));
      expect(results.whereType<PgnConflict>(), hasLength(1));
    },
  );
  test('delete versus queued save cannot recreate the chapter', () async {
    final before = await seed();
    file.deleteSync();
    expect(await store.save(before, 'stale'), isA<PgnConflict>());
    expect(file.existsSync(), isFalse);
  });
  test('final symlink and hardlink aliases fail closed', () async {
    await seed();
    final alias = Link('${root.path}/alias.pgn')..createSync(file.path);
    expect(await store.open(alias.path), isA<PgnReadFailed>());
    final hard = '${root.path}/hard.pgn';
    final result = await Process.run('ln', [file.path, hard]);
    expect(result.exitCode, 0);
    expect(await store.open(file.path), isA<PgnReadFailed>());
    expect(await store.open(hard), isA<PgnReadFailed>());
  }, skip: Platform.isWindows);
  test('unavailable identity never permits replacement', () async {
    final before = await seed();
    final unavailable = NativePgnDocumentStore(
      observe: (_) async => NativeFileObservation(status: 2, error: 5),
    );
    expect(await unavailable.save(before, 'lost'), isA<PgnWriteFailed>());
    expect(file.readAsStringSync(), content);
  });
  test(
    'external change after preparation is caught at final validation',
    () async {
      final before = await seed();
      final racing = NativePgnDocumentStore(
        writer: AtomicFileWriter(
          testHook: (step) async {
            if (step == AtomicWriteStep.tempFlushed) {
              file.writeAsStringSync('external');
            }
          },
        ),
      );
      expect(await racing.save(before, 'lost'), isA<PgnConflict>());
      expect(file.readAsStringSync(), 'external');
    },
  );
  test(
    'failed flush after installation is uncertain, never ordinary failure',
    () async {
      final before = await seed();
      final failed = NativePgnDocumentStore(
        flushDirectory: (path) async {
          if (path == root.path) {
            throw const FileSystemException('flush failed');
          }
          await syncDirectory(path);
        },
      );
      final result = await failed.save(before, 'installed');
      expect(result, isA<PgnWriteUncertain>());
      expect((result as PgnWriteUncertain).observed!.content, 'installed');
      expect(result.installedRevision, result.observed!.revision);
      expect(file.readAsStringSync(), 'installed');
      expect(await store.save(before, 'duplicate retry'), isA<PgnConflict>());
    },
  );
  test(
    'same-text impostor after installation carries no provenance proof',
    () async {
      final before = await seed();
      final racing = NativePgnDocumentStore(
        flushDirectory: (path) async {
          if (path == root.path) {
            final impostor = File('${root.path}/impostor')
              ..writeAsStringSync('installed');
            impostor.renameSync(file.path);
            throw const FileSystemException(
              'flush failed after external replacement',
            );
          }
          await syncDirectory(path);
        },
      );
      final result =
          await racing.save(before, 'installed') as PgnWriteUncertain;
      expect(result.observed!.content, 'installed');
      expect(result.installedRevision, isNull);
    },
  );
  test(
    'staging failure preserves original and cleans temporary artifact',
    () async {
      final before = await seed();
      final failed = NativePgnDocumentStore(
        writer: AtomicFileWriter(
          testHook: (step) async {
            if (step == AtomicWriteStep.tempFlushed) {
              throw StateError('injected disk failure');
            }
          },
        ),
      );
      expect(await failed.save(before, 'lost'), isA<PgnWriteFailed>());
      expect(file.readAsStringSync(), content);
      expect(root.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
    },
  );
  test('separate isolates share the existing filesystem mutex', () async {
    final baseline = await seed();
    final results = await Future.wait([
      Isolate.run(() => NativePgnDocumentStore().save(baseline, 'worker one')),
      Isolate.run(() => NativePgnDocumentStore().save(baseline, 'worker two')),
    ]);
    expect(results.whereType<PgnSaved>(), hasLength(1));
    expect(results.whereType<PgnConflict>(), hasLength(1));
  });
  test(
    'exclusive native publication does not replace a competing creator',
    () async {
      file.writeAsStringSync('external');
      final staged = File('${root.path}/stage')..writeAsStringSync('new');
      await expectLater(
        installNewFile(staged.path, file.path),
        throwsA(isA<NativeNameCollision>()),
      );
      expect(file.readAsStringSync(), 'external');
      expect(staged.readAsStringSync(), 'new');
    },
  );
  test(
    'embedded NUL is rejected rather than reading a truncated path',
    () async {
      file.writeAsStringSync(content);
      await expectLater(
        observeFile('${file.path}\u0000suffix'),
        throwsArgumentError,
      );
    },
  );
  test('FIFO observations fail without waiting for a writer', () async {
    final result = await Process.run('mkfifo', [file.path]);
    expect(result.exitCode, 0);
    final observation = await observeFile(
      file.path,
    ).timeout(const Duration(seconds: 3));
    expect(observation.status, 4);
  }, skip: Platform.isWindows);
  test(
    'compressed documents keep their format and exact recovery baseline',
    () async {
      final original = gzip.encode(utf8.encode(content));
      file.writeAsBytesSync(original);
      final baseline = (await store.open(file.path) as PgnOpened).snapshot;
      final result = await store.save(baseline, '$content{note}') as PgnSaved;
      expect(
        gzip.decode(file.readAsBytesSync()),
        utf8.encode('$content{note}'),
      );
      expect(File(result.recoveryPath!).readAsBytesSync(), original);
    },
  );
  test(
    'transaction keeps its lock until every started write finishes',
    () async {
      final staged = Completer<void>();
      final release = Completer<void>();
      var returned = false;
      final writer = AtomicFileWriter(
        testHook: (step) async {
          if (step == AtomicWriteStep.tempFlushed) {
            staged.complete();
            await release.future;
          }
        },
      );
      final transaction = writer
          .transaction(file, (handle) async {
            unawaited(
              handle.writeBytes(
                utf8.encode(content),
                createOnly: true,
                validate: (_) async {},
              ),
            );
          })
          .then((_) => returned = true);
      await staged.future;
      expect(returned, isFalse);
      release.complete();
      await transaction;
      expect(returned, isTrue);
      expect(file.readAsStringSync(), content);
    },
  );
}
