import 'package:dartchess/dartchess.dart' show Position;

import '../fen.dart';
import 'eval.dart';
import 'legal_moves.dart';
import 'move_admission.dart';
import 'search_config.dart';
import 'search_node.dart';
import 'search_result.dart';
import 'sources.dart';
import 'terminal.dart';

/// Asked before every expansion. Returning true stops the search where it is;
/// it never abandons work in flight, so an evaluation already asked for is
/// still waited for and thrown away.
typedef CancelSignal = bool Function();

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
/// at −10 and +300, half each (0.491 and 0.749, so 0.620). The second move
/// is worth more, so the root is worth 0.620 and exports that move.
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
}) => _Search(
  config: config,
  evaluator: evaluator,
  policy: policy,
  isCancelled: isCancelled,
).run(root);

bool _neverCancelled() => false;

/// A position being worked on, with the part of its path the rules need.
///
/// The path is the point: the same placement reached two ways is two frames,
/// because a draw claim depends on what came before it.
final class _Frame {
  _Frame({
    required this.position,
    required this.fen,
    required this.history,
    required this.ply,
  });

  factory _Frame.root(Position position) {
    final fen = Fen(position.fen);
    return _Frame(
      position: position,
      fen: fen,
      history: [repetitionKey(fen)],
      ply: 0,
    );
  }

  final Position position;
  final Fen fen;

  /// [repetitionKey] for every position from the search root to this one,
  /// this one last.
  final List<String> history;

  /// Half-moves from the search root.
  final int ply;

  _Frame next(Position after) {
    final fen = Fen(after.fen);
    return _Frame(
      position: after,
      fen: fen,
      history: [...history, repetitionKey(fen)],
      ply: ply + 1,
    );
  }
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
  });

  final SearchConfig config;
  final PositionEvaluator evaluator;
  final OpponentPolicy policy;
  final CancelSignal isCancelled;

  _Stop? _stop;
  int _attached = 0;

  Future<SearchResult> run(Position root) async {
    final frame = _Frame.root(root);
    final leaf = await _leaf(frame);
    // The engine failing on the root position is the one way a search ends
    // with no tree at all, and it is reported below as a failure, not a tree.
    final tree = leaf == null ? null : await _grow(frame, leaf);
    return switch (_stop) {
      _PolicyFailed(:final fen, :final reason) => PolicyMissing(
        fen: fen,
        reason: reason,
      ),
      _EvaluationFailed(:final fen, :final reason) => EvaluationFailed(
        fen: fen,
        reason: reason,
      ),
      _Requested(:final reason) => SearchIncomplete(
        tree: tree!,
        reason: reason,
      ),
      null => SearchComplete(tree!),
    };
  }

  /// The node for [frame] before anything below it is expanded: a finished
  /// game, a horizon leaf, or a frontier node carrying the evaluation its
  /// parent's loss window is about to compare. Null when the engine failed.
  Future<SearchNode?> _leaf(_Frame frame) async {
    final kind = terminalKind(frame.position, frame.history);
    if (kind != null) return _terminal(frame, kind);
    final evaluation = await evaluator.evaluate(frame.position);
    switch (evaluation) {
      case EvaluationUnavailable(:final reason):
        _stop ??= _EvaluationFailed(frame.fen, reason);
        return null;
      case Evaluated(:final eval):
        final forUs = eval.forUs(config.side, frame.position.turn);
        return frame.ply >= config.horizonPlies
            ? HorizonNode(fen: frame.fen, evalForUs: forUs)
            : FrontierNode(fen: frame.fen, evalForUs: forUs);
    }
  }

  /// A finished game needs no engine, but the loss window and the tie-break
  /// still rank it against ordinary moves, so it carries the score an engine
  /// would report there: a mate for whoever gave it, zero for a draw.
  TerminalNode _terminal(_Frame frame, TerminalKind kind) {
    final ourTurn = frame.position.turn == config.side;
    final mate = ourTurn ? -mateBaseCp : mateBaseCp;
    return TerminalNode(
      fen: frame.fen,
      evalForUs: Eval(kind == TerminalKind.checkmate ? mate : 0),
      kind: kind,
      ourTurn: ourTurn,
    );
  }

  /// Replaces [leaf] with its expansion, or returns it unchanged when there
  /// is nothing to expand or the search is stopping.
  Future<SearchNode> _grow(_Frame frame, SearchNode leaf) async {
    if (leaf is! FrontierNode || _stopping()) return leaf;
    return frame.position.turn == config.side
        ? _expandOurs(frame, leaf)
        : _expandOpponent(frame, leaf);
  }

  /// Our turn: play every legal move, evaluate what it reaches, keep the ones
  /// the window admits, and search those.
  Future<SearchNode> _expandOurs(_Frame frame, FrontierNode leaf) async {
    final frames = <CandidateMove, _Frame>{};
    for (final named in legalMovesOf(frame.position)) {
      if (_stopping()) return leaf;
      final (after, san) = frame.position.makeSan(named.move);
      final child = frame.next(after);
      final node = await _leaf(child);
      if (node == null) return leaf;
      final move = MoveRef(uci: named.uci, san: san);
      frames[CandidateMove(move: move, child: node)] = child;
    }
    final admitted = admittedMoves(
      frames.keys.toList(),
      lossLimitCp: config.lossLimitCp,
    );
    if (!_reserve(admitted.length)) return leaf;
    final candidates = <CandidateMove>[];
    for (final candidate in admitted) {
      final grown = await _grow(frames[candidate]!, candidate.child);
      candidates.add(CandidateMove(move: candidate.move, child: grown));
    }
    return OurNode.over(
      fen: frame.fen,
      evalForUs: leaf.evalForUs,
      candidates: candidates,
    );
  }

  /// The opponent's turn: take the model's whole distribution over the legal
  /// replies, then search every reply it gives positive probability.
  Future<SearchNode> _expandOpponent(_Frame frame, FrontierNode leaf) async {
    final legal = legalMovesOf(frame.position);
    final result = await policy.policyFor(frame.position);
    if (_stopping()) return leaf;
    final shares = switch (result) {
      PolicyFound(:final policy) => policy.sharesOver(
        legal.map((named) => named.uci),
      ),
      PolicyUnavailable() => null,
    };
    if (shares == null) {
      _stop ??= _PolicyFailed(frame.fen, _policyReason(result));
      return leaf;
    }
    final leaves = await _replyLeaves(frame, legal, shares);
    if (leaves == null || !_reserve(leaves.length)) return leaf;
    final replies = <ReplyMove>[];
    for (final (reply, child) in leaves) {
      final grown = await _grow(child, reply.child);
      replies.add(
        ReplyMove(
          move: reply.move,
          probability: reply.probability,
          child: grown,
        ),
      );
    }
    return OpponentNode.over(
      fen: frame.fen,
      evalForUs: leaf.evalForUs,
      replies: replies,
    );
  }

  /// Every reply with positive probability, played and evaluated but not yet
  /// searched, with the frame each one will be searched in. Null when the
  /// search stopped part-way, so that nothing is attached and the caller
  /// keeps a frontier node instead of half a distribution.
  Future<List<(ReplyMove, _Frame)>?> _replyLeaves(
    _Frame frame,
    List<NamedMove> legal,
    Map<String, double> shares,
  ) async {
    final replies = <(ReplyMove, _Frame)>[];
    for (final named in legal) {
      final share = shares[named.uci];
      if (share == null) continue;
      if (_stopping()) return null;
      final (after, san) = frame.position.makeSan(named.move);
      final child = frame.next(after);
      final node = await _leaf(child);
      if (node == null) return null;
      final move = MoveRef(uci: named.uci, san: san);
      replies.add((
        ReplyMove(move: move, probability: share, child: node),
        child,
      ));
    }
    return replies;
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

  /// Takes [count] nodes out of the budget, or refuses and stops the search.
  /// Refusing before an expansion begins is what keeps expansions whole.
  bool _reserve(int count) {
    final budget = config.nodeBudget;
    if (budget != null && _attached + count > budget) {
      _stop ??= const _Requested(StopReason.nodeBudget);
      return false;
    }
    _attached += count;
    return true;
  }
}
