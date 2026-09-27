import '../models/pgn_document.dart';
import 'pgn_document_store.dart';

/// Save only uniquely matching source games, preserving every other byte.
/// Native adapters validate the observed whole-file revision at publication.
abstract interface class PgnCollectionRepository implements PgnDocumentStore {
  Future<PgnWriteResult> patch(String path, Map<String, String> replacements);
  Future<String?> retainRecovery(String content);
  Future<DateTime?> modified(String path);
}
