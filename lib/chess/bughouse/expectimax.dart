/// A single-board expectimax tree with real cross-board capture transfers.
/// Values are calibrated Hivemind Q, from the root mover's team, not win odds.
library;

import 'dart:math' as math;

import 'table.dart';

typedef BughousePolicy =
    Future<Map<String, double>> Function(
      TablePosition position,
      BoardNumber board,
    );
typedef BughouseValue = Future<double> Function(TablePosition position);

final class BughouseSearchOptions {
  const BughouseSearchOptions({
    this.plies = 2,
    this.replyCoverage = .9,
    this.maxReplies = 24,
    this.maxPositions = 10000,
  });

  final int plies;
  final double replyCoverage;
  final int maxReplies;
  final int maxPositions;
}

final class BughouseBranch {
  const BughouseBranch(this.move, this.probability, this.child);
  final TableMove move;
  final double probability;
  final BughouseNode child;
}

final class BughouseNode {
  const BughouseNode({
    required this.position,
    required this.evaluation,
    required this.expected,
    this.branches = const [],
    this.coverage = 1,
  });

  final TablePosition position;
  final double evaluation;
  final double expected;
  final List<BughouseBranch> branches;

  /// Probability actually expanded at this chance node. Unexpanded mass
  /// retains this position's static value, rather than being renormalized away.
  final double coverage;
  double get lift => expected - evaluation;
}

final class BughouseSearchStopped implements Exception {
  const BughouseSearchStopped(this.reason);
  final String reason;
}

/// One run. Every own legal move is kept. Opponent moves are expanded in
/// probability order to the coverage/count limits, with the tail valued at
/// the current position. No partner moves, sitting or clock state are inputs.
final class BughouseExpectimax {
  BughouseExpectimax({
    required this.board,
    required this.team,
    required this.policy,
    required this.evaluate,
    required this.options,
    required this.cancelled,
    this.onProgress,
  });

  final BoardNumber board;
  final Team team;
  final BughousePolicy policy;
  final BughouseValue evaluate;
  final BughouseSearchOptions options;
  final bool Function() cancelled;
  final void Function(int positions)? onProgress;
  final _values = <String, double>{};
  final _policies = <String, Map<String, double>>{};
  final _nodes = <(String, int), BughouseNode>{};
  int get positions => _values.length;
  double minimumCoverage = 1;

  void _check() {
    if (cancelled()) throw const BughouseSearchStopped('Stopped');
  }

  Future<double> _value(TablePosition position) async {
    _check();
    final key = position.keyText;
    if (_values[key] case final value?) return value;
    if (positions >= options.maxPositions) {
      throw const BughouseSearchStopped('Position limit reached');
    }
    // Under the no-waiting model, checkmate on either board ends the game.
    for (final b in BoardNumber.values) {
      if (position.board(b).isCheckmate) {
        return _values[key] = position.mover(b).team == team ? -1 : 1;
      }
    }
    if (position.legalMoves(board).isEmpty) return _values[key] = 0;
    final value = await evaluate(position);
    _check();
    if (!value.isFinite || value.abs() > 1.00001) {
      throw StateError('Hivemind returned an invalid position value.');
    }
    _values[key] = team == Team.ab ? value : -value;
    onProgress?.call(positions);
    return _values[key]!;
  }

  Future<Map<String, double>> _policy(TablePosition position) async {
    _check();
    final key = position.board(board).fen;
    if (_policies[key] case final known?) return known;
    final answer = await policy(position, board);
    _check();
    final legal = position.legalMoves(board).map((m) => m.uci).toSet();
    final sum = answer.values.fold(0.0, (a, b) => a + b);
    if (answer.length != legal.length ||
        !answer.keys.every(legal.contains) ||
        answer.values.any((p) => !p.isFinite || p < 0) ||
        (sum - 1).abs() > 1e-6) {
      throw StateError('CrazyAra did not return a legal move distribution.');
    }
    return _policies[key] = answer;
  }

  /// A complete root row arrives as soon as its subtree has been evaluated.
  /// Cancellation keeps completed rows, never an unfinished weighted sum.
  Stream<BughouseBranch> search(TablePosition root) async* {
    if (options.plies < 1 ||
        options.maxReplies < 1 ||
        options.replyCoverage <= 0 ||
        options.replyCoverage > 1) {
      throw ArgumentError('Invalid bughouse search limits');
    }
    if (root.mover(board).team != team) {
      throw ArgumentError('The prepared team must be on move');
    }
    await _value(root);
    if (BoardNumber.values.any((b) => root.board(b).isCheckmate)) return;
    final probabilities = await _policy(root);
    final moves = root.legalMoves(board)
      ..sort((a, b) => probabilities[b.uci]!.compareTo(probabilities[a.uci]!));
    for (final move in moves) {
      final child = await _visit(
        root.play(board, move.uci)!.after,
        options.plies - 1,
      );
      yield BughouseBranch(move, probabilities[move.uci]!, child);
    }
  }

  Future<BughouseNode> _visit(TablePosition position, int depth) async {
    _check();
    final key = (position.keyText, depth);
    if (_nodes[key] case final known?) return known;
    final value = await _value(position);
    final moves = position.legalMoves(board);
    if (depth == 0 ||
        moves.isEmpty ||
        BoardNumber.values.any((b) => position.board(b).isCheckmate)) {
      return _nodes[key] = BughouseNode(
        position: position,
        evaluation: value,
        expected: value,
      );
    }
    final own = position.mover(board).team == team;
    final probabilities = own ? <String, double>{} : await _policy(position);
    if (!own) {
      moves.sort(
        (a, b) => probabilities[b.uci]!.compareTo(probabilities[a.uci]!),
      );
    }
    final branches = <BughouseBranch>[];
    double mass = 0, expected = own ? -1 : 0;
    for (final move in moves) {
      final chance = own ? 0.0 : probabilities[move.uci]!;
      final child = await _visit(
        position.play(board, move.uci)!.after,
        depth - 1,
      );
      branches.add(BughouseBranch(move, chance, child));
      expected = own
          ? math.max(expected, child.expected)
          : expected + chance * child.expected;
      mass += chance;
      if (!own &&
          (mass >= options.replyCoverage ||
              branches.length >= options.maxReplies))
        break;
    }
    final coverage = own ? 1.0 : mass.clamp(0.0, 1.0);
    minimumCoverage = math.min(minimumCoverage, coverage);
    if (!own) expected += (1 - coverage) * value;
    return _nodes[key] = BughouseNode(
      position: position,
      evaluation: value,
      expected: expected,
      branches: List.unmodifiable(branches),
      coverage: coverage,
    );
  }
}
