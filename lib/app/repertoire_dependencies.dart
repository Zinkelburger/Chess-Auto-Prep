import '../features/repertoires/repositories/repertoire_catalog_repository.dart';
import '../features/repertoire/services/chapter_splitter.dart';
import '../features/repertoire/services/repertoire_outline_service.dart';
import '../features/documents/repositories/pgn_document_store.dart';
import '../features/repertoires/repositories/repertoire_decoder.dart';
import '../features/repertoires/repositories/repertoire_document_repository.dart';
import '../infrastructure/repertoires/document_repertoire_repository.dart';
import '../infrastructure/repertoires/isolate_repertoire_decoder.dart';
import '../services/storage/storage_factory.dart';

/// Composition for the Builder host and Trainer's board session. The host's
/// document protocol is selected once by app startup, not by its screens.
RepertoireDocumentRepository createRepertoireDocuments({
  required PgnDocumentStore documents,
}) => DocumentRepertoireRepository(documents);

RepertoireDecoder createRepertoireDecoder() => const IsolateRepertoireDecoder();

RepertoireOutlineService createRepertoireOutline({
  required RepertoireCatalogRepository catalog,
  required PgnDocumentStore documents,
}) {
  final storage = StorageFactory.instance;
  return RepertoireOutlineService(
    catalog: catalog,
    storage: storage,
    splitter: ChapterSplitter(storage: storage, documents: documents),
  );
}
