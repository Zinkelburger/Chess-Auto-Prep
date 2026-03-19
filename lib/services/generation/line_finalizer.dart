/// Shared helpers for final line emission at DFS leaves.
library;

class LineFinalizer {
  static Future<List<String>?> finalize({
    required List<String> lineSan,
    required bool isOurMove,
    required bool hasLegalMoves,
    required Future<String?> Function() findOurBestResponse,
  }) async {
    if (lineSan.isEmpty) return null;

    var finalLine = lineSan;
    if (isOurMove && hasLegalMoves) {
      final response = await findOurBestResponse();
      if (response != null) finalLine = [...lineSan, response];
    }

    final endsWithOurMove = !isOurMove || finalLine.length > lineSan.length;
    return endsWithOurMove ? finalLine : null;
  }
}
