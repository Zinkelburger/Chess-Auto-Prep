import 'package:dartchess/dartchess.dart' show Side;

import '../fen.dart';
import '../generation/draft_chapter.dart' show standardCastling;
import '../generation/eval.dart';
import '../pgn/game_tree.dart';

/// What the chapter audit checks and how it judges what it is told.
///
/// The audit walks a chapter's own moves and asks two questions the gaps do
/// not: does one of *our* moves lose against the engine's best (a weak
/// move), and does the opponent have a *good* reply here that the
/// repertoire never answers and the Replies tab does not list (a strong
/// reply)? The Replies tab owns every reply the gap walk reaches often
/// enough — answered, or listed as a gap — so the audit takes only what is
/// left: a reply too rare for the walk that the engine rates highly. The
/// caller hands over what the walk found ([strongReplies] says how), so the
/// two tabs split the replies by construction and never both name one.
///
/// Scores are packed centipawns from the side to move at the position
/// judged, as `fixedDepthLines` reports them; a loss is how much worse a
/// move is than the best one, so it is never negative. Example: best `Bb5`
/// +40, the chapter's `Nc3` −70 → the chapter's move loses 110, a mistake.
/// A mate is not a number of centipawns: missing one, or walking into one,
/// is a mistake of its own kind and is never shown as a loss in pawns.

/// A loss of this many centipawns or more is a mistake (the old app's
/// default).
const mistakeCp = 100;

/// A loss of this many or more, and less than [mistakeCp], is an
/// inaccuracy.
const inaccuracyCp = 40;

/// A reply within this many centipawns of the opponent's best is strong.
const strongReplyCp = 50;

/// How many half-moves from the chapter's start the audit looks.
const auditPlies = 30;

/// How many engine lines each position is asked for.
const auditLines = 3;

/// One position of the chapter the audit asks about: one where it plays a
/// move, ours or theirs, found by the shortest way there — or, for moves of
/// ours first played at a later occurrence, where those are played.
final class AuditPosition {
  const AuditPosition({
    required this.fen,
    required this.path,
    required this.sans,
    required this.moves,
    required this.ours,
  });

  final Fen fen;

  /// Where it is met in the tree: first, breadth first, or where [moves]
  /// are played.
  final NodePath path;

  /// The moves from the chapter's start to here.
  final List<String> sans;

  /// The moves the chapter plays here that no earlier occurrence plays.
  final List<MoveNode> moves;

  /// Whether the repertoire side is to move.
  final bool ours;
}

/// The positions of [tree] to audit for [side], breadth first. A position
/// reached again by another order of moves is the same position, asked
/// about where it is met first; a move of ours first played at a later
/// occurrence is judged there, where it is played, and every occurrence is
/// walked past. No move is judged twice. A position where the chapter stops
/// has nothing of its own to check.
List<AuditPosition> auditPositions(
  GameTree tree,
  Side side, {
  int maxPlies = auditPlies,
}) {
  final positions = <AuditPosition>[];
  // The moves already taken at each position, by [Fen.position].
  final played = <String, Set<String>>{};
  final queue = <(Fen, NodePath, List<String>, List<MoveNode>)>[
    (tree.rootFen, const NodePath.root(), const [], tree.children),
  ];
  for (var i = 0; i < queue.length; i++) {
    final (fen, path, sans, children) = queue[i];
    if (children.isEmpty || sans.length >= maxPlies) continue;
    final first = !played.containsKey(fen.position);
    final taken = played.putIfAbsent(fen.position, () => {});
    final fresh = [
      for (final move in children)
        if (taken.add(standardCastling(move.uci, fen) ?? move.uci)) move,
    ];
    final ours = fen.whiteToMove == (side == Side.white);
    // Their replies are judged once, where the position is met first.
    if (first || ours && fresh.isNotEmpty) {
      positions.add(
        AuditPosition(
          fen: fen,
          path: path,
          sans: sans,
          moves: fresh,
          ours: ours,
        ),
      );
    }
    for (final (index, child) in children.indexed) {
      queue.add((
        child.fen,
        path.child(index),
        [...sans, child.san],
        child.children,
      ));
    }
  }
  return positions;
}

/// One engine line's first move and score, from the side to move.
typedef ScoredMove = ({String uci, int cp});

sealed class AuditFinding {
  const AuditFinding({
    required this.fen,
    required this.sans,
    required this.san,
    required this.uci,
    required this.reach,
  });

  /// The position the move is played from, and the way there.
  final Fen fen;
  final List<String> sans;

  /// The move the finding is about.
  final String san;
  final String uci;

  /// How often a game from the chapter's start gets here, as the gap walk
  /// worked it out; null when the walk did not get here — rarer than the
  /// floor, or past a position the model could not answer.
  final double? reach;

  /// What identifies the finding across runs and chapters, for dismissing
  /// it: what kind, where, which move.
  String get key;
}

/// One of the chapter's own moves, scored [played], is worse than the
/// engine's [bestSan], scored [best]; both from our side.
final class WeakMove extends AuditFinding {
  const WeakMove({
    required super.fen,
    required super.sans,
    required super.san,
    required super.uci,
    required super.reach,
    required this.best,
    required this.played,
    required this.bestSan,
  });

  final Eval best;
  final Eval played;
  final String bestSan;

  /// The best move mates and this one does not.
  bool get missesMate => best.mating && !played.mating;

  /// This move lets the opponent mate and the best one does not.
  bool get allowsMate => played.mated && !best.mated;

  /// How many centipawns the move gives away; null when a mate is what it
  /// misses or allows.
  int? get lossCp => missesMate || allowsMate ? null : best.cp - played.cp;

  bool get mistake => (lossCp ?? mistakeCp) >= mistakeCp;

  @override
  String get key => 'weak|${fen.position}|$uci';
}

/// The opponent's [san], scored [score], is as good as their best reply,
/// scored [best] (both from their side), the repertoire does not answer
/// it, and the model gives it only [share].
final class StrongReply extends AuditFinding {
  const StrongReply({
    required super.fen,
    required super.sans,
    required super.san,
    required super.uci,
    required super.reach,
    required this.best,
    required this.score,
    required this.share,
    required this.fromChessDb,
  });

  final Eval best;
  final Eval score;

  /// The reply mates, as their best does.
  bool get mates => score.mating;

  /// How far below their best it is; null when it mates.
  int? get behindCp => mates ? null : best.cp - score.cp;

  /// The model's share of the reply; null when it could not say.
  final double? share;

  /// Whether ChessDB named it rather than the engine.
  final bool fromChessDb;

  @override
  String get key => 'reply|${fen.position}|$uci';
}

/// The chapter's moves at [position], ours, that are weak against the best
/// of [lines]: a loss of at least [inaccuracyCp], a missed mate or a mate
/// walked into. [scoreAfter] is the score of a chapter move the lines do
/// not name, from the side that played it; a move nothing could score is
/// not judged. Where every move is mated, none is weak.
List<WeakMove> weakMoves(
  AuditPosition position, {
  required List<ScoredMove> lines,
  required Map<String, int> scoreAfter,
  required double? reach,
  required String Function(String uci) sanOf,
}) {
  if (lines.isEmpty) return const [];
  final best = lines.first;
  final found = <WeakMove>[];
  for (final move in position.moves) {
    final uci = standardCastling(move.uci, position.fen) ?? move.uci;
    final named = lines.where((line) => line.uci == uci).firstOrNull;
    final score = named?.cp ?? scoreAfter[uci];
    if (score == null) continue;
    final weak = WeakMove(
      fen: position.fen,
      sans: position.sans,
      san: move.san,
      uci: uci,
      reach: reach,
      best: Eval(best.cp),
      played: Eval(score),
      bestSan: sanOf(best.uci),
    );
    if (_isWeak(weak)) found.add(weak);
  }
  return found;
}

bool _isWeak(WeakMove move) {
  if (move.missesMate || move.allowsMate) return true;
  if (move.best.mating || move.best.mated || move.played.mating) return false;
  return move.lossCp! >= inaccuracyCp;
}

/// The strong replies at [position], theirs: as good as the best of
/// [lines] (within [strongReplyCp], or another mate where the best mates),
/// not played by the chapter, not a way into a position the repertoire
/// answers ([answered], by [Fen.position]; [leadsInto] says where a move
/// goes), and not one of [gaps] — the replies the gap walk already lists
/// here, which are the Replies tab's. [shares] is the model's, shown with
/// the finding; null when it could not say.
List<StrongReply> strongReplies(
  AuditPosition position, {
  required List<ScoredMove> lines,
  required Map<String, double>? shares,
  required Set<String> answered,
  required Set<String> gaps,
  required Fen? Function(String uci) leadsInto,
  required String Function(String uci) sanOf,
  required double? reach,
  required bool fromChessDb,
}) {
  if (lines.isEmpty) return const [];
  final best = Eval(lines.first.cp);
  final played = {
    for (final move in position.moves)
      standardCastling(move.uci, position.fen) ?? move.uci,
  };
  final found = <StrongReply>[];
  for (final line in lines) {
    final score = Eval(line.cp);
    if (!_asGood(score, best)) continue;
    if (played.contains(line.uci) || gaps.contains(line.uci)) continue;
    final after = leadsInto(line.uci);
    if (after == null || answered.contains(after.position)) continue;
    found.add(
      StrongReply(
        fen: position.fen,
        sans: position.sans,
        san: sanOf(line.uci),
        uci: line.uci,
        reach: reach,
        best: best,
        score: score,
        share: shares?[line.uci],
        fromChessDb: fromChessDb,
      ),
    );
  }
  return found;
}

/// Whether a reply scored [score] is as good as the best, [best]: another
/// mate where the best mates; nothing where every reply is mated; within
/// [strongReplyCp] otherwise.
bool _asGood(Eval score, Eval best) {
  if (best.mating) return score.mating;
  if (best.mated || score.mated) return false;
  return best.cp - score.cp <= strongReplyCp;
}

/// Mistakes first, then strong replies, then inaccuracies; within each the
/// most reached first (one the walk did not reach after every one it did),
/// then the earliest; ties by where and what, so a rerun lists them in the
/// same order.
int byReach(AuditFinding a, AuditFinding b) {
  final kind = _rank(a).compareTo(_rank(b));
  if (kind != 0) return kind;
  final reach = (b.reach ?? -1).compareTo(a.reach ?? -1);
  if (reach != 0) return reach;
  final ply = a.sans.length.compareTo(b.sans.length);
  return ply != 0 ? ply : a.key.compareTo(b.key);
}

int _rank(AuditFinding finding) => switch (finding) {
  WeakMove(mistake: true) => 0,
  StrongReply() => 1,
  WeakMove() => 2,
};
