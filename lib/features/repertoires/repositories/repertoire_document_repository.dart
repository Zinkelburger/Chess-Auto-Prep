import '../../documents/models/pgn_document.dart';
import '../models/repertoire_mutation_receipt.dart';

/// Exact acknowledged document and target game after a line edit. Consumers
/// advance their full-document baseline only from this committed result.
typedef RepertoireLineSaveReceipt = ({
  String documentPgn,
  String linePgn,
  int lineIndex,
});

/// Chapter storage boundary. Replacements require the captured decoded content;
/// adapters also validate the observed document revision at publication.
abstract interface class RepertoireDocumentRepository {
  Future<({bool exists, String? pgn})> read(String path);
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
