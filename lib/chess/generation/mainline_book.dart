import 'package:collection/collection.dart' show mergeSort;
import 'package:dartchess/dartchess.dart' show Position, Side;

import '../fen.dart';
import 'eval.dart';
import 'legal_moves.dart';
import 'search.dart'
    show CancelSignal, LastPly, SearchProgress, SearchSnapshot, snapshotEvery;
import 'search_node.dart';
import 'search_result.dart';
import 'terminal.dart';

/// The ChessDB mainline book: the objectively best line, not the practical
/// one.
///
/// Nothing here weighs how likely anyone is to go wrong. At each of our
/// positions the book plays the move ChessDB scores best (a tie goes to the
/// move masters played most). At the opponent's it follows the replies
/// masters actually play there — most played first, until [MainlineConfig.
/// coverage] of their games or [MainlineConfig.maxReplies] replies — while
/// the line is within [MainlineConfig.branchPlies] of the start; past that,
/// or where masters never went, the opponent too plays ChessDB's best, so
/// each line runs on as a single mainline until ChessDB knows no more or it
/// is [MainlineConfig.linePlies] long.
///
/// The result is a search tree like the expectimax search's, so the table,
/// Make lines and the saved tree read it the same way: one candidate at each
/// of our positions, the replies weighted by their share of the masters'
/// games (a lone ChessDB reply is all of it), and a position's value the
/// expected score of ChessDB's verdict. Example: after 1.e4 masters played
/// c5 in 600 games and e5 in 400 → replies at 0.6 and 0.4; each continues
/// with ChessDB's best for us.
///
/// It goes level by level, as the search does, so a stop — asked for,
/// ChessDB no longer answering ([StopReason.sourceUnavailable]) or the run
/// out of requests ([StopReason.nodeBudget]), which the result says —
/// leaves every line to the same depth and unexpanded positions a resume
/// goes on from. One position ChessDB did not answer is not an outage: it is
/// left unexpanded and the rest is built ([StopReason.unanswered]). Each position is walked
/// with its [SearchPath], so a repetition is found against the whole line
/// that led to it, as the search finds one.

/// One move a database scores, from the side to move, packed centipawns.
typedef ScoredBookMove = ({String uci, int cp});

/// One reply masters played and in how many games.
typedef PlayedMove = ({String uci, int games});

/// What ChessDB said when asked about one position.
sealed class BookAnswer {
  const BookAnswer();
}

/// Its moves there, best first; none where it knows none.
final class BookMoves extends BookAnswer {
  const BookMoves(this.moves);

  final List<ScoredBookMove> moves;
}

/// This position went unanswered — a slow or refused request — while
/// ChessDB still answers the run: the position is left to do.
final class BookMissed extends BookAnswer {
  const BookMissed();
}

/// ChessDB stopped answering the run: the build stops with what it has.
final class BookLost extends BookAnswer {
  const BookLost();
}

/// The run asked every question it was allowed: the build stops as a
/// search stops at its node budget.
final class BookSpent extends BookAnswer {
  const BookSpent();
}

final class MainlineConfig {
  const MainlineConfig({
    required this.side,
    this.branchPlies = defaultBranchPlies,
    this.linePlies = 40,
    this.maxReplies = 4,
    this.coverage = 0.8,
    this.minGames = 10,
  });

  /// How far the book branches on the opponent's choices when nobody said.
  static const defaultBranchPlies = 8;

  final Side side;

  /// The opponent's choices are followed only this many half-moves from
  /// the start.
  final int branchPlies;

  /// No line runs past this many half-moves from the start.
  final int linePlies;
  final int maxReplies;

  /// The share of the masters' games the replies followed must reach.
  final double coverage;

  /// A reply played fewer times than this is not a choice anyone recorded.
  final int minGames;
}

/// Builds the book from [root], or goes on from [seed], a book built from
/// the same position before. [movesAt] is ChessDB's [BookAnswer] at a
/// position; one it could not give either leaves that position to do or
/// stops the build, keeping what it has, and the result says which.
/// [practiceAt] is the masters' replies, most played first.
Future<SearchResult> buildMainlineBook({
  required Position root,
  required MainlineConfig config,
  required Future<BookAnswer> Function(Fen fen) movesAt,
  required Future<List<PlayedMove>> Function(Fen fen) practiceAt,
  SearchNode? seed,
  CancelSignal? isCancelled,
  LastPly? lastPly,
  void Function(SearchProgress progress)? onProgress,
  SearchSnapshot? onSnapshot,
}) async {
  final start = SearchPath.root(root);
  final top = seed == null ? _Node(start, null) : _adopt(seed, start);
  final queue = <_Node>[...top.unexpanded()];
  var shown = DateTime.now();
  var level = queue.isEmpty ? 0 : queue.first.ply;
  var nodes = top.count();
  StopReason? stopped;
  var skipped = false;
  var unanswered = false;
  while (queue.isNotEmpty) {
    final node = queue.removeAt(0);
    if (isCancelled?.call() ?? false) {
      stopped = StopReason.cancelled;
      break;
    }
    if (lastPly?.call() case final last? when node.ply >= last) {
      skipped = true;
      continue;
    }
    if (node.ply > level) {
      level = node.ply;
      onSnapshot?.call(top.tree(config.side));
      shown = DateTime.now();
    }
    final answer = await _expand(node, config, movesAt, practiceAt);
    if (answer is! BookMoves && identical(node, top)) {
      return EvaluationFailed(
        fen: Fen(root.fen),
        reason: 'ChessDB could not be reached.',
        tree: null,
      );
    }
    if (answer is BookMissed) {
      unanswered = true;
      continue;
    }
    stopped = switch (answer) {
      BookLost() => StopReason.sourceUnavailable,
      BookSpent() => StopReason.nodeBudget,
      BookMoves() || BookMissed() => null,
    };
    if (stopped != null) break;
    queue.addAll(node.children.map((child) => child.node));
    nodes += node.children.length;
    onProgress?.call((nodes: nodes, depth: node.ply + 1));
    if (DateTime.now().difference(shown) >= snapshotEvery) {
      onSnapshot?.call(top.tree(config.side));
      shown = DateTime.now();
    }
  }
  final tree = top.tree(config.side);
  if (stopped != null) return SearchIncomplete(tree: tree, reason: stopped);
  if (skipped) {
    return SearchIncomplete(tree: tree, reason: StopReason.levelDone);
  }
  if (unanswered) {
    return SearchIncomplete(tree: tree, reason: StopReason.unanswered);
  }
  return SearchComplete(tree);
}

/// Works out [node]'s moves. Anything but [BookMoves] when ChessDB could
/// not answer; the node is left unexpanded.
Future<BookAnswer> _expand(
  _Node node,
  MainlineConfig config,
  Future<BookAnswer> Function(Fen fen) movesAt,
  Future<List<PlayedMove>> Function(Fen fen) practiceAt,
) async {
  final fen = node.path.fen;
  final over = terminalKind(node.position, node.path.history);
  if (over != null) {
    node
      ..terminal = over
      ..expanded = true;
    return const BookMoves([]);
  }
  if (node.ply >= config.linePlies) {
    node.expanded = true;
    return const BookMoves([]);
  }
  final answer = await movesAt(fen);
  if (answer is! BookMoves) return answer;
  final moves = answer.moves;
  node.expanded = true;
  if (moves.isEmpty) return answer;
  final turn = node.position.turn;
  node.eval = Eval(moves.first.cp).forUs(config.side, turn);
  // A masters' reply ChessDB does not score stays unscored until its own
  // position is asked about; it is not worth what the best move is.
  Eval? evalOf(String uci) {
    final scored = moves.where((m) => m.uci == uci).firstOrNull;
    return scored == null ? null : Eval(scored.cp).forUs(config.side, turn);
  }

  final ours = turn == config.side;
  final replies = !ours && node.ply < config.branchPlies
      ? _replies(_named(node.position, await practiceAt(fen)), config)
      : const <(String, double)>[];
  final chosen = replies.isNotEmpty
      ? replies
      : [(await _best(moves, node.position, fen, practiceAt), 1.0)];
  for (final (uci, share) in chosen) {
    node.add(uci, share, evalOf(uci));
  }
  return answer;
}

/// ChessDB's best move; of several it scores the same, the one masters
/// played most, then the first it named.
Future<String> _best(
  List<ScoredBookMove> moves,
  Position position,
  Fen fen,
  Future<List<PlayedMove>> Function(Fen fen) practiceAt,
) async {
  final tied = moves.where((m) => m.cp == moves.first.cp).toList();
  if (tied.length < 2) return moves.first.uci;
  final practice = _named(position, await practiceAt(fen));
  int games(String uci) =>
      practice.where((p) => p.uci == uci).firstOrNull?.games ?? 0;
  tied.sort((a, b) => games(b.uci).compareTo(games(a.uci)));
  return tied.first.uci;
}

/// [practice] under the names ChessDB and the tree use, most played first.
/// Masters spell castling king onto rook (`e8h8`), ChessDB king to its square
/// (`e8g8`); both spellings are one move, their games added. A move not legal
/// here is dropped, so it takes no share of the replies.
List<PlayedMove> _named(Position position, List<PlayedMove> practice) {
  final legal = legalMovesOf(position);
  final games = <String, int>{};
  for (final move in practice) {
    final named = _legal(legal, move.uci);
    if (named == null) continue;
    games.update(
      named.uci,
      (sum) => sum + move.games,
      ifAbsent: () => move.games,
    );
  }
  final named = [
    for (final MapEntry(:key, :value) in games.entries)
      (uci: key, games: value),
  ];
  mergeSort(named, compare: (a, b) => b.games.compareTo(a.games));
  return named;
}

/// The legal move [uci] names, castling spelled either way.
NamedMove? _legal(List<NamedMove> legal, String uci) =>
    legal.where((m) => m.uci == uci || m.move.uci == uci).firstOrNull;

/// The masters' replies the book follows, each with its share of the ones
/// followed, most played first.
List<(String, double)> _replies(
  List<PlayedMove> practice,
  MainlineConfig config,
) {
  final total = practice.fold(0, (sum, move) => sum + move.games);
  if (total == 0) return const [];
  final taken = <PlayedMove>[];
  var covered = 0;
  for (final move in practice) {
    if (move.games < config.minGames || taken.length >= config.maxReplies) {
      break;
    }
    taken.add(move);
    covered += move.games;
    if (covered / total >= config.coverage) break;
  }
  final followed = taken.fold(0, (sum, move) => sum + move.games);
  return [for (final move in taken) (move.uci, move.games / followed)];
}

/// A position of the book while it is being built, with the way to it.
final class _Node {
  _Node(this.path, this.eval);

  final SearchPath path;
  Position get position => path.position;
  int get ply => path.ply;

  /// ChessDB's verdict from our side, once known.
  Eval? eval;
  bool expanded = false;
  TerminalKind? terminal;
  final children = <({MoveRef move, double share, _Node node})>[];

  void add(String uci, double share, Eval? eval) {
    final legal = _legal(legalMovesOf(position), uci);
    if (legal == null) return;
    final (next, san) = position.makeSan(legal.move);
    children.add((
      move: MoveRef(uci: legal.uci, san: san),
      share: share,
      node: _Node(path.next(next, share: share), eval),
    ));
  }

  Iterable<_Node> unexpanded() sync* {
    if (!expanded) {
      yield this;
      return;
    }
    for (final child in children) {
      yield* child.node.unexpanded();
    }
  }

  int count() => children.fold(1, (sum, child) => sum + child.node.count());

  SearchNode tree(Side side) {
    final fen = path.fen;
    if (!expanded) return FrontierNode(fen: fen, evalForUs: eval);
    if (terminal case final kind?) {
      return TerminalNode(
        fen: fen,
        evalForUs: eval,
        kind: kind,
        ourTurn: position.turn == side,
      );
    }
    if (children.isEmpty) return HorizonNode(fen: fen, evalForUs: eval);
    if (position.turn == side) {
      return OurNode.over(
        fen: fen,
        evalForUs: eval,
        candidates: [
          for (final child in children)
            CandidateMove(move: child.move, child: child.node.tree(side)),
        ],
      );
    }
    return OpponentNode.over(
      fen: fen,
      evalForUs: eval,
      replies: [
        for (final child in children)
          ReplyMove(
            move: child.move,
            probability: child.share,
            child: child.node.tree(side),
          ),
      ],
    );
  }
}

/// [node], a book built before from [path]'s position, as nodes to go on
/// from: what it expanded stays expanded, its frontier is what is left to
/// do.
_Node _adopt(SearchNode node, SearchPath path) {
  final built = _Node(path, node.evaluated ? node.evalForUs : null);
  void follow(MoveRef move, double share, SearchNode child) {
    final legal = _legal(legalMovesOf(path.position), move.uci);
    if (legal == null) return;
    final next = path.next(path.position.play(legal.move), share: share);
    built.children.add((move: move, share: share, node: _adopt(child, next)));
  }

  switch (node) {
    case FrontierNode():
      return built;
    case TerminalNode(:final kind):
      built.terminal = kind;
    case HorizonNode():
      break;
    case OurNode(:final candidates):
      for (final candidate in candidates) {
        follow(candidate.move, 1, candidate.child);
      }
    case OpponentNode(:final replies):
      for (final reply in replies) {
        follow(reply.move, reply.probability, reply.child);
      }
  }
  built.expanded = true;
  return built;
}
