import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_creation.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late LegacyRepertoireCatalogRepository repository;

  setUp(() {
    root = Directory.systemTemp.createTempSync('catalog-contract-');
    Directory('${root.path}/repertoires').createSync();
    repository = LegacyRepertoireCatalogRepository(
      documents: NativePgnDocumentStore(),
      IOStorageService(
        documentsRoot: root,
        supportRoot: root,
        repertoiresRoot: Directory('${root.path}/repertoires'),
      ),
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'create, reopen, rename and recoverable delete preserve PGN bytes',
    () async {
      final created = await repository.create(
        const CreateRepertoire(
          name: 'Caro',
          color: 'Black',
          pgnContent: '[Event "Main"]\n\n1. e4 c6 *',
        ),
      );
      final bytes = File(created.chapterPath).readAsBytesSync();
      final entries = await repository.listRepertoires();
      expect(entries.single.name, 'Caro');
      final chapters = await repository.listChapters(entries.single.filePath);
      expect(chapters.single.filePath, created.chapterPath);
      await repository.rename(entries.single, 'Caro-Kann');
      final renamed = (await repository.listRepertoires()).single;
      expect(renamed.name, 'Caro-Kann');
      expect(File('${renamed.filePath}/Main.pgn').readAsBytesSync(), bytes);
      await repository.moveToRecovery(renamed);
      expect(await repository.listRepertoires(), isEmpty);
      final recovered = root
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (file) =>
                file.path.contains('.chess_auto_prep_trash') &&
                file.path.endsWith('.pgn'),
          );
      expect(recovered, hasLength(1));
      expect(recovered.single.readAsBytesSync(), bytes);
      if (repository.supportsRecovery) {
        final entry = (await repository.listRecovery()).single;
        await repository.restore(entry.id);
        expect(await repository.listRecovery(), isEmpty);
        final restored = (await repository.listRepertoires()).single;
        expect(restored.name, 'Caro-Kann');
        expect(File('${restored.filePath}/Main.pgn').readAsBytesSync(), bytes);
      }
    },
  );

  test('competing creation never replaces the winning chapter', () async {
    const request = CreateRepertoire(name: 'Same', color: 'White');
    final results = await Future.wait([
      for (var i = 0; i < 2; i++)
        repository
            .create(request)
            .then<Object>((value) => value, onError: (Object error) => error),
    ]);
    expect(results.whereType<RepertoireCreationResult>(), hasLength(1));
    expect(results.whereType<RepertoireExistsException>(), hasLength(1));
    final winner = results.whereType<RepertoireCreationResult>().single;
    expect(
      File(winner.chapterPath).readAsStringSync(),
      contains('// Color: White'),
    );
  });

  test('invalid names and colours cannot create files', () async {
    await expectLater(
      repository.create(
        const CreateRepertoire(name: '../outside', color: 'White'),
      ),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      repository.create(const CreateRepertoire(name: 'Valid', color: 'Other')),
      throwsArgumentError,
    );
    expect(await repository.listRepertoires(), isEmpty);
  });

  test('rename collision leaves both repertoires untouched', () async {
    for (final name in ['First', 'Second']) {
      await repository.create(CreateRepertoire(name: name, color: 'White'));
    }
    final entries = await repository.listRepertoires();
    final first = entries.firstWhere((entry) => entry.name == 'First');
    await expectLater(
      repository.rename(first, 'Second'),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      (await repository.listRepertoires()).map((entry) => entry.name),
      containsAll(['First', 'Second']),
    );
  });
}
