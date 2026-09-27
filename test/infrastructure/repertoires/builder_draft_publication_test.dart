import 'dart:io';
import 'dart:convert';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/document_repertoire_repository.dart';
import 'package:chess_auto_prep/utils/atomic_file.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _InterceptingStore implements PgnDocumentStore {
  _InterceptingStore(this.delegate, this.onSave);
  final PgnDocumentStore delegate;
  @override
  bool get supportsQuarantine => delegate.supportsQuarantine;
  @override
  Future<PgnQuarantineResult> quarantine(
    PgnSnapshot baseline, {
    String? allowedRoot,
  }) => delegate.quarantine(baseline, allowedRoot: allowedRoot);
  final Future<PgnWriteResult> Function(PgnSnapshot, String) onSave;
  @override
  Future<PgnOpenResult> open(String path) => delegate.open(path);
  @override
  Future<PgnWriteResult> create(String path, String content) =>
      delegate.create(path, content);
  @override
  Future<PgnWriteResult> save(PgnSnapshot baseline, String content) =>
      onSave(baseline, content);
}

void main() {
  late Directory root;
  late File chapter;
  late NativePgnDocumentStore native;
  const original =
      '// Color: White\n\n[Event "Original"]\n[Custom "retained"]\n\n'
      '1. e4 {first comment} e5 *\n';
  const draft =
      '[Event "Recovered"]\n[FutureHeader "preserved"]\n[Result "*"]\n\n'
      '1. d4 {annotation} d5 (1... Nf6) 2. c4 *';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('builder-draft-publication-');
    chapter = File(p.join(root.path, 'chapter.pgn'));
    await chapter.writeAsString(original);
    native = NativePgnDocumentStore();
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'append retains source and draft text with native acknowledgement',
    () async {
      final repository = DocumentRepertoireRepository(native);
      final before =
          (await repository.read(chapter.path) as PgnOpened).snapshot;
      final result =
          await repository.appendPgn(chapter.path, draft) as PgnSaved;
      expect(result.before!.revision, before.revision);
      expect(result.after.content, '$original\n\n$draft\n');
      final reopened =
          (await repository.read(chapter.path) as PgnOpened).snapshot;
      expect(reopened.revision, result.after.revision);
      expect(reopened.content, result.after.content);
    },
  );

  test(
    'an external edit between observation and append is preserved',
    () async {
      const external = '[Event "External"]\n\n1. c4 e5 *\n';
      final repository = DocumentRepertoireRepository(
        _InterceptingStore(native, (baseline, content) async {
          await chapter.writeAsString(external);
          return native.save(baseline, content);
        }),
      );
      expect(
        await repository.appendPgn(chapter.path, draft),
        isA<PgnConflict>(),
      );
      expect(await chapter.readAsString(), external);
    },
  );

  test(
    'same-text replacement cannot rebase the native append baseline',
    () async {
      final repository = DocumentRepertoireRepository(
        _InterceptingStore(native, (baseline, content) async {
          await chapter.rename(p.join(root.path, 'external-original.pgn'));
          await File(chapter.path).writeAsString(original);
          return native.save(baseline, content);
        }),
      );
      expect(
        await repository.appendPgn(chapter.path, draft),
        isA<PgnConflict>(),
      );
      expect(await File(chapter.path).readAsString(), original);
    },
  );

  test('same decoded text with changed raw bytes remains a conflict', () async {
    final repository = DocumentRepertoireRepository(
      _InterceptingStore(native, (baseline, content) async {
        await chapter.writeAsString('\ufeff$original');
        final current = await native.open(chapter.path) as PgnOpened;
        expect(current.snapshot.content, baseline.content);
        return native.save(baseline, content);
      }),
    );
    expect(await repository.appendPgn(chapter.path, draft), isA<PgnConflict>());
    expect(await chapter.readAsBytes(), utf8.encode('\ufeff$original'));
  });

  test(
    'failed staging preserves original and does not acknowledge a copy',
    () async {
      final repository = DocumentRepertoireRepository(
        NativePgnDocumentStore(
          writer: AtomicFileWriter(
            testHook: (step) async {
              if (step == AtomicWriteStep.tempFlushed) {
                throw StateError('stage failed');
              }
            },
          ),
        ),
      );
      expect(
        await repository.appendPgn(chapter.path, draft),
        isA<PgnWriteFailed>(),
      );
      expect(await chapter.readAsString(), original);
    },
  );

  test(
    'uncertain installation retains native evidence for reconciliation',
    () async {
      final repository = DocumentRepertoireRepository(
        NativePgnDocumentStore(
          flushDirectory: (path) async {
            if (path == root.path) {
              throw StateError('directory acknowledgement lost');
            }
            await syncDirectory(path);
          },
        ),
      );
      final result =
          await repository.appendPgn(chapter.path, draft) as PgnWriteUncertain;
      expect(result.before!.content, original);
      expect(result.installedRevision, isNotNull);
      final observed =
          (await repository.read(chapter.path) as PgnOpened).snapshot;
      expect(observed.revision, result.installedRevision);
      expect(observed.content, '$original\n\n$draft\n');
      expect(result.observed!.revision, observed.revision);
    },
  );

  test(
    'unexpected loss of acknowledgement never replays an installed append',
    () async {
      var writes = 0;
      final repository = DocumentRepertoireRepository(
        _InterceptingStore(native, (baseline, content) async {
          writes++;
          expect(await native.save(baseline, content), isA<PgnSaved>());
          throw StateError('transport closed after installation');
        }),
      );
      final result =
          await repository.appendPgn(chapter.path, draft) as PgnWriteUncertain;
      expect(result.before!.content, original);
      expect(result.installedRevision, isNull);
      expect(result.observed, isNull);
      expect(writes, 1);
      expect(await chapter.readAsString(), '$original\n\n$draft\n');
    },
  );

  test(
    'missing destination is a failed append, never implicit creation',
    () async {
      await chapter.delete();
      final repository = DocumentRepertoireRepository(native);
      expect(await repository.read(chapter.path), isA<PgnMissing>());
      expect(
        await repository.appendPgn(chapter.path, draft),
        isA<PgnWriteFailed>(),
      );
      expect(await chapter.exists(), isFalse);
    },
  );
}
