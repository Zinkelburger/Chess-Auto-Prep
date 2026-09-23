import 'dart:collection';

import 'package:dartchess/dartchess.dart' show Position;

import '../fen.dart';
import 'eval.dart';
import 'legal_moves.dart';
import 'search_config.dart';
import 'search_node.dart';
import 'search_result.dart';
import 'sources.dart';
import 'terminal.dart';

/// Asked before every expansion. Returning true stops the search where it is;
/// it never abandons work in flight, so an evaluation already asked for is
/// still waited for and thrown away.
typedef CancelSignal = bool Function();

/// How far a search has got, told after every expansion: the nodes the tree
/// holds and the deepest ply expanded so far.
typedef SearchProgress = ({int nodes, int depth});

/// Searches from [root] and returns the tree it found.
///
/// The recurrence, all of it, in expected score for [SearchConfig.side]:
/// a finished game is worth 1, 0.5 or 0; a position at the horizon is worth
/// the logistic [expectedScore] of the engine's fixed-depth verdict; one of
/// our positions is worth the best of the moves the loss window admitted; one
/// of the opponent's is worth the average of every reply the model gives
/// positive probability, weighted by it.
///
/// A six-node example, White to move, horizon two, loss limit 200: we play
/// the two moves the window keeps; against the first the opponent has one
/// reply that reaches +80 (worth 0.573) and against the second two replies
/// at −10 and +300, half each (0.491 and 0.751, so 0.621). The second move
/// is worth more, so the root is worth 0.621 and exports that move.
///
/// The shallowest unexpanded node always goes first, so a search that runs
/// out of budget or is cancelled comes back level by level rather than one
/// deep line: every move at the root is answered before any reply to them is,
/// and the root's provisional bounds therefore say something about the whole
/// choice instead of about the one line that happened to be explored.
///
/// Expansions are committed whole. A cancel or a budget that lands in the
/// middle of one leaves the node it was expanding untouched — a frontier
/// node with the engine's estimate and the full [0, 1] bounds — rather than
/// half its legal moves or part of a probability distribution.
Future<SearchResult> buildSearchTree({
  required Position root,
  required SearchConfig config,
  required PositionEvaluator evaluator,
  required OpponentPolicy policy,
  CancelSignal isCancelled = _neverCancelled,
  void Function(SearchProgress progress)? onProgress,
}) => _Search(
  config: config,
  evaluator: evaluator,
  policy: policy,
  isCancelled: isCancelled,
  onProgress: onProgress,
).run(root);

bool _neverCancelled() => false;

/// What one position turned out to be, before anything below it is
/// expanded: the leaf it is for now, or why the engine could not score it.
///
/// The engine answers for a whole node's children at once, so a failure is
/// carried back with its position rather than recorded where it happened;
/// whichever answer arrives first, the search reports the first move in
/// order that failed.
sealed class _Leaf {
  const _Leaf();
}

final class _Scored extends _Leaf {
  const _Scored(this.node);

  final SearchNode node;
}

final class _Unscored extends _Leaf {
  const _Unscored(this.reason);

  final String reason;
}

/// Why the search stopped, once it has.
sealed class _Stop {
  const _Stop();
}

final class _Requested extends _Stop {
  const _Requested(this.reason);

  final StopReason reason;
}

final class _PolicyFailed extends _Stop {
  const _PolicyFailed(this.fen, this.reason);

  final Fen fen;
  final String reason;
}

final class _EvaluationFailed extends _Stop {
  const _EvaluationFailed(this.fen, this.reason);

  final Fen fen;
  final String reason;
}

/// One run of [buildSearchTree]. Everything it mutates — why it stopped and
/// how much of the budget is gone — belongs to the one run and dies with it.
final class _Search {
  _Search({
    required this.config,
    required this.evaluator,
    required this.policy,
    required this.isCancelled,
    required this.onProgress,
  });

  final SearchConfig config;
  final PositionEvaluator evaluator;
  final OpponentPolicy policy;
  final CancelSignal isCancelled;
  final void Function(SearchProgress progress)? onProgress;

  _Stop? _stop;

  /// The deepest ply an expansion has reached.
  int _deepest = 0;

  /// Nodes in the tree so far, the root included, the way the old builder
  /// counts them.
  int _nodes = 1;

  Future<SearchResult> run(Position root) async {
    final path = SearchPath.root(root);
    final leaf = await _leaf(path);
    if (leaf case _Unscored(:final reason)) {
      _stop = _EvaluationFailed(path.fen, reason);
    }
    final start = leaf is _Scored ? PendingNode(path, leaf.node) : null;
    if (start != null) await _expandByDepth(start);
    // The engine failing on the root position is the one way a search ends
    // with no tree at all; every other failure still hands back what it had.
    final tree = start == null ? null : assembleTree(start);
    return switch (_stop) {
      _PolicyFailed(:final fen, :final reason) => PolicyMissing(
        fen: fen,
        reason: reason,
        tree: tree,
      ),
      _EvaluationFailed(:final fen, :final reason) => EvaluationFailed(
        fen: fen,
        reason: reason,
        tree: tree,
      ),
      _Requested(:final reason) => SearchIncomplete(
        tree: tree!,
        reason: reason,
      ),
      null => SearchComplete(tree!),
    };
  }

  /// The node for [path] before anything below it is expanded: a finished
  /// game, a horizon leaf, or a frontier node carrying the evaluation its
  /// parent's loss window is about to compare.
  ///
  /// The horizon is two things: the ply the search was asked to stop at,
  /// and the reach below which a reply is not worth preparing for
  /// ([SearchConfig.replyFloor]). A position past either is valued where it
  /// stands.
  Future<_Leaf> _leaf(SearchPath path) async {
    final kind = terminalKind(path.position, path.history);
    if (kind != null) return _Scored(_terminal(path, kind));
    final evaluation = await evaluationOf(evaluator, path.position);
    switch (evaluation) {
      case EvaluationUnavailable(:final reason):
        return _Unscored(reason);
      case Evaluated(:final eval):
        final forUs = eval.forUs(config.side, path.position.turn);
        final beyond =
            path.ply >= config.horizonPlies || path.reach < config.replyFloor;
        return _Scored(
          beyond
              ? HorizonNode(fen: path.fen, evalForUs: forUs)
              : FrontierNode(fen: path.fen, evalForUs: forUs),
        );
    }
  }

  /// The leaves for [frames], asked for together.
  ///
  /// The engine is the slow part of a build and one node's children do not
  /// depend on each other, so the whole set goes out at once. The answers are
  /// read back in move order, so a run that loses the engine on two of them
  /// reports the first of the two, every time.
  Future<List<PendingNode>?> _leavesOf(List<SearchPath> paths) async {
    final leaves = await Future.wait(paths.map(_leaf));
    final pendings = <PendingNode>[];
    for (final (index, leaf) in leaves.indexed) {
      if (leaf case _Unscored(:final reason)) {
        _stop ??= _EvaluationFailed(paths[index].fen, reason);
        return null;
      }
      pendings.add(PendingNode(paths[index], (leaf as _Scored).node));
    }
    return pendings;
  }

  /// [named] played: the name the tree will hold it under, and the path its
  /// child is searched in.
  (MoveRef, SearchPath) _play(
    SearchPath path,
    NamedMove named, {
    double share = 1,
  }) {
    final (after, san) = path.position.makeSan(named.move);
    return (MoveRef(uci: named.uci, san: san), path.next(after, share: share));
  }

  /// A finished game needs no engine, but the loss window and the tie-break
  /// still rank it against ordinary moves, so it carries the score an engine
  /// would report there: a mate for whoever gave it, zero for a draw.
  TerminalNode _terminal(SearchPath path, TerminalKind kind) {
    final ourTurn = path.position.turn == config.side;
    final mate = ourTurn ? -mateBaseCp : mateBaseCp;
    return TerminalNode(
      fen: path.fen,
      evalForUs: Eval(kind == TerminalKind.checkmate ? mate : 0),
      kind: kind,
      ourTurn: ourTurn,
    );
  }

  /// Expands the shallowest unexpanded node first, until the horizon is
  /// reached everywhere or the search stops.
  ///
  /// The queue is what makes an unfinished answer worth having: work is spent
  /// evenly across the tree, so what comes back is the whole choice seen
  /// shallowly rather than one line seen deeply.
  Future<void> _expandByDepth(PendingNode start) async {
    final queue = Queue<PendingNode>()..add(start);
    while (queue.isNotEmpty && !_stopping()) {
      final pending = queue.removeFirst();
      if (pending.leaf is! FrontierNode) continue;
      final expansion = pending.path.position.turn == config.side
          ? await _ourMoves(pending.path)
          : await _replies(pending.path);
      if (expansion == null) continue;
      pending.expansion = expansion;
      queue.addAll(expansion.children);
      if (pending.path.ply + 1 > _deepest) _deepest = pending.path.ply + 1;
      onProgress?.call((nodes: _nodes, depth: _deepest));
    }
  }

  /// Our turn: play every legal move, evaluate what it reaches, and keep the
  /// ones the window admits. Null when the search stopped part-way, so that
  /// nothing is attached and the node stays a frontier node instead of half
  /// an enumeration.
  Future<Expansion?> _ourMoves(SearchPath path) async {
    final legal = _pinnedOrAll(path, legalMovesOf(path.position));
    if (!_fits(legal.length)) return null;
    final played = [for (final named in legal) _play(path, named)];
    final pendings = await _leavesOf([for (final (_, child) in played) child]);
    if (pendings == null || _stopping()) return null;
    final admitted = admittedMoves([
      for (final (index, (move, _)) in played.indexed)
        CandidateMove(move: move, child: pendings[index].leaf),
    ], lossLimitCp: config.lossLimitCp);
    // Moves are told apart by their name, never by the identity of the
    // candidate the window handed back.
    final kept = {for (final candidate in admitted) candidate.move.uci};
    _nodes += kept.length;
    return OurMoves([
      for (final (index, (move, _)) in played.indexed)
        if (kept.contains(move.uci)) (move, pendings[index]),
    ]);
  }

  /// [legal] narrowed to the moves pinned at [path]'s position, when any of
  /// them is legal there. A pin names a move in the model's spelling or in
  /// dartchess's — castling is `e1g1` to one and `e1h1` to the other — so
  /// both are tried.
  List<NamedMove> _pinnedOrAll(SearchPath path, List<NamedMove> legal) {
    final pinned = config.pins[path.fen.position];
    if (pinned == null || pinned.isEmpty) return legal;
    final kept = [
      for (final named in legal)
        if (pinned.contains(named.uci) || pinned.contains(named.move.uci))
          named,
    ];
    return kept.isEmpty ? legal : kept;
  }

  /// The opponent's turn: take the model's whole distribution over the legal
  /// replies and keep every reply it gives positive probability. Null on the
  /// same terms as [_ourMoves], so a budget can never leave part of a
  /// probability distribution behind.
  Future<Expansion?> _replies(SearchPath path) async {
    final legal = legalMovesOf(path.position);
    final result = await policyOf(policy, path.position);
    if (_stopping()) return null;
    final shares = switch (result) {
      PolicyFound(:final policy) => policy.sharesOver(
        legal.map((named) => named.uci),
      ),
      PolicyUnavailable() => null,
    };
    if (shares == null) {
      _stop ??= _PolicyFailed(path.fen, _policyReason(result));
      return null;
    }
    final played = _repliesPlayed(path, legal, shares);
    if (!_fits(played.length)) return null;
    final pendings = await _leavesOf([
      for (final (_, _, child) in played) child,
    ]);
    if (pendings == null || _stopping()) return null;
    _nodes += pendings.length;
    return Replies([
      for (final (index, (move, share, _)) in played.indexed)
        (move, share, pendings[index]),
    ]);
  }

  /// Every reply the model gives positive probability, played, with the
  /// share it holds of the opponent's move.
  List<(MoveRef, double, SearchPath)> _repliesPlayed(
    SearchPath path,
    List<NamedMove> legal,
    Map<String, double> shares,
  ) {
    final played = <(MoveRef, double, SearchPath)>[];
    for (final named in legal) {
      final share = shares[named.uci];
      if (share == null) continue;
      final (move, child) = _play(path, named, share: share);
      played.add((move, share, child));
    }
    return played;
  }

  String _policyReason(PolicyResult result) => switch (result) {
    PolicyUnavailable(:final reason) => reason,
    PolicyFound() => 'the opponent model gave no legal move any weight',
  };

  /// True when nothing more may be expanded. Asking the caller is the only
  /// place cancellation is noticed, so every expansion passes through here.
  bool _stopping() {
    if (_stop == null && isCancelled()) {
      _stop = const _Requested(StopReason.cancelled);
    }
    return _stop != null;
  }

  /// True when [count] more nodes still fit in the budget, and otherwise
  /// stops the search.
  ///
  /// [count] is the most the expansion could attach — every legal move of
  /// one of our positions, before the loss window has seen any of them — and
  /// it is asked before the first evaluation of that expansion, so the budget
  /// is never spent on work the search then refuses to attach. The moves the
  /// window rejects are not charged, so a search can finish under budget with
  /// room the next expansion could not use.
  bool _fits(int count) {
    final budget = config.nodeBudget;
    if (budget != null && _nodes + count > budget) {
      _stop ??= const _Requested(StopReason.nodeBudget);
      return false;
    }
    return true;
  }
}

/// The moves worth preparing: every one whose fixed-depth evaluation is
/// within [lossLimitCp] centipawns of our best move's.
///
/// The search enumerates *every* legal move at one of our positions,
/// promotions to all four pieces included, evaluates each of them at the same
/// fixed depth, and then throws away only the ones this window rejects.
/// Nothing else narrows our side of the tree: not how often a move is played,
/// not how many lines it would cost, not what the engine ranked it.
///
/// Example: with a 200 centipawn limit, moves scoring +30, −150 and −400 from
/// our side give a best of +30, so +30 and −150 are kept — they lose at most
/// 180 — and −400 is not. The window is plain centipawns, so a forced mate
/// (±10000) admits only the other mates.
///
/// [candidates] must not be empty; a position with no legal move is a
/// terminal, not an empty choice.
List<CandidateMove> admittedMoves(
  List<CandidateMove> candidates, {
  required int lossLimitCp,
}) {
  final best = candidates
      .map((candidate) => candidate.evalForUs.cp)
      .reduce((a, b) => a > b ? a : b);
  return [
    for (final candidate in candidates)
      if (candidate.evalForUs.cp >= best - lossLimitCp) candidate,
  ];
}

/// A node while the search is still working: the leaf it is for now, and
/// what it turned into once it was expanded.
///
/// This is the one thing in the search that changes after it is made. The
/// queue has to hand out places in the tree before their subtrees exist, and
/// the tree it hands to the caller is built from these at the end, so nothing
/// mutable ever leaves the run.
final class PendingNode {
  PendingNode(this.path, this.leaf);

  final SearchPath path;
  final SearchNode leaf;

  Expansion? expansion;
}

/// What one expanded node turned into: the moves we may play, or the replies
/// the opponent may answer with.
sealed class Expansion {
  const Expansion();

  Iterable<PendingNode> get children;
}

final class OurMoves extends Expansion {
  const OurMoves(this.admitted);

  final List<(MoveRef, PendingNode)> admitted;

  @override
  Iterable<PendingNode> get children => admitted.map((entry) => entry.$2);
}

final class Replies extends Expansion {
  const Replies(this.replies);

  final List<(MoveRef, double, PendingNode)> replies;

  @override
  Iterable<PendingNode> get children => replies.map((entry) => entry.$3);
}

/// Builds the immutable tree out of the finished scaffolding, bottom up. A
/// node nothing was expanded into stays the leaf it already was.
SearchNode assembleTree(PendingNode pending) => switch (pending.expansion) {
  null => pending.leaf,
  OurMoves(:final admitted) => OurNode.over(
    fen: pending.leaf.fen,
    evalForUs: pending.leaf.evalForUs,
    candidates: [
      for (final (move, child) in admitted)
        CandidateMove(move: move, child: assembleTree(child)),
    ],
  ),
  Replies(:final replies) => OpponentNode.over(
    fen: pending.leaf.fen,
    evalForUs: pending.leaf.evalForUs,
    replies: [
      for (final (move, probability, child) in replies)
        ReplyMove(
          move: move,
          probability: probability,
          child: assembleTree(child),
        ),
    ],
  ),
};
