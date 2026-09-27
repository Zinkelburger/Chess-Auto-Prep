/// Creates a repertoire using the same prepared chapter plan on every host.
/// Linux publishes the prepared directory atomically; other hosts retain any
/// acknowledged files if a later chapter cannot be confirmed.
library;

import 'dart:io';
import 'package:path/path.dart' as p;
import '../features/documents/models/pgn_document.dart';
import '../features/documents/repositories/pgn_document_store.dart';
import '../features/repertoires/models/repertoire_creation.dart';
import '../infrastructure/repertoires/repertoire_import_planner.dart';
import 'storage/storage_factory.dart';
import 'storage/storage_service.dart';
import 'storage/io_storage_service.dart';

Future<RepertoireCreationResult> createRepertoire({
  required String name,
  required String color,
  required PgnDocumentStore documents,
  String? pgnContent,
  int gameCount = 0,
  String chapterName = 'Main',
  DateTime? createdAt,
  StorageService? storage,
  bool splitChapters = true,
}) async {
  final store = storage ?? StorageFactory.instance;
  final request = CreateRepertoire(
    name: name,
    color: color,
    pgnContent: pgnContent,
    gameCount: gameCount,
    chapterName: chapterName,
    splitChapters: splitChapters,
  );
  final createdPaths = <String>[];
  Future<void> create(String path, String content) async {
    final outcome = await documents.create(path, content);
    switch (outcome) {
      case PgnSaved():
        createdPaths.add(outcome.after.path);
      case PgnNameCollision() when createdPaths.isEmpty:
        throw RepertoireExistsException(name);
      default:
        throw RepertoireCreationUncertain(
          cause: outcome,
          createdPaths: List.unmodifiable(createdPaths),
          pathsToInspect: [
            path,
            if (outcome is PgnWriteUncertain && outcome.recoveryPath != null)
              outcome.recoveryPath!,
          ],
        );
    }
  }

  if (Platform.isLinux && store is IOStorageService) {
    return store.publishRepertoire(
      request,
      createdAt: createdAt,
      createDocument: create,
    );
  }
  final date = createdAt ?? DateTime.now();
  final plan = await prepareRepertoireImport(request, date);
  final dirPath = await store.repertoireDirectoryPath(name);
  for (final chapter in plan.chapters.entries) {
    await create(p.join(dirPath, chapter.key), chapter.value);
  }
  return RepertoireCreationResult(
    directoryPath: dirPath,
    chapterPath: createdPaths.first,
    chapterPaths: createdPaths,
    gameCount: plan.gameCount,
  );
}
