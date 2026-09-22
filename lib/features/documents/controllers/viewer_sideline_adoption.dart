import 'dart:collection';
import 'package:collection/collection.dart';
import '../../../models/move_tree.dart';

/// Validates the entire stored forest before changing anything. Incoming
/// annotations and sibling order are authoritative; unmatched scratch nodes
/// survive. New persistent nodes must lie on the exact referenced engine path.
/// Matching equal-SAN siblings consumes them in occurrence order, so duplicate
/// branches never alias one mutable node or silently lose their annotations.
class ViewerSidelineAdoption {
  ViewerSidelineAdoption._(this._plies);
  final Map<int, List<_SiblingAdoption>> _plies;

  static ViewerSidelineAdoption? plan({
    required Map<int, List<MoveNode>> current,
    required Map<int, List<MoveNode>> incoming,
    required Map<int, List<String>> enginePaths,
  }) {
    final plies = <int, List<_SiblingAdoption>>{};
    for (final ply in {...current.keys, ...incoming.keys}) {
      final source = incoming[ply] ?? const <MoveNode>[];
      final allowed = <MoveNode>{};
      var candidates = source;
      for (final san in enginePaths[ply] ?? const <String>[]) {
        final next = candidates.where((node) => node.san == san).firstOrNull;
        if (next == null) break;
        allowed.add(next);
        candidates = next.children;
      }
      final plans = plies[ply] = <_SiblingAdoption>[];
      final pending = [
        (current[ply] ?? <MoveNode>[], source, null as MoveNode?),
      ];
      while (pending.isNotEmpty) {
        final (target, source, parent) = pending.removeLast();
        final buckets = <(String, String), Queue<MoveNode>>{};
        for (final node in target) {
          (buckets[(node.san, node.fen)] ??= Queue()).add(node);
        }
        final ordered = <MoveNode>[];
        final matches = <(MoveNode, MoveNode)>[];
        final retained = <MoveNode>{};
        for (final node in source) {
          final bucket = buckets[(node.san, node.fen)];
          final existing = bucket == null || bucket.isEmpty
              ? null
              : bucket.removeFirst();
          if ((existing == null || existing.isEphemeral) &&
              !allowed.contains(node)) {
            return null;
          }
          if (existing == null) {
            // Validate every new descendant, not just the first SAN of a PV.
            final descendants = [node];
            while (descendants.isNotEmpty) {
              final child = descendants.removeLast();
              if (!allowed.contains(child)) return null;
              descendants.addAll(child.children);
            }
            ordered.add(node);
          } else {
            retained.add(existing);
            ordered.add(existing);
            matches.add((existing, node));
            pending.add((existing.children, node.children, existing));
          }
        }
        for (final node in target) {
          if (retained.contains(node)) continue;
          if (!node.isEphemeral) return null;
          ordered.add(node);
        }
        plans.add(_SiblingAdoption(target, ordered, matches, parent));
      }
    }
    return ViewerSidelineAdoption._(plies);
  }

  /// Returns changed IDs including ancestors, for incremental projection.
  /// A changed root list can have no changed old IDs (e.g. a new engine RAV).
  Map<int, Set<int>> apply(Map<int, List<MoveNode>> target) {
    final changes = <int, Set<int>>{};
    for (final MapEntry(key: ply, value: plans) in _plies.entries) {
      final dirty = <int>{};
      var changed = false;
      for (final plan in plans.reversed) {
        for (final (owned, source) in plan.matches) {
          if (owned.isEphemeral ||
              owned.comment != source.comment ||
              owned.startingComment != source.startingComment ||
              !const ListEquality<int>().equals(owned.nags, source.nags)) {
            owned
              ..isEphemeral = false
              ..comment = source.comment
              ..startingComment = source.startingComment
              ..nags = source.nags?.toList();
            dirty.add(owned.id);
          }
        }
        final reordered = !const ListEquality<MoveNode>().equals(
          plan.target,
          plan.ordered,
        );
        final subtreeChanged =
            reordered || plan.ordered.any((node) => dirty.contains(node.id));
        if (reordered) {
          plan.target
            ..clear()
            ..addAll(plan.ordered);
        }
        if (subtreeChanged) {
          changed = true;
          final parent = plan.parent;
          if (parent != null) dirty.add(parent.id);
        }
      }
      if (changed) {
        target[ply] = plans.first.target;
        changes[ply] = dirty;
      }
    }
    return changes;
  }
}

class _SiblingAdoption {
  _SiblingAdoption(this.target, this.ordered, this.matches, this.parent);
  final List<MoveNode> target;
  final List<MoveNode> ordered;
  final List<(MoveNode, MoveNode)> matches;
  final MoveNode? parent;
}
