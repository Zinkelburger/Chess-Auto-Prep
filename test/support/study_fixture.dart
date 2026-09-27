import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/features/studies/repositories/study_library_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/studies/legacy_study_library_repository.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'scripted_document_store.dart';

StudyController studyWithStorage(StorageService storage) {
  final documents = LegacyPgnDocumentStore(storage);
  return StudyController(
    library: LegacyStudyLibraryRepository(storage, documents),
    documents: documents,
  );
}

StudyController memoryStudy() =>
    StudyController(library: MemoryStudyLibrary(), documents: Store());

class MemoryStudyLibrary implements StudyLibraryRepository {
  final recoveries = <String>[];
  final deleted = <String>[];
  Future<void> Function()? beforeDelete;
  @override
  Future<List<RepertoireMetadata>> list() async => [];
  @override
  Future<String> pathForName(String name) async => '/studies/$name.pgn';
  @override
  Future<String> suggestNewPath(String name) => pathForName(name);
  @override
  Future<bool> exists(String path) async => false;
  @override
  Future<PgnSnapshot> rename(PgnSnapshot baseline, String destination) async =>
      snapshot(
        baseline.content,
        path: destination,
        revision: baseline.revision.nativeIdentity,
      );
  @override
  Future<void> delete(String path) async {
    await beforeDelete?.call();
    deleted.add(path);
  }

  @override
  Future<String?> retainRecovery(String name, String content) async {
    recoveries.add(content);
    return '/recovered.pgn';
  }
}
