/// Replaying parsed games to find positions: does a game pass through a
/// FEN, what follows it, and the inverted FEN → game index the viewer keeps
/// on disk beside each collection.
///
/// Every helper here is isolate-safe (no instance state captured).
library;

import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:dartchess/dartchess.dart';

import 'package:chess_auto_prep/chess_core/pgn/pgn_dummy_mainline.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart'
    show isNullMoveSan, playSanOrNullMove;
import 'package:chess_auto_prep/utils/fen_utils.dart';

// ── Start position ───────────────────────────────────────────────────────────

/// Determines the starting [Position] for a parsed PGN game.
///
/// Uses a nonempty `[FEN]` header, including exports without `[SetUp]`;
/// otherwise returns [Chess.initial].
Position startPositionFromGame(PgnGame game) {
  try {
    return _positionFromHeaders(game.headers);
  } catch (_) {
    // An unparsable FEN header: the viewer shows the game from the standard
    // start rather than refusing it.
    return Chess.initial;
  }
}

/// Throws when a nonempty `[FEN]` is unparsable — replay helpers catch that
/// and skip the game. [startPositionFromGame] falls back to the initial
/// position instead.
Position _positionFromHeaders(Map<String, String> headers) {
  final fenHeader = headers['FEN']?.trim() ?? '';
  if (fenHeader.isNotEmpty) {
    return Chess.fromSetup(Setup.parseFen(expandFen(fenHeader)));
  }
  return Chess.initial;
}

PgnGame<PgnNodeData> _parsePgnForReplay(String pgnText) {
  final game = parsePgnGame(pgnText);
  promoteNullMoveDummyMainline(game.moves);
  return game;
}

// ── Tree walk ────────────────────────────────────────────────────────────────

/// DFS over the parsed tree, mainline children first. [visit] returning
/// false stops the walk. Iterative so a hostile 500-deep RAV nest cannot
/// blow the stack.
void _forEachPgnNode(
  PgnNode<PgnNodeData> root,
  Position start,
  bool Function(Position pos, PgnNode<PgnNodeData> node) visit, {
  bool includeVariations = true,
}) {
  if (!visit(start, root)) return;
  final stack = <({PgnNode<PgnNodeData> node, Position pos})>[
    (node: root, pos: start),
  ];
  while (stack.isNotEmpty) {
    final cur = stack.removeLast();
    final kids = cur.node.children;
    final childCount = includeVariations ? kids.length : (kids.isEmpty ? 0 : 1);
    for (var i = childCount - 1; i >= 0; i--) {
      final next = playSanOrNullMove(cur.pos, kids[i].data.san);
      if (next == null) continue;
      if (!visit(next, kids[i])) return;
      stack.add((node: kids[i], pos: next));
    }
  }
}

/// The SANs of the first-child chain below [node], at most [maxPlies] long.
List<String> _mainlineSansBelow(
  PgnNode<PgnNodeData> node, {
  required int maxPlies,
}) {
  final remaining = <String>[];
  var n = node;
  while (n.children.isNotEmpty && remaining.length < maxPlies) {
    final child = n.children.first;
    remaining.add(child.data.san);
    n = child;
  }
  return remaining;
}

// ── A game parsed once ───────────────────────────────────────────────────────

/// A game parsed once for every replay-based predicate a slice applies to
/// it.  The slow slice path used to parse the same game up to three times —
/// once per predicate — which is the whole cost of a slice on a collection
/// without a `.fenidx`.
class PgnReplayGame {
  PgnReplayGame._(this.game, this.start);

  final PgnGame<PgnNodeData> game;
  final Position start;

  /// Null when the game or its `[FEN]` header does not parse; every
  /// predicate then reports no match, as the per-call parses did.
  static PgnReplayGame? tryParse(Map<String, String> headers, String pgnText) {
    try {
      return PgnReplayGame._(
        _parsePgnForReplay(pgnText),
        _positionFromHeaders(headers),
      );
    } catch (_) {
      // Documented above: an unparsable game matches nothing.
      return null;
    }
  }

  /// Whether the game reaches [targetFen] (already normalized), in its
  /// mainline or — unless [includeVariations] is false — any sideline.
  bool passesThroughFen(String targetFen, {bool includeVariations = true}) {
    var found = false;
    _forEachPgnNode(game.moves, start, (pos, _) {
      if (normalizeFen(pos.fen) == targetFen) {
        found = true;
        return false;
      }
      return true;
    }, includeVariations: includeVariations);
    return found;
  }

  /// The mainline's real moves, null moves left out.
  List<String> get mainlineSans => [
    for (final node in game.moves.mainline())
      if (!isNullMoveSan(node.san)) node.san,
  ];
}

/// Whether [pgnText] contains a position matching [targetFen] (normalized).
///
/// Walks the mainline and RAVs, so a course chapter that only reaches the
/// position in a sideline still matches.
bool gamePassesThroughFen(
  Map<String, String> headers,
  String pgnText,
  String targetFen, {
  bool includeVariations = true,
}) =>
    PgnReplayGame.tryParse(
      headers,
      pgnText,
    )?.passesThroughFen(targetFen, includeVariations: includeVariations) ??
    false;

/// SAN after [targetFen] is reached, along the line that found it (the
/// mainline of that variation, or the game mainline when the hit is there).
/// Empty if the FEN is never hit, or if the line ends at that position.
///
/// Caps at [maxPlies] so a list row never materialises a whole long game.
List<String> mainlineSansAfterFen(
  Map<String, String> headers,
  String pgnText,
  String targetFen, {
  int maxPlies = 40,
}) {
  try {
    final game = _parsePgnForReplay(pgnText);
    final target = normalizeFen(targetFen);
    List<String>? remaining;
    _forEachPgnNode(game.moves, _positionFromHeaders(headers), (pos, node) {
      if (normalizeFen(pos.fen) != target) return true;
      remaining = _mainlineSansBelow(node, maxPlies: maxPlies);
      return false;
    });
    return remaining ?? const [];
  } catch (_) {
    // An unparsable game or FEN header has no continuation to show.
    return const [];
  }
}

// ── FEN position index ───────────────────────────────────────────────────────

/// Build an inverted index mapping normalized FEN → sorted game indices.
///
/// Replays each game's mainline **and RAVs** and records every position
/// reached, so opening-tree "games at this position" and position-slice
/// filters see course sidelines, not just each chapter's mainline.
Map<String, List<int>> buildFenIndex(
  List<({Map<String, String> headers, String pgnText})> games, {
  bool includeVariations = true,
}) {
  final index = <String, List<int>>{};

  void record(String fen, int gameIdx) {
    final list = index[fen];
    if (list == null) {
      index[fen] = [gameIdx];
    } else if (list.last != gameIdx) {
      list.add(gameIdx);
    }
  }

  for (var i = 0; i < games.length; i++) {
    try {
      final game = _parsePgnForReplay(games[i].pgnText);
      _forEachPgnNode(game.moves, _positionFromHeaders(games[i].headers), (
        pos,
        _,
      ) {
        record(normalizeFen(pos.fen), i);
        return true;
      }, includeVariations: includeVariations);
    } catch (_) {
      // Best-effort; a game that does not parse is simply absent from the
      // index.
    }
  }

  return index;
}

/// Isolate entry point for a mainline-only position index.
Map<String, List<int>> buildMainlineFenIndex(
  List<({Map<String, String> headers, String pgnText})> games,
) => buildFenIndex(games, includeVariations: false);

// ── FEN index persistence ────────────────────────────────────────────────────

/// Format tag of the persisted index. v3 honors FEN headers without SetUp;
/// older indexes rebuild so setup chapters cannot retain incorrect positions.
const String _kFenIndexFormat = 'FENIDX3';

/// Serialize a FEN index for disk storage.
///
/// Format header: `FENIDX3 <gameCount> <fileSize> <modifiedMs>`, then
/// one `FEN\tidx,idx,...` per entry.  [fileSize] and [modifiedMs] are the
/// PGN file's byte-size and last-modified epoch-ms at build time, used for
/// staleness detection on load.
String serializeFenIndex(
  Map<String, List<int>> index, {
  required int gameCount,
  required int fileSize,
  required int modifiedMs,
}) {
  final buf = StringBuffer();
  buf.writeln('$_kFenIndexFormat $gameCount $fileSize $modifiedMs');
  for (final entry in index.entries) {
    buf.write(entry.key);
    buf.write('\t');
    buf.writeln(entry.value.join(','));
  }
  return buf.toString();
}

/// Deserialize a FEN index from disk.  Returns `null` if the format is
/// invalid or the stored file metadata doesn't match the current PGN file.
Map<String, List<int>>? deserializeFenIndex(
  String data, {
  required int expectedGameCount,
  required int expectedFileSize,
  required int expectedModifiedMs,
}) {
  final firstNl = data.indexOf('\n');
  if (firstNl < 0) return null;

  final header = data.substring(0, firstNl).trim().split(' ');
  // Older replay semantics or unknown format — force rebuild.
  if (header.length != 4 || header[0] != _kFenIndexFormat) return null;
  if (int.tryParse(header[1]) != expectedGameCount) return null;
  if (int.tryParse(header[2]) != expectedFileSize) return null;
  if (int.tryParse(header[3]) != expectedModifiedMs) return null;

  final index = <String, List<int>>{};
  var start = firstNl + 1;
  while (start < data.length) {
    var end = data.indexOf('\n', start);
    if (end < 0) end = data.length;
    var line = data.substring(start, end);
    start = end + 1;
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    if (line.isEmpty) continue;

    final tab = line.indexOf('\t');
    if (tab < 0) continue;
    final fen = line.substring(0, tab);
    final ids = <int>[];
    for (final s in line.substring(tab + 1).split(',')) {
      final v = int.tryParse(s);
      if (v == null) continue;
      // Reject a stale/malformed index: any game reference outside
      // `[0, expectedGameCount)` would point past `allGames` and crash
      // consumers. Returning null forces the caller to rebuild from scratch.
      if (v < 0 || v >= expectedGameCount) return null;
      ids.add(v);
    }
    if (ids.isNotEmpty) index[fen] = ids;
  }
  return index;
}
