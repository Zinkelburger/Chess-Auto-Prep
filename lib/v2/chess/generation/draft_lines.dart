import 'dart:math' as math;

import '../fen.dart';
import '../pgn/game_tree.dart';
import 'eval.dart';
import 'search_node.dart';

/// The lines a finished search proposes, as the draft chapter writes them.
///
/// The search tree is the whole policy: our one move at every position and
/// every reply the model gave any weight. A draft is for a person to read and
/// accept line by line, so it is cut down: one game per line the search
/// actually answered, most reached first, near-copies of a kept line folded
/// into it as a sideline, lines the chapter already has left out, and at
/// most [DraftPlan.cap] of them. Every move carries what the search thought
/// the position after it was worth, so the values travel with the line
/// wherever it is dragged.

/// One move of a proposed line and what the position after it is worth.
final class DraftMove {
  const DraftMove({
    required this.move,
    required this.before,
    required this.after,
    required this.value,
    required this.ours,
  });

  final MoveRef move;

  /// The position the move is played from, the four fields only: what a
  /// decision is keyed by.
  final String before;

  final Fen after;

  /// The expected score of [after] for the repertoire side, in [0, 1].
  final double value;

  final bool ours;

  /// What identifies the decision this move is: where, and what.
  String get decision => '$before|${move.uci}';
}

/// One line the search answered, from the search root to its last move.
final class DraftLine {
  const DraftLine({required this.moves, required this.reach});

  final List<DraftMove> moves;

  /// How often a game from the root goes down this line: the product of the
  /// opponent's shares along it.
  final double reach;

  /// The moves of ours that this line decides.
  Set<String> get decisions => {
    for (final move in moves)
      if (move.ours) move.decision,
  };

  List<String> get ucis => [for (final move in moves) move.move.uci];
}

/// Every line [root] answers, most reached first.
///
/// A line follows our chosen move at each of our positions and, at each of
/// the opponent's, branches into every reply the search went on to answer;
/// a reply it only valued and never answered is not a line, because there is
/// nothing of ours in it to learn. A line therefore ends on our move, or on
/// a finished game.
List<DraftLine> linesOf(SearchNode root) {
  final lines = <DraftLine>[];
  void walk(SearchNode node, List<DraftMove> sofar, double reach) {
    switch (node) {
      case OurNode(:final chosen):
        walk(chosen.child, [
          ...sofar,
          _step(node.fen, chosen.move, chosen.child, ours: true),
        ], reach);
      case OpponentNode(:final replies):
        var followed = false;
        for (final reply in replies) {
          final child = reply.child;
          if (child is! OurNode && child is! TerminalNode) continue;
          followed = true;
          walk(child, [
            ...sofar,
            _step(node.fen, reply.move, child, ours: false),
          ], reach * reply.probability);
        }
        if (!followed && sofar.isNotEmpty) {
          lines.add(DraftLine(moves: List.unmodifiable(sofar), reach: reach));
        }
      case TerminalNode() || HorizonNode() || FrontierNode():
        if (sofar.isNotEmpty) {
          lines.add(DraftLine(moves: List.unmodifiable(sofar), reach: reach));
        }
    }
  }

  walk(root, const [], 1);
  lines.sort((a, b) {
    final byReach = b.reach.compareTo(a.reach);
    return byReach != 0
        ? byReach
        : a.ucis.join(' ').compareTo(b.ucis.join(' '));
  });
  return lines;
}

DraftMove _step(
  Fen from,
  MoveRef move,
  SearchNode child, {
  required bool ours,
}) => DraftMove(
  move: move,
  before: from.position,
  after: child.fen,
  value: child.valuation.value,
  ours: ours,
);

/// A line the draft keeps, with the near-copies folded into it.
final class DraftEntry {
  const DraftEntry({required this.line, this.sidelines = const []});

  final DraftLine line;

  /// Each folded line and the index of the first move where it leaves
  /// [line]; the sideline is that line's moves from there on.
  final List<(int, DraftLine)> sidelines;
}

/// What the draft holds, and what was done with the rest.
final class DraftPlan {
  const DraftPlan({
    required this.entries,
    required this.folded,
    required this.dropped,
    required this.alreadyThere,
  });

  /// The most lines a draft holds: what a person can read, and about what
  /// the old builder wrote per chapter.
  static const cap = 100;

  final List<DraftEntry> entries;

  /// Near-copies written as sidelines of the line they copy.
  final int folded;

  /// Near-copies with nothing to hang off, and lines past [cap].
  final int dropped;

  /// Lines whose every move of ours the chapter already plays.
  final int alreadyThere;

  int get lines => entries.length;
}

/// How different a line must be from the lines already kept: the old
/// builder's bar, `LineDiversity.standard`.
///
/// A line is kept when it shares no more than [maxOverlap] of its decisions
/// with any one kept line (Jaccard) and at least [minNewShare] of them are
/// decisions no kept line teaches. One that fails hangs off the kept line it
/// shares the longest prefix with, as a sideline of at most [maxFoldPlies]
/// plies; longer, or with no shared prefix, it is dropped.
const double maxOverlap = 0.7;
const double minNewShare = 0.25;
const int maxFoldPlies = 6;

/// Cuts [lines], most reached first, to what the draft writes.
///
/// [known] is every decision the chapter already makes, `position|uci` as
/// [DraftMove.decision] spells it; a line with none of its own is not
/// proposed again.
DraftPlan planDraft(List<DraftLine> lines, {Set<String> known = const {}}) {
  final entries = <_Kept>[];
  final taught = <String>{};
  var folded = 0;
  var dropped = 0;
  var alreadyThere = 0;
  for (final line in lines) {
    final decisions = line.decisions;
    if (decisions.every(known.contains)) {
      alreadyThere++;
      continue;
    }
    if (!_tooClose(decisions, entries, taught) &&
        entries.length < DraftPlan.cap) {
      entries.add(_Kept(line, decisions));
      taught.addAll(decisions);
      continue;
    }
    final host = _hostFor(entries, line);
    if (host == null) {
      dropped++;
      continue;
    }
    final (kept, divergeAt) = host;
    final tail = line.moves.length - divergeAt;
    if (tail <= 0 || tail > maxFoldPlies) {
      dropped++;
      continue;
    }
    kept.sidelines.add((divergeAt, line));
    folded++;
  }
  return DraftPlan(
    entries: List.unmodifiable([
      for (final kept in entries)
        DraftEntry(
          line: kept.line,
          sidelines: List.unmodifiable(kept.sidelines),
        ),
    ]),
    folded: folded,
    dropped: dropped,
    alreadyThere: alreadyThere,
  );
}

final class _Kept {
  _Kept(this.line, this.decisions);

  final DraftLine line;
  final Set<String> decisions;
  final sidelines = <(int, DraftLine)>[];
}

/// Whether a line with [decisions] fails the bar: too little of it is new
/// beside everything [taught], or it overlaps one [kept] line too much.
bool _tooClose(Set<String> decisions, List<_Kept> kept, Set<String> taught) {
  if (decisions.isEmpty) return false;
  final fresh = decisions.where((d) => !taught.contains(d)).length;
  return fresh / decisions.length < minNewShare ||
      kept.any((line) => _jaccard(decisions, line.decisions) > maxOverlap);
}

double _jaccard(Set<String> a, Set<String> b) {
  final union = {...a, ...b};
  if (union.isEmpty) return 0;
  return a.intersection(b).length / union.length;
}

/// The kept line [line] shares the longest prefix with, and how long that
/// prefix is; null when no kept line shares even its first move.
(_Kept, int)? _hostFor(List<_Kept> kept, DraftLine line) {
  _Kept? best;
  var longest = 0;
  final ucis = line.ucis;
  for (final candidate in kept) {
    final other = candidate.line.ucis;
    var shared = 0;
    while (shared < ucis.length &&
        shared < other.length &&
        ucis[shared] == other[shared]) {
      shared++;
    }
    if (shared > longest) {
      longest = shared;
      best = candidate;
    }
  }
  return best == null ? null : (best, longest);
}

/// [entry] as a game tree from [rootFen]: [prefix] first, uncommented, then
/// the line's moves, each carrying its tokens, with the sidelines hanging
/// off the moves they leave.
///
/// [prefix] is the chapter's own way from its root to the position the
/// search started at, so a draft line is rooted where the chapter is and
/// can be dropped into it.
GameTree draftTree(
  DraftEntry entry, {
  required Fen rootFen,
  List<MoveNode> prefix = const [],
}) {
  final root = _Branch(null);
  var at = root;
  for (final node in prefix) {
    final next = _Branch(MoveNode(san: node.san, uci: node.uci, fen: node.fen));
    at.children.add(next);
    at = next;
  }
  final start = at;
  _graft(start, entry.line.moves, first: true, reach: entry.line.reach);
  for (final (divergeAt, sideline) in entry.sidelines) {
    var host = start;
    for (var i = 0; i < divergeAt; i++) {
      host = host.children.firstWhere(
        (b) => b.node!.uci == sideline.moves[i].move.uci,
      );
    }
    _graft(
      host,
      sideline.moves.skip(divergeAt).toList(),
      first: false,
      reach: sideline.reach,
    );
  }
  return GameTree(rootFen: rootFen, children: root.build());
}

/// Adds [moves] under [at]. A move already there is followed, not added a
/// second time: two sidelines that leave the line at the same move and share
/// their start (`a b x y`, `a b x z` off `a b c`) are one `x` with `y` and
/// `z` after it, not two `x` branches. The move keeps the tokens it was
/// first written with.
void _graft(
  _Branch at,
  List<DraftMove> moves, {
  required bool first,
  required double reach,
}) {
  var here = at;
  for (final (index, move) in moves.indexed) {
    final existing = here.children
        .where((b) => b.node!.uci == move.move.uci)
        .firstOrNull;
    if (existing != null) {
      here = existing;
      continue;
    }
    final tokens = [
      if (first && index == 0)
        '[%cumProb ${(reach * 100).toStringAsFixed(1)}%]',
      '[%expectimax ${expectimaxText(move.value)}]',
      '[%score ${(move.value * 100).toStringAsFixed(1)}%]',
    ];
    final next = _Branch(
      MoveNode(
        san: move.move.san,
        uci: move.move.uci,
        fen: move.after,
        comment: tokens.join(' '),
      ),
    );
    here.children.add(next);
    here = next;
  }
}

final class _Branch {
  _Branch(this.node);

  final MoveNode? node;
  final children = <_Branch>[];

  List<MoveNode> build() => [
    for (final child in children) child.node!.copyWith(children: child.build()),
  ];
}

/// An expected score as the centipawns it stands for, in pawns with a sign:
/// `+0.42`, `-1.20`. The inverse of [expectedScore], capped short of a mate,
/// as the old app wrote `[%expectimax]`.
String expectimaxText(double value) {
  final cap = mateSaturationCp - 1;
  final int cp;
  if (value <= 0.01) {
    cp = -cap;
  } else if (value >= 0.99) {
    cp = cap;
  } else {
    cp = (-math.log(1 / value - 1) / 0.00368208).round().clamp(-cap, cap);
  }
  final pawns = (cp / 100).toStringAsFixed(2);
  return cp < 0 ? pawns : '+$pawns';
}

/// The `[%expectimax …]` value a move's comment carries, as written, or null.
String? expectimaxIn(String? comment) {
  if (comment == null) return null;
  final match = RegExp(r'\[%expectimax\s+([^\]\s]+)\]').firstMatch(comment);
  return match?.group(1);
}
