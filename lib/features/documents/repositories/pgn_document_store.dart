import '../models/pgn_document.dart';

/// Public cross-feature PGN mutation contract. A replacement requires the
/// captured snapshot; there is no optional revision or force-overwrite flag.
abstract interface class PgnDocumentStore {
  bool get supportsQuarantine;

  /// A caller may further constrain removal to its configured managed root.
  /// The native mutation validates that root inside its existing file lock.
  Future<PgnQuarantineResult> quarantine(
    PgnSnapshot baseline, {
    String? allowedRoot,
  });
  Future<PgnOpenResult> open(String path);
  Future<PgnWriteResult> create(String path, String content);
  Future<PgnWriteResult> save(PgnSnapshot baseline, String content);
}
