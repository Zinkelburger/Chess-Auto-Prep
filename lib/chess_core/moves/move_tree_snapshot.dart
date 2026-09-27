import 'package:dartchess/dartchess.dart';

import '../../utils/chess_utils.dart' show tryParseFen;
import 'move_tree_view.dart';

/// Detached tree values. No list or node aliases the editable source.
///
/// Owners cache this projection by tree revision. Cursor changes must reuse it.
/// Construction is iterative so deeply nested PGNs do not exhaust the stack.
final class MoveTreeSnapshot extends MoveTreeView {
  MoveTreeSnapshot._(
    this.identity,
    this.startingFen,
    this.rootComment,
    this.version,
    this.roots,
  );

  factory MoveTreeSnapshot.capture(MoveTreeView source, {Object? identity}) =>
      MoveTreeSnapshot.revise(
        source,
        previous: null,
        changedNodeIds: const {},
        identity: identity,
      );

  /// Rebuild changed nodes and their ancestors, sharing detached values for
  /// untouched branches. The private owner must include every changed ancestor
  /// ID; bulk edits without that provenance use [capture]. Root lists are always
  /// reconciled by ID, so sibling deletion/reordering cannot misattach a view.
  factory MoveTreeSnapshot.revise(
    MoveTreeView source, {
    required MoveTreeSnapshot? previous,
    required Set<int> changedNodeIds,
    Object? identity,
  }) {
    return MoveTreeSnapshot._(
      previous?.identity ?? identity ?? Object(),
      source.startingFen,
      source.rootComment,
      source.version,
      MoveNodeSnapshot.captureAll(
        source.roots,
        previous: previous?.roots,
        changedNodeIds: changedNodeIds,
      ),
    );
  }

  @override
  final String startingFen;
  @override
  final Object identity;
  @override
  final String? rootComment;
  @override
  final int version;
  @override
  final List<MoveNodeSnapshot> roots;
}

final class MoveNodeSnapshot implements MoveNodeView {
  MoveNodeSnapshot._(MoveNodeView node, List<MoveNodeSnapshot> children)
    : id = node.id,
      san = node.san,
      fen = node.fen,
      comment = node.comment,
      startingComment = node.startingComment,
      nags = node.nags == null ? null : List.unmodifiable(node.nags!),
      isEphemeral = node.isEphemeral,
      children = List.unmodifiable(children);

  /// Capture a detached forest, sharing unchanged branches when the owner
  /// supplies every changed node and ancestor ID. Omit [previous] for bulk edits.
  static List<MoveNodeSnapshot> captureAll(
    List<MoveNodeView> roots, {
    List<MoveNodeSnapshot>? previous,
    Set<int> changedNodeIds = const {},
  }) {
    final copied = <int, MoveNodeSnapshot>{};
    final priorRoots = {
      for (final node in previous ?? <MoveNodeSnapshot>[]) node.id: node,
    };
    final pending = [
      for (final node in roots) (node, priorRoots[node.id], false),
    ];
    while (pending.isNotEmpty) {
      final (node, prior, visited) = pending.removeLast();
      if (prior != null && !changedNodeIds.contains(node.id)) {
        copied[node.id] = prior;
      } else if (!visited) {
        pending.add((node, prior, true));
        final priorChildren = {
          for (final child in prior?.children ?? <MoveNodeSnapshot>[])
            child.id: child,
        };
        pending.addAll(
          node.children.map((child) => (child, priorChildren[child.id], false)),
        );
      } else {
        copied[node.id] = MoveNodeSnapshot._(node, [
          for (final child in node.children) copied[child.id]!,
        ]);
      }
    }
    return List.unmodifiable([for (final node in roots) copied[node.id]!]);
  }

  @override
  final int id;
  @override
  final String san;
  @override
  final String fen;
  @override
  final String? comment;
  @override
  final String? startingComment;
  @override
  final List<int>? nags;
  @override
  final bool isEphemeral;
  @override
  final List<MoveNodeSnapshot> children;
  @override
  String get fenAfter => fen;
  @override
  List<MoveNodeSnapshot> get orderedChildren => children;
  // Lazy parsing belongs to this detached value; it never reads its source.
  late final Position? _position = tryParseFen(fen);
  @override
  Position? get positionOrNull => _position;
  @override
  Position get position => _position ?? Chess.initial;
}
