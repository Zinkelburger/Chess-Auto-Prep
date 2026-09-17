/// Presentation indexing for one move-tree revision. No widgets or chess replay.
library;

import '../../../chess_core/moves/move_tree_view.dart';
import '../../../chess_core/moves/tree_path.dart';
import '../../../utils/chess_utils.dart' show isNullMoveSan;
import '../../../utils/fen_utils.dart';
import '../../../utils/pgn_comment_utils.dart' show filterDisplayComment;

/// Shared parent links keep indexing linear even for a very deep main line.
/// Only a visible move or an explicit action needs a materialized [TreePath].
final class MoveTextAddress {
  const MoveTextAddress(this.parent, this.index, this.length);
  final MoveTextAddress? parent;
  final int index;
  final int length;

  TreePath toPath() {
    final indices = List<int>.filled(length, 0);
    MoveTextAddress? cursor = this;
    while (cursor != null) {
      indices[cursor.length - 1] = cursor.index;
      cursor = cursor.parent;
    }
    return TreePath.from(indices);
  }
}

final class MoveTextMove {
  const MoveTextMove(
    this.node,
    this.address,
    this.number,
    this.white,
    this.showNumber,
  );
  final MoveNodeView node;
  final MoveTextAddress address;
  final int number;
  final bool white;
  final bool showNumber;
}

sealed class MoveTextRow {
  const MoveTextRow(this.depth);
  final int depth;
  Object get key;
}

final class MoveTextRun extends MoveTextRow {
  MoveTextRun(super.depth, List<MoveTextMove> moves)
    : moves = List.unmodifiable(moves);
  final List<MoveTextMove> moves;
  @override
  Object get key => ('moves', moves.first.node.id);
}

final class MoveTextComment extends MoveTextRow {
  const MoveTextComment(
    super.depth,
    this.node,
    this.address,
    this.paragraph,
    this.text,
  );
  final MoveNodeView? node;
  final MoveTextAddress? address;
  final int paragraph;
  final String text;
  @override
  Object get key => ('comment', node?.id, paragraph);
}

final class MoveTextInlineEditor extends MoveTextRow {
  const MoveTextInlineEditor(super.depth, this.node, this.address);
  final MoveNodeView node;
  final MoveTextAddress address;
  @override
  Object get key => ('editor', node.id);
}

/// A compact index, built iteratively. Rows cap move runs, not their pixel
/// height: wrapping and text scaling are left to the viewport. Widgets, spans,
/// paths and event handlers are created only for visible/prefetched rows.
final class MoveTextLayout {
  MoveTextLayout._(List<MoveTextRow> rows, Map<int, int> nodeRows)
    : rows = List.unmodifiable(rows),
      _nodeRows = Map.unmodifiable(nodeRows),
      _rowIndices = {for (final (i, row) in rows.indexed) row.key: i};

  final List<MoveTextRow> rows;
  final Map<int, int> _nodeRows;
  final Map<Object, int> _rowIndices;
  int? rowForNode(int id) => _nodeRows[id];
  int? indexOfKey(Object key) => _rowIndices[key];

  factory MoveTextLayout.capture(
    MoveTreeView tree, {
    int? editingNodeId,
    int maxMovesPerRow = 24,
  }) {
    if (maxMovesPerRow < 1) throw ArgumentError.value(maxMovesPerRow);
    final rows = <MoveTextRow>[];
    final nodeRows = <int, int>{};
    final run = <MoveTextMove>[];
    var runDepth = 0;
    void flush() {
      if (run.isEmpty) return;
      for (final move in run) {
        nodeRows[move.node.id] = rows.length;
      }
      rows.add(MoveTextRun(runDepth, run));
      run.clear();
    }

    bool annotations(
      MoveNodeView? node,
      MoveTextAddress? address,
      int depth,
      String? comment,
    ) {
      if (node != null && node.id == editingNodeId) {
        flush();
        nodeRows.putIfAbsent(node.id, () => rows.length);
        rows.add(MoveTextInlineEditor(depth, node, address!));
        return true;
      }
      if (comment == null || comment.isEmpty) return false;
      var emitted = false;
      for (final (index, raw) in comment.split(RegExp(r'\n\s*\n')).indexed) {
        final text = filterDisplayComment(
          raw.replaceAll('{', '').replaceAll('}', ''),
        );
        if (text.isEmpty) continue;
        flush();
        if (node != null) nodeRows.putIfAbsent(node.id, () => rows.length);
        rows.add(MoveTextComment(depth, node, address, index, text));
        emitted = true;
      }
      return emitted;
    }

    void emit(
      MoveNodeView node,
      MoveTextAddress address,
      int number,
      bool white,
      int depth,
    ) {
      if (!isNullMoveSan(node.san)) {
        runDepth = depth;
        run.add(
          MoveTextMove(node, address, number, white, white || run.isEmpty),
        );
        if (run.length == maxMovesPerRow) flush();
      }
      annotations(node, address, depth, node.comment);
    }

    annotations(null, null, 0, tree.rootComment);
    final stack = <_LayoutTask>[
      _Siblings(
        tree.roots,
        null,
        fullMoveNumber(tree.startingFen),
        isWhiteToMove(tree.startingFen),
        0,
      ),
    ];
    while (stack.isNotEmpty) {
      final task = stack.removeLast();
      switch (task) {
        case _Flush():
          flush();
        case _Variation():
          flush();
          emit(task.node, task.address, task.number, task.white, task.depth);
          stack.add(const _Flush());
          stack.add(
            _Siblings(
              task.node.children,
              task.address,
              task.white ? task.number : task.number + 1,
              !task.white,
              task.depth,
            ),
          );
        case _Siblings():
          if (task.nodes.isEmpty) continue;
          final main = task.nodes.first;
          final length = (task.parent?.length ?? 0) + 1;
          final address = MoveTextAddress(task.parent, 0, length);
          emit(main, address, task.number, task.white, task.depth);
          stack.add(
            _Siblings(
              main.children,
              address,
              task.white ? task.number : task.number + 1,
              !task.white,
              task.depth,
            ),
          );
          if (task.nodes.length > 1) {
            flush();
            for (var i = task.nodes.length - 1; i > 0; i--) {
              stack.add(
                _Variation(
                  task.nodes[i],
                  MoveTextAddress(task.parent, i, length),
                  task.number,
                  task.white,
                  task.depth + 1,
                ),
              );
            }
          }
      }
    }
    flush();
    return MoveTextLayout._(rows, nodeRows);
  }
}

sealed class _LayoutTask {
  const _LayoutTask();
}

final class _Flush extends _LayoutTask {
  const _Flush();
}

final class _Siblings extends _LayoutTask {
  const _Siblings(this.nodes, this.parent, this.number, this.white, this.depth);
  final List<MoveNodeView> nodes;
  final MoveTextAddress? parent;
  final int number;
  final bool white;
  final int depth;
}

final class _Variation extends _LayoutTask {
  const _Variation(
    this.node,
    this.address,
    this.number,
    this.white,
    this.depth,
  );
  final MoveNodeView node;
  final MoveTextAddress address;
  final int number;
  final bool white;
  final int depth;
}
