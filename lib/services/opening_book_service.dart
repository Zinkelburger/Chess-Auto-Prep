/// Bundled lichess opening book (github.com/lichess-org/chess-openings, CC0).
///
/// Loads the `assets/data/openings/[a-e].tsv` files, replays each named line
/// once, and exposes a normalized-FEN → (ECO, name) map. Classification is
/// position-based, so games that transpose into a named opening are labeled
/// with it regardless of move order.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../utils/fen_utils.dart';
import '../utils/chess_utils.dart' show playSanOrNullMove;
import '../utils/san_token_utils.dart';
import 'opening_tsv.dart';

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

/// Parse the TSV contents (columns `eco / name / pgn`) into a FEN-keyed map.
///
/// Isolate-safe: no instance state captured.
Map<String, OpeningBookEntry> buildOpeningBookFromTsv(
  List<String> tsvContents,
) {
  final map = <String, OpeningBookEntry>{};
  for (final row in parseOpeningTsvRows(tsvContents)) {
    final tokens = cleanSanTokens(row.movetext);
    if (tokens.isEmpty) continue;
    final end = _replayLine(tokens);
    if (end == null) continue;

    // Distinct lines reaching the same position are duplicates by
    // definition — keep the first (TSV order).
    map.putIfAbsent(
      normalizeFen(end.fen),
      () => OpeningBookEntry(eco: row.eco, name: row.name, ply: tokens.length),
    );
  }
  return map;
}

/// The position after [sans] from the initial position, or null when any
/// token is not a legal move there.
Position? _replayLine(List<String> sans) {
  Position pos = Chess.initial;
  for (final san in sans) {
    final next = playSanOrNullMove(pos, san);
    if (next == null) return null;
    pos = next;
  }
  return pos;
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

/// Lazily loads and caches the bundled opening book.
class OpeningBookService {
  OpeningBookService._();
  static final OpeningBookService instance = OpeningBookService._();

  Future<OpeningBook>? _loading;

  Future<OpeningBook> load() => _loading ??= _load();

  Future<OpeningBook> _load() async => OpeningBook(
    await compute(buildOpeningBookFromTsv, await loadOpeningTsvVolumes()),
  );
}
