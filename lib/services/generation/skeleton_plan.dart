/// User-supplied skeleton: the lines a player already knows they want, plus
/// structure features they want to steer toward or away from.
///
/// A skeleton is the input the generation "front door" was missing (see
/// `docs/REPERTOIRE_PLANNING.md`). It carries three things the build reads:
///
///   1. **Pins** — our-move decisions the user made by playing them. At a
///      position whose 4-field FEN matches a pin, selection plays the pinned
///      move unconditionally (it is still eval-checked and warned about, but
///      never overridden). Pins also seed extra build roots so the pinned
///      continuations are explored even when no opponent line reaches them by
///      probability alone.
///   2. **Transfer targets** — every our-turn position in the skeleton,
///      remembered by its piece placement and the move played there. When the
///      builder reaches an *unpinned* our-move node, a candidate that the
///      skeleton played at a near-identical position (≤ [transferMaxDiff]
///      differing squares) is preferred over the plain expectimax pick, as
///      long as it stays within the eval-loss window. This is the
///      "answer 2.Nf3 the way you answered 2.c4" behaviour the experiment in
///      `tools/experiments/skeleton_consistency/` found was the single
///      reliable consistency signal.
///   3. **Structure vetoes** — [StructureFeature]s the user marked "avoid".
///      A candidate whose own subtree is expected to reach a vetoed feature
///      (a pawn on a square, an early queen trade) is dropped from selection
///      unless every sibling is vetoed too. The experiment showed structure
///      preferences work as a veto, not as a vote — they cannot pick between
///      two good moves, but they reliably kill the approach the user dislikes
///      (the symmetric ...d5 lines, the queen-trade Qxd4 ...d5).
///
/// The plan is pure data + pure functions over a FEN/piece-placement — no
/// engine, no network. It is serialised into [TreeBuildConfig] as one JSON
/// blob so a paused build and a saved preset round-trip it unchanged.
library;

import 'package:dartchess/dartchess.dart';

import '../../utils/chess_utils.dart'
    show sanToUci, tryParseFen, uciToSanOrNull;
import '../../utils/fen_utils.dart' show normalizeFen;

/// A board structure the user wants to steer toward (`avoid == false`) or
/// away from (`avoid == true`). Scored on a position from *our* side.
///
/// Kept deliberately small and explicit: every feature is one the user could
/// state and verify on the board, never a learned or statistical similarity
/// (the "coherence" idea the experiment rejected).
sealed class StructureFeature {
  const StructureFeature();

  /// Signed contribution to a position's structure score for our side.
  /// Positive = matches something we like; the veto logic only looks at
  /// whether an *avoided* feature is present, but the sign lets the same
  /// list drive a future "prefer" nudge without a second type.
  double score(Position pos, Side ourSide);

  /// Whether this feature is a hard veto (avoid) rather than a soft prefer.
  bool get avoid;

  Map<String, dynamic> toJson();

  static StructureFeature? fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'pawn_on':
        final sq = json['square'];
        if (sq is! String) return null;
        return PawnOnSquare(
          square: sq,
          ours: json['ours'] as bool? ?? true,
          avoid: json['avoid'] as bool? ?? true,
        );
      case 'early_queen_trade':
        return EarlyQueenTrade(avoid: json['avoid'] as bool? ?? true);
      default:
        return null;
    }
  }
}

/// "I don't want a pawn on d5" (ours == true) — the QGD-ish symmetric
/// structures the Benko player avoids.
class PawnOnSquare extends StructureFeature {
  final String square; // algebraic, e.g. "d5"
  final bool ours;
  @override
  final bool avoid;

  const PawnOnSquare({
    required this.square,
    this.ours = true,
    this.avoid = true,
  });

  @override
  double score(Position pos, Side ourSide) {
    final sq = Square.parse(square);
    if (sq == null) return 0.0;
    final side = ours ? ourSide : ourSide.opposite;
    final piece = pos.board.pieceAt(sq);
    final present =
        piece != null && piece.role == Role.pawn && piece.color == side;
    if (!present) return 0.0;
    return avoid ? -1.0 : 1.0;
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'pawn_on',
    'square': square,
    'ours': ours,
    'avoid': avoid,
  };
}

/// "I don't want the queens traded early" — the dry Qxd4 ...d5 cxd5 Qxd5
/// lines that leave the Benko player nothing to play for.
class EarlyQueenTrade extends StructureFeature {
  @override
  final bool avoid;

  const EarlyQueenTrade({this.avoid = true});

  @override
  double score(Position pos, Side ourSide) {
    final hasOurQueen = pos.board.piecesOf(ourSide, Role.queen).isNotEmpty;
    final hasTheirQueen = pos.board
        .piecesOf(ourSide.opposite, Role.queen)
        .isNotEmpty;
    if (hasOurQueen && hasTheirQueen) return 0.0;
    // Both queens gone (or ours gone) = the trade happened.
    return avoid ? -1.0 : 1.0;
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'early_queen_trade',
    'avoid': avoid,
  };
}

/// One our-move decision recorded from the skeleton: the piece placement of
/// the position it was played in, and the move (UCI) played there.
class SkeletonNode {
  /// Canonical 4-field FEN of the position before our move.
  final String fen;

  /// Our move, in UCI.
  final String uci;

  /// Move path to this node ("d4 Nf6 c4 c5"), for the "like your line after…"
  /// label the UI shows.
  final String pathLabel;

  /// Piece placement (first FEN field) of [fen], cached for [pieceDiff].
  final String placement;

  SkeletonNode({required this.fen, required this.uci, required this.pathLabel})
    : placement = fen.split(' ').first;

  Map<String, dynamic> toJson() => {'fen': fen, 'uci': uci, 'path': pathLabel};

  static SkeletonNode? fromJson(Map<String, dynamic> json) {
    final fen = json['fen'];
    final uci = json['uci'];
    if (fen is! String || uci is! String) return null;
    return SkeletonNode(
      fen: fen,
      uci: uci,
      pathLabel: json['path'] as String? ?? '',
    );
  }
}

/// Result of a transfer lookup: the move to prefer, how far the skeleton
/// position was, and its label.
class TransferMatch {
  final String uci;
  final int diff;
  final String pathLabel;
  const TransferMatch({
    required this.uci,
    required this.diff,
    required this.pathLabel,
  });
}

class SkeletonPlan {
  /// Our-move decisions, one per our-turn ply in every skeleton line.
  final List<SkeletonNode> nodes;

  /// Structure features to steer by (currently vetoes only).
  final List<StructureFeature> features;

  /// The raw move-lines the user typed, kept verbatim so the editor can
  /// reload an exact, re-editable copy after a resume or preset load. Not read
  /// by the algorithm (which uses [nodes]); purely for round-tripping the UI.
  final List<String> sourceLines;

  /// Max differing squares for a skeleton move to "transfer" to a new
  /// position. 5 was the value the experiment validated: 4 covers a single
  /// swapped minor-piece/pawn move (2.Nf3 vs 2.c4), 5 covers one exchange;
  /// beyond that the positions are too different and it misfires.
  final int transferMaxDiff;

  const SkeletonPlan({
    this.nodes = const [],
    this.features = const [],
    this.sourceLines = const [],
    this.transferMaxDiff = 5,
  });

  bool get isEmpty => nodes.isEmpty && features.isEmpty;

  /// The vetoed features (the only kind that acts today).
  Iterable<StructureFeature> get vetoes => features.where((f) => f.avoid);

  /// Pins as a map from canonical FEN → our-move UCI, for O(1) selection
  /// lookup. Later lines win on a collision (last write), which is
  /// intentional: a user editing a line re-pins.
  Map<String, String> get pinsByFen => {for (final n in nodes) n.fen: n.uci};

  /// The skeleton move to prefer at [beforeFen] (an our-move position we did
  /// not pin), or null if none of the skeleton's moves is legal here at a
  /// piece distance within [transferMaxDiff].
  ///
  /// Ties broken by smallest distance. The returned move is a *candidate* the
  /// caller still eval-gates — transfer never overrides the eval-loss window.
  TransferMatch? transferFor(String beforeFen) {
    final placement = normalizeFen(beforeFen).split(' ').first;
    final pos = tryParseFen(beforeFen);
    if (pos == null) return null;

    TransferMatch? best;
    for (final n in nodes) {
      final diff = _placementDiff(placement, n.placement);
      if (diff > transferMaxDiff) continue;
      // The move must be legal in *this* position.
      if (uciToSanOrNull(beforeFen, n.uci) == null) continue;
      if (best == null || diff < best.diff) {
        best = TransferMatch(uci: n.uci, diff: diff, pathLabel: n.pathLabel);
      }
    }
    return best;
  }

  /// Structure score of [pos] for [ourSide]: sum over features. Negative when
  /// an avoided feature is present.
  double structureScore(Position pos, Side ourSide) {
    var s = 0.0;
    for (final f in features) {
      s += f.score(pos, ourSide);
    }
    return s;
  }

  Map<String, dynamic> toJson() => {
    'nodes': [for (final n in nodes) n.toJson()],
    'features': [for (final f in features) f.toJson()],
    if (sourceLines.isNotEmpty) 'source_lines': sourceLines,
    'transfer_max_diff': transferMaxDiff,
  };

  static SkeletonPlan fromJson(Map<String, dynamic>? json) {
    if (json == null) return const SkeletonPlan();
    final rawNodes = json['nodes'];
    final rawFeatures = json['features'];
    return SkeletonPlan(
      nodes: [
        if (rawNodes is List)
          for (final e in rawNodes)
            if (e is Map<String, dynamic>) ?SkeletonNode.fromJson(e),
      ],
      features: [
        if (rawFeatures is List)
          for (final e in rawFeatures)
            if (e is Map<String, dynamic>) ?StructureFeature.fromJson(e),
      ],
      sourceLines: [
        if (json['source_lines'] is List)
          for (final l in json['source_lines'] as List)
            if (l is String) l,
      ],
      transferMaxDiff: (json['transfer_max_diff'] as num?)?.toInt() ?? 5,
    );
  }

  /// Build a full plan (nodes + kept source lines) from typed move-lines.
  factory SkeletonPlan.fromLines(
    List<String> lines, {
    required bool playAsWhite,
    List<StructureFeature> features = const [],
  }) {
    final kept = [
      for (final l in lines)
        if (l.trim().isNotEmpty) l.trim(),
    ];
    return SkeletonPlan(
      nodes: parseLines(kept, playAsWhite: playAsWhite),
      features: features,
      sourceLines: kept,
    );
  }

  /// Parse a set of SAN move-lines (each "1.d4 Nf6 2.c4 c5 …", numbers
  /// optional) into a plan's pins. Illegal tokens end that line early rather
  /// than throwing, so a partial paste still yields the moves before the typo.
  ///
  /// [playAsWhite] decides which side's moves become pins: our-move nodes are
  /// the positions where it is our turn.
  static List<SkeletonNode> parseLines(
    List<String> lines, {
    required bool playAsWhite,
  }) {
    final out = <SkeletonNode>[];
    for (final line in lines) {
      Position pos = Chess.initial;
      final played = StringBuffer();
      var fullmove = 1;
      for (final tok in _tokenize(line)) {
        final beforeFen = pos.fen;
        final move = pos.parseSan(tok);
        if (move == null) break; // illegal here — stop this line
        final whiteToMove = pos.turn == Side.white;
        final ourTurn = whiteToMove == playAsWhite;
        final uci = sanToUci(beforeFen, tok);
        if (ourTurn && uci != null) {
          out.add(
            SkeletonNode(
              fen: normalizeFen(beforeFen),
              uci: uci,
              pathLabel: played.toString().trim(),
            ),
          );
        }
        // Append this move to the running numbered label.
        if (whiteToMove) {
          played.write('$fullmove.$tok ');
        } else {
          played.write('$tok ');
          fullmove++;
        }
        pos = pos.play(move);
      }
    }
    return out;
  }

  static Iterable<String> _tokenize(String line) sync* {
    // Drop move numbers ("1." / "12..." ) and result tokens.
    for (final raw in line.split(RegExp(r'\s+'))) {
      final tok = raw.replaceAll(RegExp(r'^\d+\.(\.\.)?'), '').trim();
      if (tok.isEmpty) continue;
      if (tok == '*' || tok == '1-0' || tok == '0-1' || tok == '1/2-1/2') {
        continue;
      }
      yield tok;
    }
  }
}

/// Number of board squares whose contents differ between two FEN placement
/// fields (first FEN field). Both are expanded to 64 cells first.
int _placementDiff(String a, String b) {
  final ea = _expandPlacement(a);
  final eb = _expandPlacement(b);
  var diff = 0;
  for (var i = 0; i < 64; i++) {
    if (ea[i] != eb[i]) diff++;
  }
  return diff;
}

/// Expand a FEN placement field into 64 chars (rank 8 → rank 1, file a → h),
/// '.' for empty. Returns a fixed 64-length string; malformed input is padded
/// or truncated so callers never index out of range.
String _expandPlacement(String placement) {
  final sb = StringBuffer();
  for (final ch in placement.split('')) {
    if (ch == '/') continue;
    final digit = int.tryParse(ch);
    if (digit != null) {
      sb.write('.' * digit);
    } else {
      sb.write(ch);
    }
  }
  var s = sb.toString();
  if (s.length < 64) s = s.padRight(64, '.');
  if (s.length > 64) s = s.substring(0, 64);
  return s;
}
