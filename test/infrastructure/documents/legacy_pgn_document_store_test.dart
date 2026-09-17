import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:chess_auto_prep/utils/atomic_file.dart';
import 'package:flutter_test/flutter_test.dart';

class Storage extends Fake implements StorageService {
  String? text;
  Object? readError;
  Object? writeError;
  void Function()? afterWrite;
  @override
  Future<String?> readFile(String path) async {
    if (readError != null) throw readError!;
    return text;
  }

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (createOnly && text != null ||
        expectedContent != null && text != expectedContent) {
      throw AtomicWriteConflict(path);
    }
    if (writeError != null) throw writeError!;
    text = content;
    afterWrite?.call();
  }
}

void main() {
  late Storage storage;
  late LegacyPgnDocumentStore store;
  setUp(() {
    storage = Storage();
    store = LegacyPgnDocumentStore(storage);
  });
  test('missing and unreadable observations differ', () async {
    expect(await store.open('/study'), isA<PgnMissing>());
    storage.readError = StateError('permission');
    expect(await store.open('/study'), isA<PgnReadFailed>());
  });
  test(
    'create collision and captured-content conflict never overwrite',
    () async {
      final created = await store.create('/study', 'original') as PgnSaved;
      expect(
        await store.create('/study', 'overwrite'),
        isA<PgnNameCollision>(),
      );
      storage.text = 'external';
      expect(await store.save(created.after, 'stale'), isA<PgnConflict>());
      expect(storage.text, 'external');
    },
  );
  test('success receipt never adopts a later external edit', () async {
    storage.afterWrite = () => storage.text = 'external after commit';
    final created = await store.create('/study', 'submitted') as PgnSaved;
    expect(created.after.content, 'submitted');
    expect(await store.save(created.after, 'next'), isA<PgnConflict>());
  });
  test(
    'legacy exception cannot prove a failed commit and blocks blind retry',
    () async {
      final created = await store.create('/study', 'original') as PgnSaved;
      storage.afterWrite = () => throw StateError('lost acknowledgement');
      final result =
          await store.save(created.after, 'installed') as PgnWriteUncertain;
      expect(result.before, same(created.after));
      expect(result.observed!.content, 'installed');
    },
  );
}
