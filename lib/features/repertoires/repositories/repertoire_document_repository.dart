import '../../../chess_core/pgn/repertoire_document_mutation.dart';

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
    bool reconcileInstalled = false,
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
  Future<AppendMovesResult> append(
    String path,
    List<String> prefix,
    List<String> moves, {
    String? startingFen,
    bool isWhiteRepertoire = true,
  });
}
