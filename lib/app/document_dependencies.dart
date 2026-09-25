import 'dart:io';

import '../features/documents/repositories/pgn_document_store.dart';
import '../infrastructure/documents/legacy_pgn_document_store.dart';
import '../infrastructure/documents/native_pgn_document_store.dart';
import '../services/storage/io_storage_service.dart';
import '../services/storage/storage_factory.dart';

/// Adopt only on the verified host; the remaining native commit protocols
/// keep their documented legacy adapter until their platform gates pass.
PgnDocumentStore createPlatformDocumentStore() {
  final storage = StorageFactory.instance;
  if (!Platform.isLinux) return LegacyPgnDocumentStore(storage);
  return NativePgnDocumentStore(
    guardOperation: storage is IOStorageService
        ? storage.guardDocumentOperation
        : null,
  );
}
