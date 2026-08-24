/// Working out which side a repertoire PGN is *for*, from the moves alone.
///
/// Files this app writes carry a `// Color:` comment, so the question never
/// arises for them. Third-party course exports (Chessable, ChessBase, a study
/// downloaded from Lichess) carry nothing of the sort, and the old fallback
/// was to assume White. For a Black course that is silently catastrophic: the
/// trainer quizzes you on the *opponent's* moves for every line in the file,
/// and nothing on screen says so.
///
/// The signal is the shape of the move tree. A repertoire answers each
/// opponent move with exactly one move of its own, and covers many opponent
/// replies — so branching is lopsided: the side that branches is the opponent,
/// the side that does not is you. A second, independent signal is which side
/// plays the last move of each line, since a line normally ends on the move
/// you are meant to know.
library;

import 'package:dartchess/dartchess.dart';

import '../models/repertoire_line.dart';

/// What the guess was based on, so callers can explain it.
enum ColorEvidence {
  /// Lopsided branching in the move tree — the strong signal.
  branching,

  /// Which side plays each line's last move.
  lastMove,
}

/// An inferred training colour and why.
class InferredColor {
  const InferredColor({
    required this.isWhite,
    required this.evidence,
    required this.detail,
  });

  final bool isWhite;
  final ColorEvidence evidence;

  /// One phrase for the UI: "most lines end on a Black move (796 of 930)".
  final String detail;

  /// 'white' / 'black', matching [RepertoireLine.color].
  String get colorName => isWhite ? 'white' : 'black';

  @override
  String toString() => 'InferredColor($colorName, $evidence: $detail)';
}

/// Fewer lines than this and neither signal means anything — a two-line file
/// is not a repertoire whose shape can be read.
const int _minLinesForBranching = 8;
const int _minLinesForLastMove = 4;

/// The side [lines] appears to train, or null when the file does not say
/// clearly enough to act on.
///
/// Never guesses from a handful of lines, and never on a thin margin: the
/// caller's fallback ("assume White", "leave the picker where the user put
/// it") is better than a confident wrong answer.
InferredColor? inferTrainingColor(List<RepertoireLine> lines) {
  // Model games are somebody else's complete game — both sides branch freely,
  // which is exactly the noise this measures.
  final candidates = [
    for (final line in lines)
      if (!line.isModelGame && line.moves.isNotEmpty) line,
  ];
  if (candidates.length < _minLinesForLastMove) return null;

  return _fromBranching(candidates) ?? _fromLastMoves(candidates);
}

// ---------------------------------------------------------------------------
// SIGNAL 1 — who branches
// ---------------------------------------------------------------------------

class _TrieNode {
  final Map<String, _TrieNode> children = {};
}

/// Fraction of positions-with-a-continuation where each side has more than one
/// move on file. The opponent's fraction is high (you cover their options);
/// yours is near zero (you have one answer).
InferredColor? _fromBranching(List<RepertoireLine> lines) {
  if (lines.length < _minLinesForBranching) return null;

  // One trie per starting position: lines from a custom root share no prefix
  // with lines from move 1, and merging them would invent branches.
  final byStart = <String, List<RepertoireLine>>{};
  for (final line in lines) {
    byStart.putIfAbsent(line.startPosition.fen, () => []).add(line);
  }

  var whiteNodes = 0, whiteBranching = 0;
  var blackNodes = 0, blackBranching = 0;

  for (final entry in byStart.entries) {
    final group = entry.value;
    if (group.length < 2) continue;
    final startIsWhite = group.first.startPosition.turn == Side.white;

    final root = _TrieNode();
    for (final line in group) {
      var node = root;
      for (final san in line.moves) {
        node = node.children.putIfAbsent(san, _TrieNode.new);
      }
    }

    void walk(_TrieNode node, int ply) {
      if (node.children.isEmpty) return;
      // Ply 0 is played by whoever moves in the starting position.
      final whiteToMove = startIsWhite ? ply.isEven : ply.isOdd;
      if (whiteToMove) {
        whiteNodes++;
        if (node.children.length > 1) whiteBranching++;
      } else {
        blackNodes++;
        if (node.children.length > 1) blackBranching++;
      }
      for (final child in node.children.values) {
        walk(child, ply + 1);
      }
    }

    walk(root, 0);
  }

  if (whiteNodes < _minLinesForBranching ||
      blackNodes < _minLinesForBranching) {
    return null;
  }

  final whiteFraction = whiteBranching / whiteNodes;
  final blackFraction = blackBranching / blackNodes;
  final wide = whiteFraction > blackFraction ? whiteFraction : blackFraction;
  final narrow = whiteFraction > blackFraction ? blackFraction : whiteFraction;

  // The real files this was measured on separate by 12x or more; anything
  // under "twice as branchy, and actually branching somewhere" is a file
  // whose shape says nothing, so leave it to the next signal.
  if (wide < 0.02 || wide < narrow * 2) return null;

  final heroIsWhite = whiteFraction < blackFraction;
  final opponent = heroIsWhite ? 'Black' : 'White';
  return InferredColor(
    isWhite: heroIsWhite,
    evidence: ColorEvidence.branching,
    detail:
        'the file covers many $opponent replies but answers each with one '
        'move',
  );
}

// ---------------------------------------------------------------------------
// SIGNAL 2 — who plays the last move
// ---------------------------------------------------------------------------

/// A repertoire line ends on the move you are meant to play, so a strong
/// majority of last moves belonging to one side names that side.
InferredColor? _fromLastMoves(List<RepertoireLine> lines) {
  var white = 0;
  var black = 0;
  for (final line in lines) {
    final startIsWhite = line.startPosition.turn == Side.white;
    final lastPly = line.moves.length - 1;
    final lastIsWhite = startIsWhite ? lastPly.isEven : lastPly.isOdd;
    if (lastIsWhite) {
      white++;
    } else {
      black++;
    }
  }

  final total = white + black;
  if (total < _minLinesForLastMove) return null;
  final majority = white > black ? white : black;
  if (majority / total < 0.75) return null;

  final heroIsWhite = white > black;
  final side = heroIsWhite ? 'White' : 'Black';
  return InferredColor(
    isWhite: heroIsWhite,
    evidence: ColorEvidence.lastMove,
    detail: 'most lines end on a $side move ($majority of $total)',
  );
}
