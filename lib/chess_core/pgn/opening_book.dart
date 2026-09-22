class OpeningBookEntry {
  final String eco;
  final String name;

  /// Length in plies of the book line defining this entry. A game's opening
  /// is the book position it reaches with the highest [ply] — the most
  /// specific named line.
  final int ply;

  const OpeningBookEntry({
    required this.eco,
    required this.name,
    required this.ply,
  });
}

class OpeningBook {
  /// Normalized FEN (4-field, see [normalizeFen]) → book entry.
  final Map<String, OpeningBookEntry> byFen;

  const OpeningBook(this.byFen);
}

/// Classify every game using a prebuilt FEN → game-indices index: for each
/// book position a game passes through, keep the deepest (highest-ply) entry.
///
/// O(book size) map lookups — no game replay needed.
List<OpeningBookEntry?> classifyGamesFromIndex(
  OpeningBook book,
  Map<String, List<int>> fenIndex,
  int gameCount,
) {
  final result = List<OpeningBookEntry?>.filled(gameCount, null);
  book.byFen.forEach((fen, entry) {
    final games = fenIndex[fen];
    if (games == null) return;
    for (final g in games) {
      if (g < 0 || g >= gameCount) continue;
      final current = result[g];
      if (current == null || entry.ply > current.ply) result[g] = entry;
    }
  });
  return result;
}
