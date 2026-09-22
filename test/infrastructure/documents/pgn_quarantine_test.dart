import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _UnusedStorage implements StorageService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected storage access: $invocation');
}

void main() {
  late Directory root;
  late File file;
  const original = '[Event "Source"]\n\n1. e4 e5 *\n';
  const changed = '[Event "Newer source"]\n\n1. d4 d5 *\n';
  setUp(() {
    root = Directory.systemTemp.createTempSync('pgn-quarantine-');
    file = File(p.join(root.path, 'Main.pgn'))..writeAsStringSync(original);
  });
  tearDown(() => root.deleteSync(recursive: true));
  Future<PgnSnapshot> baseline(NativePgnDocumentStore store) async =>
      (await store.open(file.path) as PgnOpened).snapshot;

  test(
    'legacy capability refuses quarantine without accessing storage',
    () async {
      final native = NativePgnDocumentStore();
      final before = await baseline(native);
      final legacy = LegacyPgnDocumentStore(_UnusedStorage());
      expect(legacy.supportsQuarantine, isFalse);
      final result = await legacy.quarantine(before);
      expect(result, isA<PgnQuarantineFailed>());
      expect((result as PgnQuarantineFailed).error, isA<UnsupportedError>());
      expect(file.readAsStringSync(), original);
    },
  );

  test(
    'acknowledged quarantine retains exact compressed bytes and identity',
    () async {
      final bytes = gzip.encode([0xef, 0xbb, 0xbf, ...utf8.encode(original)]);
      file.writeAsBytesSync(bytes);
      final store = NativePgnDocumentStore();
      final before = await baseline(store);
      expect(store.supportsQuarantine, isTrue);
      final result = await store.quarantine(before) as PgnQuarantined;
      expect(file.existsSync(), isFalse);
      expect(result.before.revision, before.revision);
      expect(
        result.retained.revision.nativeIdentity,
        before.revision.nativeIdentity,
      );
      expect(result.retained.revision.sha256, before.revision.sha256);
      expect(result.retained.path, isNot(before.path));
      expect(result.retained.content, before.content);
      expect(File(result.retained.path).readAsBytesSync(), bytes);
      expect(File(result.recoveryPath).readAsBytesSync(), bytes);
    },
  );

  for (final equalText in [false, true]) {
    test(
      'rejects ${equalText ? 'equal-text' : 'changed'} native replacement',
      () async {
        final store = NativePgnDocumentStore();
        final before = await baseline(store);
        File(p.join(root.path, 'replacement'))
          ..writeAsStringSync(equalText ? original : changed)
          ..renameSync(file.path);
        expect(await store.quarantine(before), isA<PgnQuarantineConflict>());
        expect(file.readAsStringSync(), equalText ? original : changed);
      },
    );
  }

  test('revalidates source after preserving its baseline', () async {
    final before = await baseline(NativePgnDocumentStore());
    var reads = 0;
    final store = NativePgnDocumentStore(
      observe: (path) async {
        if (path == file.path && ++reads == 2) {
          File(p.join(root.path, 'replacement'))
            ..writeAsStringSync(changed)
            ..renameSync(file.path);
        }
        return observeFile(path);
      },
    );
    expect(await store.quarantine(before), isA<PgnQuarantineConflict>());
    expect(file.readAsStringSync(), changed);
  });

  test(
    'external replacement after validation is retained as uncertainty',
    () async {
      final before = await baseline(NativePgnDocumentStore());
      var reads = 0;
      final store = NativePgnDocumentStore(
        observe: (path) async {
          final observed = await observeFile(path);
          if (path == file.path && ++reads == 2) {
            // Simulate an uncooperative writer in the last validation/rename gap.
            File(p.join(root.path, 'replacement'))
              ..writeAsStringSync(changed)
              ..renameSync(file.path);
          }
          return observed;
        },
      );
      final result = await store.quarantine(before) as PgnQuarantineUncertain;
      expect(file.existsSync(), isFalse);
      expect(result.observedQuarantine!.content, changed);
      expect(File(result.quarantinePath).readAsStringSync(), changed);
      expect(File(result.recoveryPath).readAsStringSync(), original);
      expect(result.before.revision, before.revision);
    },
  );

  test(
    'directory-flush failure after move never becomes failed or success',
    () async {
      final before = await baseline(NativePgnDocumentStore());
      final store = NativePgnDocumentStore(
        flushDirectory: (path) async {
          if (path == root.path) {
            throw const FileSystemException('flush failed');
          }
          await syncDirectory(path);
        },
      );
      final result = await store.quarantine(before) as PgnQuarantineUncertain;
      expect(file.existsSync(), isFalse);
      expect(File(result.quarantinePath).readAsStringSync(), original);
      expect(File(result.recoveryPath).readAsStringSync(), original);
    },
  );

  test(
    'recreated source prevents acknowledgement without removing new work',
    () async {
      final before = await baseline(NativePgnDocumentStore());
      final store = NativePgnDocumentStore(
        flushDirectory: (path) async {
          if (path == root.path) file.writeAsStringSync(changed);
          await syncDirectory(path);
        },
      );
      final result = await store.quarantine(before) as PgnQuarantineUncertain;
      expect(file.readAsStringSync(), changed);
      expect(result.observedSource!.content, changed);
      expect(File(result.quarantinePath).readAsStringSync(), original);
    },
  );

  test(
    'domain acknowledgement failure retains the completed move evidence',
    () async {
      final before = await baseline(NativePgnDocumentStore());
      final store = NativePgnDocumentStore(
        guardOperation: <T>(path, action) async {
          await action();
          throw StateError('domain acknowledgement failed');
        },
      );
      final result = await store.quarantine(before) as PgnQuarantineUncertain;
      expect(result.observedQuarantine!.content, original);
      expect(File(result.quarantinePath).readAsStringSync(), original);
      expect(file.existsSync(), isFalse);
    },
  );

  test('save and quarantine with one baseline cannot both commit', () async {
    final store = NativePgnDocumentStore();
    final before = await baseline(store);
    final results = await Future.wait<Object>([
      store.quarantine(before),
      store.save(before, changed),
    ]);
    if (results.first is PgnQuarantined) {
      expect(results.last, isA<PgnConflict>());
      expect(file.existsSync(), isFalse);
    } else {
      expect(results.first, isA<PgnQuarantineConflict>());
      expect(results.last, isA<PgnSaved>());
      expect(file.readAsStringSync(), changed);
    }
  });

  test('native path move refuses an existing quarantine destination', () async {
    final occupied = File(p.join(root.path, 'occupied'))
      ..writeAsStringSync(changed);
    await expectLater(
      movePathNoReplace(file.path, occupied.path),
      throwsA(isA<NativeNameCollision>()),
    );
    expect(file.readAsStringSync(), original);
    expect(occupied.readAsStringSync(), changed);
  });

  test(
    'absent managed root does not block or create for external documents',
    () async {
      final missing = Directory(p.join(root.path, 'not-created'));
      final storage = IOStorageService(
        documentsRoot: missing,
        supportRoot: missing,
      );
      final store = NativePgnDocumentStore(
        guardOperation: storage.guardDocumentOperation,
      );
      final before = await baseline(store);
      expect(await store.save(before, changed), isA<PgnSaved>());
      expect(file.readAsStringSync(), changed);
      expect(missing.existsSync(), isFalse);
    },
  );

  for (final alias in [false, true]) {
    test(
      'repertoire rename waits for guarded quarantine (root alias: $alias)',
      () async {
        final library = Directory(p.join(root.path, 'repertoires'))
          ..createSync();
        final folder = Directory(p.join(library.path, 'Course'))..createSync();
        file = File(p.join(folder.path, 'Main.pgn'))
          ..writeAsStringSync(original);
        final configured = alias
            ? Directory(
                (Link(
                  p.join(root.path, 'library-alias'),
                )..createSync(library.path)).path,
              )
            : library;
        final storage = IOStorageService(
          documentsRoot: root,
          supportRoot: root,
          repertoiresRoot: configured,
        );
        final entered = Completer<void>();
        final release = Completer<void>();
        var armed = false;
        final store = NativePgnDocumentStore(
          guardOperation: storage.guardDocumentOperation,
          observe: (path) async {
            if (armed && path == file.path && !entered.isCompleted) {
              entered.complete();
              await release.future;
            }
            return observeFile(path);
          },
        );
        final before =
            (await store.open(p.join(configured.path, 'Course', 'Main.pgn'))
                    as PgnOpened)
                .snapshot;
        expect(before.path, file.path);
        armed = true;
        final removal = store.quarantine(before);
        await entered.future;
        var renamed = false;
        final rename = storage
            .renameRepertoireDirectory(
              p.join(configured.path, 'Course'),
              'Renamed',
            )
            .then((_) {
              renamed = true;
            });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(renamed, isFalse);
        release.complete();
        expect(await removal, isA<PgnQuarantined>());
        await rename;
        expect(Directory(p.join(library.path, 'Renamed')).existsSync(), isTrue);
        expect(
          File(p.join(library.path, 'Renamed', 'Main.pgn')).existsSync(),
          isFalse,
        );
      },
    );
  }
}
