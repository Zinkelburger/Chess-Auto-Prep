/// Breadth-first walk over a repertoire tree, shared by the defensive audit
/// and the adversarial hole hunt.
///
/// Both sweep every position below a start node down to a ply limit, yield to
/// a [RunControl] checkpoint before each one, report progress every few
/// positions and carry a reach probability down the tree. They differ only in
/// what they do at a position and in *whose* branching attenuates reach — the
/// audit charges the opponent's alternatives, the hunt the repertoire owner's
/// — so that is the one parameter the walk takes.
library;

import 'package:chess_auto_prep/chess_core/moves/opening_graph.dart';
import 'dart:collection';

import '../../../services/run_control.dart';
import '../../../utils/fen_utils.dart';

/// One position of a [RepertoireWalk].
class RepertoireWalkEntry {
  const RepertoireWalkEntry({
    required this.node,
    required this.movePath,
    required this.ply,
    required this.cumulativeProbability,
  });

  final OpeningNodeView node;

  /// SAN moves from the tree root to [node].
  final List<String> movePath;

  /// Plies below the walk's start node.
  final int ply;

  /// Probability of reaching this position from the start node (0..1): the
  /// product of the attenuating side's move shares along the path.
  final double cumulativeProbability;

  String get fen => node.fen;

  bool get isLeaf => node.children.isEmpty;

  bool get whiteToMove => isWhiteToMove(node.fen);

  /// Entries for the children of [node].
  ///
  /// When [attenuate] is set each child inherits this entry's probability
  /// scaled by its share of the games played here; otherwise the children
  /// inherit it unchanged, because the side to move is assumed to steer.
  List<RepertoireWalkEntry> children({required bool attenuate}) {
    final parentTotal = node.children.values.fold<int>(
      0,
      (sum, child) => sum + child.gamesPlayed,
    );
    return [
      for (final MapEntry(key: san, value: child) in node.children.entries)
        RepertoireWalkEntry(
          node: child,
          movePath: [...movePath, san],
          ply: ply + 1,
          cumulativeProbability: attenuate && parentTotal > 0
              ? cumulativeProbability * child.gamesPlayed / parentTotal
              : cumulativeProbability,
        ),
    ];
  }
}

/// Breadth-first traversal of the subtree under a start node.
///
/// The walk visits a node at [maxPly] but not its children, which is exactly
/// what [totalNodes] counts, so a progress bar driven by [visited] over
/// [totalNodes] ends at 100%.
class RepertoireWalk {
  RepertoireWalk({
    required OpeningNodeView start,
    required this.maxPly,
    required this.attenuatingSideIsWhite,
    required this._control,
  }) : _start = start,
       totalNodes = start.countDescendants(maxPly: maxPly);

  /// Progress is reported after every this many positions, and at the last.
  static const int progressInterval = 5;

  final OpeningNodeView _start;
  final RunControl _control;
  final int maxPly;

  /// The side whose alternatives attenuate reach probability. Where the
  /// other side is to move every child keeps the parent's probability.
  final bool attenuatingSideIsWhite;

  /// Positions the walk will visit.
  final int totalNodes;

  /// Positions visited so far, including the one being visited.
  int get visited => _visited;
  int _visited = 0;

  /// Visit every position breadth-first.
  ///
  /// [visit] runs once per position, before its children are queued.
  /// [onProgress] fires every [progressInterval] positions and on the last,
  /// just before that position's [visit]. Returns early, leaving the rest of
  /// the tree unvisited, once the [RunControl] is cancelled.
  Future<void> run({
    required Future<void> Function(RepertoireWalkEntry entry) visit,
    void Function(RepertoireWalkEntry entry)? onProgress,
  }) async {
    final queue = Queue<RepertoireWalkEntry>()
      ..add(
        RepertoireWalkEntry(
          node: _start,
          movePath: _start.getMovePath(),
          ply: 0,
          cumulativeProbability: 1.0,
        ),
      );

    while (queue.isNotEmpty) {
      if (!await _control.checkpoint()) return;

      final entry = queue.removeFirst();
      if (entry.ply > maxPly) continue;

      _visited++;
      if (_visited % progressInterval == 0 || _visited == totalNodes) {
        onProgress?.call(entry);
      }

      await visit(entry);

      queue.addAll(
        entry.children(attenuate: entry.whiteToMove == attenuatingSideIsWhite),
      );
    }
  }
}
