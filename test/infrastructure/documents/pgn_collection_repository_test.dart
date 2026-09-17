import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_collection_repository.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/utils/atomic_file.dart';

void main() {
  late Directory root;
  late File file;
  late IOStorageService storage;
  const first = '[Event "One"]\n\n1. e4 *';
  const second = '[Event "Two"]\n\n1. d4 {external note} *';
  const content = '; User banner\n\n$first\n\n$second\n';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('collection-native-');
    file = File('${root.path}/games.pgn');
    await file.writeAsString(content);
    storage = IOStorageService(documentsRoot: root);
  });
  tearDown(() => root.delete(recursive: true));
  test(
    'native patch retains unrelated bytes and archives the exact pre-save file',
    () async {
      final repository = StoragePgnCollectionRepository(
        storage,
        documents: NativePgnDocumentStore(),
      );
      final result = await repository.patch(file.path, {
        first: '$first\n{my note}',
      });
      expect(result, isA<PgnSaved>());
      expect(
        await file.readAsString(),
        content.replaceFirst(first, '$first\n{my note}'),
      );
      expect(
        await File((result as PgnSaved).recoveryPath!).readAsString(),
        content,
      );
    },
  );
  test(
    'changed or ambiguous source games are conflicts with no writes',
    () async {
      final repository = StoragePgnCollectionRepository(
        storage,
        documents: NativePgnDocumentStore(),
      );
      await file.writeAsString('$first\n\n$first\n');
      expect(
        await repository.patch(file.path, {first: '$first\n{mine}'}),
        isA<PgnConflict>(),
      );
      expect(await file.readAsString(), '$first\n\n$first\n');
      expect(
        await repository.patch(file.path, {second: 'stale'}),
        isA<PgnConflict>(),
      );
    },
  );
  test(
    'replacement after observation is rejected before native publication',
    () async {
      var replaced = false;
      final store = NativePgnDocumentStore(
        writer: AtomicFileWriter(
          testHook: (step) async {
            if (!replaced && step == AtomicWriteStep.tempFlushed) {
              replaced = true;
              final replacement = File('${root.path}/replacement');
              await replacement.writeAsString(content);
              await replacement.rename(file.path);
            }
          },
        ),
      );
      final repository = StoragePgnCollectionRepository(
        storage,
        documents: store,
      );
      expect(
        await repository.patch(file.path, {first: '$first\n{mine}'}),
        isA<PgnConflict>(),
      );
      expect(await file.readAsString(), content);
    },
  );
}
