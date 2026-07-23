/// PGN clock parsing for flaw tempo tags: `[%clk]` comment tokens, the
/// `TimeControl` header, and per-move think time.
///
/// Chess.com PGNs carry `[%clk 0:09:58.8]` on every move; Lichess includes
/// them only when downloads request `clocks=true`.  Absence of clock data is
/// meaningful downstream ("couldn't measure" ≠ "didn't rush"), so every
/// helper here returns null rather than a fallback value.
library;

final RegExp _clkTokenRe = RegExp(
  r'\[%clk\s+(\d+):(\d{1,2}):(\d{1,2}(?:\.\d+)?)\]',
);

/// Remaining clock in seconds from a move's PGN comments, or null when no
/// `[%clk H:MM:SS(.t)]` token is present.
double? clockSecondsFromComments(List<String>? comments) {
  if (comments == null) return null;
  for (final comment in comments) {
    final m = _clkTokenRe.firstMatch(comment);
    if (m == null) continue;
    final hours = int.parse(m.group(1)!);
    final minutes = int.parse(m.group(2)!);
    final seconds = double.parse(m.group(3)!);
    return hours * 3600 + minutes * 60 + seconds;
  }
  return null;
}

/// Base time and increment in seconds from a PGN `TimeControl` header
/// ("600+5", "180", "40/9000"); (null, null) for unknown/absent forms like
/// "-", "?" or daily "1/86400".
(int? base, double? increment) parseTimeControl(String? timeControl) {
  final tc = timeControl?.trim() ?? '';
  if (tc.isEmpty) return (null, null);
  final m = RegExp(r'^(\d+)(?:\+(\d+(?:\.\d+)?))?$').firstMatch(tc);
  if (m == null) return (null, null);
  final base = int.parse(m.group(1)!);
  final inc = m.group(2) != null ? double.parse(m.group(2)!) : 0.0;
  return (base, inc);
}

/// Think time in seconds for the move at 0-based [ply], given the
/// index-aligned per-ply [clocks].
///
/// The mover's previous clock is two plies back (ply − 1 is the opponent's
/// clock).  Formula: `prev − current + increment` — the increment is granted
/// on completing a move, so the post-move clock already had it added back.
/// Null for first moves (ply < 2), missing clocks, or a negative result
/// (physically impossible; signals corrupt clock data, and letting it
/// through would mislabel the move as hasty).
double? moveTimeSeconds(List<double?> clocks, int ply, double increment) {
  if (ply < 2 || ply >= clocks.length) return null;
  final prev = clocks[ply - 2];
  final current = clocks[ply];
  if (prev == null || current == null) return null;
  final moveTime = prev - current + increment;
  if (moveTime < 0) return null;
  return moveTime;
}
