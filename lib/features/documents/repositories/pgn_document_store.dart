import '../models/pgn_document.dart';

/// Public cross-feature PGN mutation contract. A replacement requires the
/// captured snapshot; there is no optional revision or force-overwrite flag.
abstract interface class PgnDocumentStore {
  Future<PgnOpenResult> open(String path);
  Future<PgnWriteResult> create(String path, String content);
  Future<PgnWriteResult> save(PgnSnapshot baseline, String content);
}
