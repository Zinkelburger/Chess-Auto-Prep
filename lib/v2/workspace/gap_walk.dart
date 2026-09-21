import 'package:dartchess/dartchess.dart' show Move, NormalMove, Side;

import '../chess/fen.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/tree_edit.dart';

/// How likely the opponent is to play each legal move at [fen], as standard
/// UCI to a share summing to one, or null when the model cannot say.
typedef ReplyShares = Future<Map<String, double>?> Function(Fen fen);

/// A position the repertoire reaches often enough to need an answer and has
/// none for.
///
/// [reach] is how often a game that starts at the chapter's root gets here:
/// the product of the opponent's shares along the way, our own moves
/// counting as certain because we choose them. A chapter is "covered" to the
/// extent that its reach does not end in gaps.
sealed class Gap {
  const Gap({required this.at, required this.reach});

  /// The last position the chapter holds on the way to the gap.
  final NodePath at;

  final double reach;
}

/// The opponent plays [uci] at [at] often enough, and the chapter has no
/// line for it.
final class MissingReply extends Gap {
  const MissingReply({
    required super.at,
    required super.reach,
    required this.uci,
    required this.san,
  });

  /// Standard UCI, as the model names moves.
  final String uci;

  final String san;
}

/// It is our move at [at], often enough, and the chapter stops there.
final class DeadEnd extends Gap {
  const DeadEnd({required super.at, required super.reach});
}

/// What a walk over a chapter found.
final class GapWalk {
  const GapWalk({
    required this.gaps,
    required this.reach,
    required this.positionsAsked,
    required this.positionsUnanswered,
  });

  /// Most reached first.
  final List<Gap> gaps;

  /// How often each position the walk went through is reached, by its place
  /// in the tree. A position below the floor is not here.
  final Map<NodePath, double> reach;

  /// How many positions the model was asked about.
  final int positionsAsked;

  /// How many of those it could not answer; their replies are not gaps,
  /// they are unknown.
  final int positionsUnanswered;

  /// The share of games above the floor that reach a gap, taken off one.
  ///
  /// Our own alternatives at one position each carry the full reach, since
  /// we might play any of them, so a chapter with many sidelines and many
  /// gaps can sum past one; the floor of zero is the honest reading then.
  double get covered {
    final missing = gaps.fold(0.0, (sum, gap) => sum + gap.reach);
    return (1 - missing).clamp(0.0, 1.0);
  }
}

/// Walks [tree] as [side]'s repertoire and lists the gaps above [floor].
///
/// At our move every continuation is followed with the reach it arrived
/// with; a position with none is a [DeadEnd]. At the opponent's move each
/// reply the model gives is followed with its share of the reach, and a
/// reply the tree lacks is a [MissingReply]. Nothing below [floor] is
/// followed, so a book of a thousand lines costs one model answer per
/// opponent position the user could plausibly meet, not one per node.
///
/// [overtaken] is asked after every model answer; once it says so the walk
/// stops and answers null, so a chapter edited mid-walk never gets a report
/// about the version before.
Future<GapWalk?> walkGaps({
  required GameTree tree,
  required Side side,
  required double floor,
  required ReplyShares shares,
  required bool Function() overtaken,
}) async {
  final walk = _Walk(tree, side, floor, shares, overtaken);
  if (!await walk.visit(const NodePath.root(), 1.0)) return null;
  walk.gaps.sort((a, b) => b.reach.compareTo(a.reach));
  return GapWalk(
    gaps: List.unmodifiable(walk.gaps),
    reach: Map.unmodifiable(walk.reach),
    positionsAsked: walk.asked,
    positionsUnanswered: walk.unanswered,
  );
}

final class _Walk {
  _Walk(this.tree, this.side, this.floor, this.shares, this.overtaken);

  final GameTree tree;
  final Side side;
  final double floor;
  final ReplyShares shares;
  final bool Function() overtaken;

  final gaps = <Gap>[];
  final reach = <NodePath, double>{};
  var asked = 0;
  var unanswered = 0;

  /// False once overtaken.
  Future<bool> visit(NodePath path, double reached) async {
    if (reached < floor) return true;
    reach[path] = reached;
    final fen = tree.fenAt(path);
    final children = tree.nodeAt(path)?.children ?? tree.children;
    if (fen.whiteToMove == (side == Side.white)) {
      return _ours(path, reached, children);
    }
    return _theirs(path, reached, fen, children);
  }

  Future<bool> _ours(NodePath path, double reached, List<MoveNode> kids) async {
    if (kids.isEmpty) {
      gaps.add(DeadEnd(at: path, reach: reached));
      return true;
    }
    for (var i = 0; i < kids.length; i++) {
      if (!await visit(path.child(i), reached)) return false;
    }
    return true;
  }

  Future<bool> _theirs(
    NodePath path,
    double reached,
    Fen fen,
    List<MoveNode> kids,
  ) async {
    asked++;
    final answer = await shares(fen);
    if (overtaken()) return false;
    if (answer == null) {
      unanswered++;
      return true;
    }
    for (final MapEntry(key: uci, value: share) in answer.entries) {
      final onward = reached * share;
      if (onward < floor) continue;
      final index = indexOfReply(fen, kids, uci);
      if (index < 0) {
        gaps.add(_missing(fen, path, uci, onward));
      } else if (!await visit(path.child(index), onward)) {
        return false;
      }
    }
    return true;
  }

  Gap _missing(Fen fen, NodePath at, String uci, double reached) {
    final move = Move.parse(uci);
    final node = move == null ? null : moveNode(fen, move);
    return MissingReply(
      at: at,
      reach: reached,
      uci: uci,
      san: node?.san ?? uci,
    );
  }
}

/// Which of [siblings] plays the model's move [uci] from [fen], or −1.
///
/// The model names castling king to destination (`e1g1`); the tree, through
/// dartchess, names it king to rook (`e1h1`). The position knows which is
/// which, so the model's spelling is normalised before the two are compared.
int indexOfReply(Fen fen, List<MoveNode> siblings, String uci) {
  final move = Move.parse(uci);
  final position = positionOf(fen);
  if (move == null || position == null) return -1;
  final spelled = move is NormalMove ? position.normalizeMove(move).uci : uci;
  return siblings.indexWhere((node) => node.uci == spelled || node.uci == uci);
}
