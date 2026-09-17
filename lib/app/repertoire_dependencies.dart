import '../features/documents/repositories/pgn_document_store.dart';
import '../features/repertoires/repositories/repertoire_decoder.dart';
import '../features/repertoires/repositories/repertoire_document_repository.dart';
import '../infrastructure/documents/legacy_pgn_document_store.dart';
import '../infrastructure/repertoires/document_repertoire_repository.dart';
import '../infrastructure/repertoires/isolate_repertoire_decoder.dart';
import '../services/storage/storage_factory.dart';

/// Composition for the Builder host and Trainer's board session. The host's
/// document protocol is selected once by app startup, not by its screens.
RepertoireDocumentRepository createRepertoireDocuments({
  required PgnDocumentStore? documents,
}) => DocumentRepertoireRepository(
  documents ?? LegacyPgnDocumentStore(StorageFactory.instance),
);

RepertoireDecoder createRepertoireDecoder() => const IsolateRepertoireDecoder();
