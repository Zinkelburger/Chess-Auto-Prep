import '../features/documents/repositories/pgn_document_store.dart';
import '../features/studies/controllers/study_controller.dart';
import '../infrastructure/documents/legacy_pgn_document_store.dart';
import '../infrastructure/studies/legacy_study_library_repository.dart';
import '../services/storage/storage_factory.dart';

/// App-lifetime editor with explicitly injected document and library adapters.
StudyController createStudyController({PgnDocumentStore? documents}) {
  final storage = StorageFactory.instance;
  final store = documents ?? LegacyPgnDocumentStore(storage);
  return StudyController(
    library: LegacyStudyLibraryRepository(storage, store),
    documents: store,
  );
}
