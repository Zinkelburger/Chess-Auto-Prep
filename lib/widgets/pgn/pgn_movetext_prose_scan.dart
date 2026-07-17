part of 'pgn_movetext_view.dart';

/// A bare SAN move core (no move number, check/annotation glyphs), used to
/// pre-filter prose words before the (more expensive) legality check.
final RegExp _sanCoreRe = RegExp('^$kSanCorePattern\$');

// Prose-word tokenizers for [_extractLegalSan], hoisted so each prose word
// doesn't recompile them.
final RegExp _leadBracketRe = RegExp(r'^[(\["]+');
final RegExp _trailPunctRe = RegExp(r'[)\]",;.!?]+$');
final RegExp _moveNumberPrefixRe = RegExp(r'^\d+\.{1,3}');
final RegExp _ellipsisPrefixRe = RegExp(r'^\.{2,3}');
final RegExp _glyphSuffixRe = RegExp(r'[!?+#]+$');

/// Memoizes [_extractLegalSan] across rebuilds. Navigating the game
/// re-renders the whole movetext, and re-parsing every prose word's SAN from
/// scratch each time is what made move clicks lag on heavily-annotated
/// (book/study) PGNs. Keyed by the anchor FEN plus the word, so results are
/// correct across positions and games; the check is a pure function of those
/// two, so caching is always safe. Cleared wholesale past a size cap so the
/// map can't grow without bound over a long session.
final Map<String, ({String prefix, String san, String suffix})?>
_legalSanCache = {};

({String prefix, String san, String suffix})? _extractLegalSanCached(
  String word,
  Position pos,
  String anchorFen,
) {
  final key = '$anchorFen $word';
  final cached = _legalSanCache[key];
  if (cached != null || _legalSanCache.containsKey(key)) return cached;
  if (_legalSanCache.length > 50000) _legalSanCache.clear();
  final result = _extractLegalSan(word, pos);
  _legalSanCache[key] = result;
  return result;
}

/// Extract a legal SAN move from a single prose word, along with any leading
/// bracket / trailing punctuation to keep rendered separately. Returns null
/// when the word is not a legal move from [pos].
({String prefix, String san, String suffix})? _extractLegalSan(
  String word,
  Position pos,
) {
  final lead = _leadBracketRe.firstMatch(word);
  final prefix = lead?.group(0) ?? '';
  var rest = word.substring(prefix.length);
  final trail = _trailPunctRe.firstMatch(rest);
  final suffix = trail?.group(0) ?? '';
  rest = rest.substring(0, rest.length - suffix.length);
  if (rest.isEmpty) return null;
  // Strip a leading move number / ellipsis (8., 12..., …) and trailing glyphs.
  var core = rest
      .replaceFirst(_moveNumberPrefixRe, '')
      .replaceFirst(_ellipsisPrefixRe, '')
      .replaceFirst(_glyphSuffixRe, '');
  if (core.isEmpty || !_sanCoreRe.hasMatch(core)) return null;
  try {
    if (pos.parseSan(core) == null) return null;
  } catch (_) {
    return null;
  }
  return (prefix: prefix, san: core, suffix: suffix);
}

/// The (fullmove number, side) of a move played at [ply] half-moves in.
({int moveNumber, bool isWhite}) _coordsAtPly(PgnMovetextView view, int ply) =>
    coordsAtPly(
      ply: ply,
      startFullmoves: view.startingMoveNumber,
      startWhiteToMove: view.startingWhiteTurn,
    );

/// Replay the mainline into a list of positions: `[k]` is the board after
/// `k` half-moves. Returns null when there is no start position, or when
/// inline lines are disabled (nothing consumes the positions then).
//
// Per-game cache for the mainline replay: navigating just re-renders the same
// game, so replaying every SAN on each rebuild is wasted work. Keyed on the
// [moveHistory] list identity via an Expando so each live movetext view keeps
// its own entry — a single shared slot thrashed (full-game dartchess replay
// per build) whenever two viewers were mounted at once. The stored start and
// length are re-validated so comment/NAG edits (same positions) reuse the
// cache while an appended move (changed length) rebuilds it.
class _PrefixCacheEntry {
  const _PrefixCacheEntry(this.start, this.length, this.positions);
  final Position start;
  final int length;
  final List<Position> positions;
}

final Expando<_PrefixCacheEntry> _prefixCache = Expando<_PrefixCacheEntry>();

List<Position>? _buildPrefixPositions(PgnMovetextView view) {
  final start = view.startPosition;
  if (start == null || view.onPlayInlineLine == null) return null;
  final cached = _prefixCache[view.moveHistory];
  if (cached != null &&
      identical(cached.start, start) &&
      cached.length == view.moveHistory.length) {
    return cached.positions;
  }
  final positions = <Position>[start];
  Position pos = start;
  for (final data in view.moveHistory) {
    if (data.san == '--') {
      positions.add(pos);
      continue;
    }
    final move = pos.parseSan(data.san);
    if (move == null) break;
    pos = pos.play(move);
    positions.add(pos);
  }
  _prefixCache[view.moveHistory] = _PrefixCacheEntry(
    start,
    view.moveHistory.length,
    positions,
  );
  return positions;
}

Position? _posAt(List<Position>? prefix, int ply) =>
    (prefix != null && ply >= 0 && ply < prefix.length) ? prefix[ply] : null;
