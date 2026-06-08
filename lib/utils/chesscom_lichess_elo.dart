/// Chess.com blitz → Lichess blitz Elo conversion for Maia and human-style modeling.
///
/// Maia-3 was trained on Lichess-scale ratings. Chess.com PGN headers use
/// Chess.com blitz Elos, which are not 1:1 with Lichess. This module holds the
/// empirical lookup used when importing Chess.com games (see
/// [TacticsImportService.importGamesFromChessCom]).
///
/// **Assumption:** all Chess.com tactic imports are treated as **blitz**;
/// other time controls in the PGN are not distinguished yet.
///
/// **Table source:** community rating-alignment study (Chess.com blitz column →
/// Lichess blitz column; sample sizes and other TC columns omitted). Anchors
/// are piecewise-linear interpolated; values below/above the table clamp to
/// the nearest endpoint before callers apply Maia bounds (600–2400).
library;

/// Sorted (Chess.com blitz, Lichess blitz) anchors — do not reorder.
const List<(int chessCom, int lichessBlitz)> kChessComBlitzToLichessBlitzTable =
    [
  (500, 1030),
  (600, 1075),
  (700, 1145),
  (800, 1200),
  (900, 1335),
  (1000, 1420),
  (1100, 1475),
  (1150, 1525),
  (1200, 1565),
  (1250, 1605),
  (1300, 1635),
  (1350, 1670),
  (1400, 1705),
  (1450, 1745),
  (1500, 1780),
  (1550, 1815),
  (1600, 1850),
  (1650, 1895),
  (1700, 1910),
  (1750, 1950),
  (1800, 1970),
  (1850, 2005),
  (1900, 2050),
  (1950, 2075),
  (2000, 2100),
  (2100, 2170),
  (2200, 2235),
  (2300, 2295),
  (2400, 2370),
  (2500, 2445),
  (2600, 2560),
  (2700, 2625),
  (2800, 2695),
  (2900, 2780),
  (3000, 2850),
];

/// Maps a Chess.com **blitz** rating to the empirical Lichess blitz equivalent.
///
/// Linear interpolation between [kChessComBlitzToLichessBlitzTable] anchors;
/// out-of-range inputs clamp to the first/last Lichess value (not extrapolated).
int chessComBlitzToLichessBlitz(int chessComBlitz) {
  final table = kChessComBlitzToLichessBlitzTable;
  if (table.isEmpty) return chessComBlitz;

  if (chessComBlitz <= table.first.$1) return table.first.$2;
  if (chessComBlitz >= table.last.$1) return table.last.$2;

  for (var i = 0; i < table.length - 1; i++) {
    final lo = table[i];
    final hi = table[i + 1];
    if (chessComBlitz < lo.$1) continue;
    if (chessComBlitz > hi.$1) continue;
    if (chessComBlitz == lo.$1) return lo.$2;
    if (chessComBlitz == hi.$1) return hi.$2;
    final t = (chessComBlitz - lo.$1) / (hi.$1 - lo.$1);
    return (lo.$2 + t * (hi.$2 - lo.$2)).round();
  }

  return table.last.$2;
}
