import '../../../chess_core/moves/move_tree_view.dart';
import '../../../chess_core/pgn/pgn_game_view.dart';

/// A bounded piece of the reading document. Indexing never constructs widgets,
/// parses prose, or replays positions. Node and move identities survive edits.
sealed class ViewerDocumentRow {
  const ViewerDocumentRow();
  Object get key;
}

final class ViewerIntroductionRow extends ViewerDocumentRow {
  const ViewerIntroductionRow();
  @override
  Object get key => 'introduction';
}

final class ViewerFrontierRow extends ViewerDocumentRow {
  const ViewerFrontierRow(this.ply);
  final int ply;
  @override
  Object get key => ('frontier', ply);
}

final class ViewerMainlineRow extends ViewerDocumentRow {
  const ViewerMainlineRow(this.start, this.end, this.identity);
  final int start;
  final int end;
  final Object identity;
  @override
  Object get key => ('mainline', identity);
}

final class ViewerVariationRow extends ViewerDocumentRow {
  ViewerVariationRow({
    required this.nodes,
    required this.root,
    required this.ply,
    required this.branchPly,
    required this.depth,
    required this.open,
    required this.containsCurrent,
    this.proseReference = false,
    this.engineMove,
  });
  final List<MoveNodeView> nodes;
  final MoveNodeView root;
  final int ply;
  final int branchPly;
  final int depth;
  final bool open;
  final bool containsCurrent;
  final bool proseReference;
  final int? engineMove;
  bool get first => nodes.first.id == root.id;
  @override
  Object get key => ('variation', nodes.first.id);
}

/// Immutable, iterative index of the visible document, including collapsed
/// branch heads. Building is O(visible nodes); row construction is bounded by
/// [maxRunLength]. Selection lookup and stable-key lookup are O(1).
final class ViewerDocumentLayout {
  static const maxRunLength = 24;
  ViewerDocumentLayout({
    required List<PgnMoveSnapshot> moves,
    required Map<int, List<MoveNodeView>> variations,
    required bool Function(MoveNodeView, int) visible,
    required bool Function(MoveNodeView, int) proseReference,
    required bool Function(int) inlineVariation,
    required Map<int, bool> visibility,
    required Set<int> selectedPath,
    required bool expandAll,
    required int frontier,
    required Map<int, int> engineRoots,
    MoveNodeView? scope,
    int scopePly = 0,
    int scopeBranchPly = 0,
    int? editingCommentIndex,
    bool Function(PgnMoveSnapshot, int)? breaksMainline,
  }) {
    final rows = <ViewerDocumentRow>[];
    void addBranch(
      MoveNodeView root,
      int ply,
      int branchPly,
      int depth, {
      int? engineMove,
    }) {
      final pending = <_BranchWork>[
        _BranchWork(root, root, ply, branchPly, depth, const [], engineMove),
      ];
      while (pending.isNotEmpty) {
        final work = pending.removeLast();
        final contains = selectedPath.contains(work.root.id);
        final open =
            work.depth == 0 ||
            contains ||
            (visibility[work.root.id] ?? (expandAll || work.depth <= 2));
        final reference =
            work.depth == 1 &&
            work.engineMove == null &&
            work.node.id == work.root.id &&
            proseReference(work.node, work.ply);
        final nodes = <MoveNodeView>[];
        var node = work.node;
        var ply = work.ply;
        var alternatives = work.alternatives;
        while (true) {
          nodes.add(node);
          if (!open || reference) break;
          final next = node.children
              .where((n) => visible(n, work.branchPly))
              .toList();
          final continuation = next.isEmpty
              ? null
              : _BranchWork(
                  work.root,
                  next.first,
                  ply + 1,
                  work.branchPly,
                  work.depth,
                  next.skip(1).toList(),
                  work.engineMove,
                );
          final split =
              alternatives.isNotEmpty ||
              nodes.length == maxRunLength ||
              _annotated(node) ||
              (next.isNotEmpty && _annotated(next.first));
          if (split || continuation == null) {
            if (continuation != null) pending.add(continuation);
            for (final alternative in alternatives.reversed) {
              pending.add(
                _BranchWork(
                  alternative,
                  alternative,
                  ply,
                  work.branchPly,
                  work.depth + 1,
                  const [],
                  work.engineMove,
                ),
              );
            }
            break;
          }
          node = next.first;
          alternatives = next.skip(1).toList();
          ply++;
        }
        rows.add(
          ViewerVariationRow(
            nodes: List.unmodifiable(nodes),
            root: work.root,
            ply: work.ply,
            branchPly: work.branchPly,
            depth: work.depth,
            open: open,
            containsCurrent: contains,
            proseReference: reference,
            engineMove: work.engineMove,
          ),
        );
      }
    }

    void addVariations(int ply) {
      if (inlineVariation(ply)) return;
      final roots = variations[ply] ?? const <MoveNodeView>[];
      final engineId = engineRoots[ply];
      // Suggested alternatives immediately follow their verdict.
      if (engineId != null) {
        for (final root in roots) {
          if (root.id == engineId && visible(root, ply)) {
            addBranch(root, ply, ply, 1, engineMove: ply);
          }
        }
      }
      for (final root in roots) {
        if (root.id != engineId && visible(root, ply)) {
          addBranch(root, ply, ply, 1);
        }
      }
    }

    if (scope != null) {
      addBranch(scope, scopePly, scopeBranchPly, 0);
    } else {
      rows.add(const ViewerIntroductionRow());
      var start = 0;
      final end = frontier.clamp(0, moves.length);
      for (var i = 0; i < end; i++) {
        final move = moves[i];
        final separate =
            breaksMainline?.call(move, i) ??
            ((move.comments?.isNotEmpty ?? false) ||
                (move.startingComments?.isNotEmpty ?? false) ||
                editingCommentIndex == i);
        if (separate && start < i) {
          rows.add(ViewerMainlineRow(start, i, moves[start].identity));
          start = i;
        }
        if (separate ||
            i - start + 1 == maxRunLength ||
            ((variations[i]?.isNotEmpty ?? false) && !inlineVariation(i)) ||
            i + 1 == end) {
          rows.add(ViewerMainlineRow(start, i + 1, moves[start].identity));
          addVariations(i);
          start = i + 1;
        }
      }
      if (inlineVariation(end)) {
        rows.add(ViewerFrontierRow(end));
      } else {
        addVariations(end);
      }
    }
    this.rows = List.unmodifiable(rows);
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      _keys[row.key] = i;
      if (row is ViewerMainlineRow) {
        for (var ply = row.start; ply < row.end; ply++) {
          _mainline[ply] = i;
          if (inlineVariation(ply)) {
            var node = variations[ply]!.single;
            while (true) {
              _nodes[node.id] = i;
              final next = node.children.where((n) => visible(n, ply));
              if (next.isEmpty) break;
              node = next.first;
            }
          }
        }
      } else if (row is ViewerFrontierRow) {
        var node = variations[row.ply]!.single;
        while (true) {
          _nodes[node.id] = i;
          final next = node.children.where((n) => visible(n, row.ply));
          if (next.isEmpty) break;
          node = next.first;
        }
      } else if (row is ViewerVariationRow) {
        for (final node in row.nodes) {
          _nodes[node.id] = i;
        }
      }
    }
  }
  late final List<ViewerDocumentRow> rows;
  final _keys = <Object, int>{};
  final _mainline = <int, int>{};
  final _nodes = <int, int>{};
  int? indexOfKey(Object key) => _keys[key];
  int? mainlineRow(int ply) => _mainline[ply];
  int? nodeRow(int id) => _nodes[id];

  static bool _annotated(MoveNodeView node) =>
      (node.comment?.isNotEmpty ?? false) ||
      (node.startingComment?.isNotEmpty ?? false);
}

final class _BranchWork {
  const _BranchWork(
    this.root,
    this.node,
    this.ply,
    this.branchPly,
    this.depth,
    this.alternatives,
    this.engineMove,
  );
  final MoveNodeView root;
  final MoveNodeView node;
  final int ply;
  final int branchPly;
  final int depth;
  final List<MoveNodeView> alternatives;
  final int? engineMove;
}
