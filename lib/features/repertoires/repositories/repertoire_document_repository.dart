import '../../documents/models/pgn_document.dart';
import '../models/repertoire_mutation_receipt.dart';

/// Exact acknowledged document and target game after a line edit. Consumers
/// advance their full-document baseline only from this committed result.
typedef RepertoireLineSaveReceipt = ({
  String documentPgn,
  PgnSnapshot? snapshot,
  String linePgn,
  int lineIndex,
});

/// Chapter storage boundary. Replacements require the captured decoded content;
/// adapters also validate the observed document revision at publication.
abstract interface class RepertoireDocumentRepository {
  /// Observations retain native identity and bytes digest for recovery decisions.
  Future<PgnOpenResult> read(String path);

  /// Append captured game text to one freshly observed chapter. Publication
  /// validates that exact revision, including identity, without reopening to
  /// rebase against equal decoded text. Never replay an uncertain append.
  Future<PgnWriteResult> appendPgn(String path, String capturedPgn);
  Future<void> replace(
    String path,
    String content, {
    required String expectedContent,
  });
  Future<bool> deleteLine(
    String path,
    String lineId, {
    required String expectedContent,
  });
  Future<int> deleteLinesAt(String path, Map<int, String> expectedGames);
  Future<RepertoireLineSaveReceipt?> updateLineContent(
    String path,
    String lineId,
    String content, {
    required String expectedContent,
  });

  /// Restore only the captured native revision; never reopen to rebase it.
  Future<PgnSnapshot> restore(PgnSnapshot expected, String content);

  Future<RepertoireMutationReceipt> append(
    String path,
    List<String> prefix,
    List<String> moves, {
    String? startingFen,
    bool isWhiteRepertoire = true,
  });
}
