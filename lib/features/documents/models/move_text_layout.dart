/// Presentation indexing for one move-tree revision. No widgets or chess replay.
library;

import 'dart:collection';

import '../../../chess_core/moves/move_tree_view.dart';
import '../../../chess_core/moves/move_tree_snapshot.dart';
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

typedef MoveTextParagraph = ({int index, String text});

/// Reuse filtered prose for structurally shared nodes across annotation edits.
/// Weak keys cannot keep an obsolete document alive. Checking the source text
/// also supports the remaining mutable MoveTreeView callers safely.
final class MoveTextCommentCache {
  final _nodes = Expando<(String, List<MoveTextParagraph>)>();
  (String, List<MoveTextParagraph>)? _root;
  static final _paragraphBreak = RegExp(r'\n\s*\n');

  List<MoveTextParagraph> paragraphs(MoveNodeView? node, String comment) {
    final cached = node == null ? _root : _nodes[node];
    if (cached != null && cached.$1 == comment) return cached.$2;
    final paragraphs = <MoveTextParagraph>[];
    for (final (index, raw) in comment.split(_paragraphBreak).indexed) {
      final text = filterDisplayComment(
        raw.replaceAll('{', '').replaceAll('}', ''),
      );
      if (text.isNotEmpty) paragraphs.add((index: index, text: text));
    }
    final result = List<MoveTextParagraph>.unmodifiable(paragraphs);
    if (node == null) {
      _root = (comment, result);
    } else {
      _nodes[node] = (comment, result);
    }
    return result;
  }
}

/// A compact index, built iteratively. Rows cap move runs, not their pixel
/// height: wrapping and text scaling are left to the viewport. Widgets, spans,
/// paths and event handlers are created only for visible/prefetched rows.
final class MoveTextLayout {
  MoveTextLayout._(
    List<MoveTextRow> rows,
    Map<int, int> nodeRows, {
    MoveTreeSnapshot? snapshot,
  }) : rows = UnmodifiableListView(rows),
       _nodeRows = nodeRows,
       _snapshot = snapshot;

  final List<MoveTextRow> rows;
  final Map<int, int> _nodeRows;
  final MoveTreeSnapshot? _snapshot;
  int? rowForNode(int id) => _nodeRows[id];

  /// Every annotation follows its node's move run (or replaces it for a null
  /// move). Resolve mounted row keys from the existing node index instead of
  /// rebuilding a second document-sized map on each annotation edit.
  int? indexOfKey(Object key) {
    final int? nodeId;
    switch (key) {
      case ('moves', int id):
      case ('editor', int id):
        nodeId = id;
      case ('comment', int? id, int _):
        nodeId = id;
      default:
        return null;
    }
    final start = nodeId == null ? 0 : _nodeRows[nodeId];
    if (start == null || start >= rows.length) return null;
    var index = start;
    if (rows[index].key == key) return index;
    if (rows[index] is MoveTextRun) index++;
    while (index < rows.length) {
      final row = rows[index];
      if (row.key == key) return index;
      if (row is! MoveTextComment || row.node?.id != nodeId) return null;
      index++;
    }
    return null;
  }

  /// Reuse row structure for annotation-only revisions of immutable trees.
  /// A structural change or a different paragraph count uses full indexing.
  /// Identity comparisons are safe only for detached snapshots, never mutable
  /// legacy trees. Ancestors copied by the projection still receive fresh nodes.
  MoveTextLayout? reviseAnnotations(
    MoveTreeSnapshot after, {
    required MoveTextCommentCache comments,
  }) {
    final before = _snapshot;
    if (before == null ||
        !identical(before.identity, after.identity) ||
        before.startingFen != after.startingFen ||
        before.rootComment != after.rootComment ||
        before.roots.length != after.roots.length) {
      return null;
    }
    final changed = <int, MoveNodeSnapshot>{};
    final paragraphs = <int, List<MoveTextParagraph>>{};
    final pending = [
      for (var i = 0; i < before.roots.length; i++)
        (before.roots[i], after.roots[i]),
    ];
    while (pending.isNotEmpty) {
      final (old, current) = pending.removeLast();
      if (identical(old, current)) continue;
      if (old.id != current.id ||
          old.san != current.san ||
          old.children.length != current.children.length) {
        return null;
      }
      changed[current.id] = current;
      if (old.comment != current.comment) {
        final oldParagraphs = comments.paragraphs(old, old.comment ?? '');
        final newParagraphs = comments.paragraphs(
          current,
          current.comment ?? '',
        );
        if (oldParagraphs.length != newParagraphs.length) return null;
        paragraphs[current.id] = newParagraphs;
      }
      for (var i = 0; i < old.children.length; i++) {
        pending.add((old.children[i], current.children[i]));
      }
    }
    final revised = <MoveTextRow>[];
    final paragraphOffsets = <int, int>{};
    for (final row in rows) {
      switch (row) {
        case MoveTextRun():
          revised.add(
            row.moves.any((move) => changed.containsKey(move.node.id))
                ? MoveTextRun(row.depth, [
                    for (final move in row.moves)
                      changed.containsKey(move.node.id)
                          ? MoveTextMove(
                              changed[move.node.id]!,
                              move.address,
                              move.number,
                              move.white,
                              move.showNumber,
                            )
                          : move,
                  ])
                : row,
          );
        case MoveTextComment():
          final node = changed[row.node?.id];
          if (node == null) {
            revised.add(row);
          } else {
            final offset = paragraphOffsets.update(
              node.id,
              (n) => n + 1,
              ifAbsent: () => 0,
            );
            final paragraph = paragraphs[node.id]?[offset];
            revised.add(
              MoveTextComment(
                row.depth,
                node,
                row.address,
                paragraph?.index ?? row.paragraph,
                paragraph?.text ?? row.text,
              ),
            );
          }
        case MoveTextInlineEditor():
          final node = changed[row.node.id];
          revised.add(
            node == null
                ? row
                : MoveTextInlineEditor(row.depth, node, row.address),
          );
      }
    }
    return MoveTextLayout._(revised, _nodeRows, snapshot: after);
  }

  factory MoveTextLayout.capture(
    MoveTreeView tree, {
    int? editingNodeId,
    int maxMovesPerRow = 24,
    MoveTextCommentCache? comments,
  }) {
    if (maxMovesPerRow < 1) throw ArgumentError.value(maxMovesPerRow);
    final rows = <MoveTextRow>[];
    final nodeRows = <int, int>{};
    final run = <MoveTextMove>[];
    final commentCache = comments ?? MoveTextCommentCache();
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
      for (final paragraph in commentCache.paragraphs(node, comment)) {
        flush();
        if (node != null) nodeRows.putIfAbsent(node.id, () => rows.length);
        rows.add(
          MoveTextComment(
            depth,
            node,
            address,
            paragraph.index,
            paragraph.text,
          ),
        );
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
    return MoveTextLayout._(
      rows,
      nodeRows,
      snapshot: tree is MoveTreeSnapshot ? tree : null,
    );
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
