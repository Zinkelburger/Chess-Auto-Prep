/// Both prepared colours backed up over one pruned bughouse tree.
library;

import 'dart:math' as math;
import 'package:dartchess/dartchess.dart' show Side;
import 'table.dart';

typedef BughousePolicy =
    Future<Map<String, double>> Function(TablePosition, BoardNumber);
typedef BughouseEvaluation = ({
  double value,
  String? best,
  int nodes,
  int? depth,
});
typedef BughouseValue =
    Future<BughouseEvaluation> Function(TablePosition, BoardNumber);

final class BughouseSearchOptions {
  const BughouseSearchOptions({
    this.plies = 2,
    this.nodes = 800,
    this.maxPositions = 10000,
  });
  final int plies;
  final int nodes;
  final int maxPositions;
  static const model = 'crazyara-os96-t1.5-hivemind-search-v2';
  String get key => '$model:$plies:$nodes';
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
    required this.white,
    required this.black,
    this.branches = const [],
    this.coverage = 1,
    this.nodes = 0,
    this.depth,
  });
  final TablePosition position;

  /// All three values are from White's perspective on the selected board.
  final double evaluation;

  /// White chooses best continuations; Black follows the human distribution.
  final double white;

  /// Black chooses best continuations; White follows the human distribution.
  final double black;
  final List<BughouseBranch> branches;
  final double coverage;
  final int nodes;
  final int? depth;
  double prepared(Side side) => side == Side.white ? white : black;
}

final class BughouseSearchStopped implements Exception {
  const BughouseSearchStopped(this.reason);
  final String reason;
}

/// The engine's best move plus the four most probable moves above 1%, deduped.
/// The best move is retained even when the policy gives it <=1% probability.
List<TableMove> bughouseCandidates(
  TablePosition p,
  BoardNumber board,
  Map<String, double> probabilities,
  String? best,
) {
  final legal = p.legalMoves(board);
  final ranked = [...legal]
    ..sort((a, b) => probabilities[b.uci]!.compareTo(probabilities[a.uci]!));
  final chosen = <String>{
    if (best != null && legal.any((m) => m.uci == best)) best,
    ...ranked
        .where((m) => probabilities[m.uci]! > .01)
        .take(4)
        .map((m) => m.uci),
  };
  return [for (final uci in chosen) legal.firstWhere((m) => m.uci == uci)];
}

final class BughouseExpectimax {
  BughouseExpectimax({
    required this.board,
    required this.policy,
    required this.evaluate,
    required this.options,
    required this.cancelled,
    this.onProgress,
  });
  final BoardNumber board;
  final BughousePolicy policy;
  final BughouseValue evaluate;
  final BughouseSearchOptions options;
  final bool Function() cancelled;
  final void Function(int positions)? onProgress;
  final _values = <String, BughouseEvaluation>{};
  final _policies = <String, Map<String, double>>{};
  final _nodes = <(String, int), BughouseNode>{};
  int get positions => _values.length;
  double minimumCoverage = 1;
  int rootCandidates = 0;

  void _check() {
    if (cancelled()) throw const BughouseSearchStopped('Stopped');
  }

  Future<BughouseEvaluation> _value(TablePosition position) async {
    _check();
    final key = position.keyText;
    if (_values[key] case final value?) return value;
    if (positions >= options.maxPositions)
      throw const BughouseSearchStopped('Position limit reached');
    double? terminal;
    for (final b in BoardNumber.values) {
      if (position.board(b).isCheckmate) {
        terminal = position.mover(b).team == Team.ab ? -1 : 1;
      }
    }
    if (terminal == null && position.legalMoves(board).isEmpty) terminal = 0;
    final answer = terminal == null
        ? await evaluate(position, board)
        : (value: terminal, best: null, nodes: 0, depth: null);
    _check();
    if (!answer.value.isFinite || answer.value.abs() > 1.00001)
      throw StateError('Invalid Hivemind value');
    // Network values are AB; the table always reads White on the selected board.
    _values[key] = (
      value: board == BoardNumber.one ? answer.value : -answer.value,
      best: answer.best,
      nodes: answer.nodes,
      depth: answer.depth,
    );
    onProgress?.call(positions);
    return _values[key]!;
  }

  Future<Map<String, double>> _policy(TablePosition position) async {
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

  bool _terminal(TablePosition p) =>
      p.legalMoves(board).isEmpty ||
      BoardNumber.values.any((b) => p.board(b).isCheckmate);

  Stream<BughouseBranch> search(TablePosition root) async* {
    if (options.plies < 1) throw ArgumentError('Invalid search depth');
    final value = await _value(root);
    if (_terminal(root)) return;
    final probabilities = await _policy(root);
    final moves = bughouseCandidates(root, board, probabilities, value.best);
    rootCandidates = moves.length;
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
    if (depth == 0 || _terminal(position)) {
      return _nodes[key] = BughouseNode(
        position: position,
        evaluation: value.value,
        white: value.value,
        black: value.value,
        nodes: value.nodes,
        depth: value.depth,
      );
    }
    final probabilities = await _policy(position);
    final moves = bughouseCandidates(
      position,
      board,
      probabilities,
      value.best,
    );
    final branches = <BughouseBranch>[];
    double mass = 0, whiteAverage = 0, blackAverage = 0;
    double bestWhite = -1, bestBlack = 1;
    for (final move in moves) {
      final chance = probabilities[move.uci]!;
      final child = await _visit(
        position.play(board, move.uci)!.after,
        depth - 1,
      );
      branches.add(BughouseBranch(move, chance, child));
      whiteAverage += chance * child.white;
      blackAverage += chance * child.black;
      bestWhite = math.max(bestWhite, child.white);
      bestBlack = math.min(bestBlack, child.black);
      mass += chance;
    }
    final coverage = mass.clamp(0.0, 1.0);
    minimumCoverage = math.min(minimumCoverage, coverage);
    // Unexpanded mass stays at the current searched value, never disappears.
    whiteAverage += (1 - coverage) * value.value;
    blackAverage += (1 - coverage) * value.value;
    final whiteTurn = position.turn(board) == Side.white;
    return _nodes[key] = BughouseNode(
      position: position,
      evaluation: value.value,
      white: whiteTurn ? bestWhite : whiteAverage,
      black: whiteTurn ? blackAverage : bestBlack,
      branches: List.unmodifiable(branches),
      coverage: coverage,
      nodes: value.nodes,
      depth: value.depth,
    );
  }
}
