import '../features/generation/services/generation_artifacts.dart';
import '../infrastructure/generation/storage_generation_artifact_repository.dart';
import '../features/documents/repositories/pgn_document_store.dart';
import '../features/generation/controllers/generation_publication_controller.dart';
import '../infrastructure/documents/legacy_pgn_document_store.dart';
import '../infrastructure/generation/storage_generation_draft_repository.dart';
import '../services/storage/storage_factory.dart';

GenerationPublicationController createGenerationPublication({
  required PgnDocumentStore? documents,
}) {
  final storage = StorageFactory.instance;
  return GenerationPublicationController(
    documents: documents ?? LegacyPgnDocumentStore(storage),
    drafts: StorageGenerationDraftRepository(storage),
  );
}

GenerationArtifacts createGenerationArtifacts({
  required PgnDocumentStore? documents,
}) {
  final storage = StorageFactory.instance;
  return GenerationArtifacts(
    StorageGenerationArtifactRepository(
      storage: storage,
      documents: documents ?? LegacyPgnDocumentStore(storage),
    ),
  );
}
