import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_decoder.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_document_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/document_repertoire_repository.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/isolate_repertoire_decoder.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';

/// Legacy test fixtures install disposable storage. Capture it once here;
/// production controllers never resolve the global, even during later writes.
RepertoireController testRepertoireController({
  RepertoireDocumentRepository? documents,
  RepertoireDecoder decoder = const IsolateRepertoireDecoder(),
}) => RepertoireController(
  documents: documents ?? testRepertoireDocuments(),
  decoder: decoder,
);

RepertoireDocumentRepository testRepertoireDocuments() =>
    DocumentRepertoireRepository(
      LegacyPgnDocumentStore(StorageFactory.instance),
    );
