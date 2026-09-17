import 'move_tree_snapshot.dart';
import 'move_tree_view.dart';
import 'tree_path.dart';

/// One private mutable tree's lazy, detached presentation values.
///
/// The owner records changed paths before mutation so removed/reordered nodes
/// still identify their original ancestors. Bulk edits omit the path. Replacing
/// the source starts a new editing identity; navigation reuses the exact view.
class MoveTreeProjectionCache {
  MoveTreeView? _source;
  Object _session = Object();
  MoveTreeSnapshot? _snapshot;
  Set<int>? _changedNodes;
  bool _bulkChange = false;

  /// Opaque identity: consumers never receive the mutable source itself.
  Object sessionFor(MoveTreeView source) {
    if (!identical(_source, source)) {
      _source = source;
      _session = Object();
      _snapshot = null;
      _changedNodes = null;
      _bulkChange = false;
    }
    return _session;
  }

  void changed(MoveTreeView source, {TreePath? path}) {
    sessionFor(source);
    if (_snapshot == null) return;
    if (path == null) {
      _bulkChange = true;
    } else {
      (_changedNodes ??= {}).addAll(
        source.nodeListAt(path).map((node) => node.id),
      );
    }
  }

  MoveTreeSnapshot read(MoveTreeView source) {
    final identity = sessionFor(source);
    final previous = _snapshot;
    if (previous != null && previous.version == source.version) {
      _changedNodes = null;
      _bulkChange = false;
      return previous;
    }
    final next = previous != null && !_bulkChange && _changedNodes != null
        ? MoveTreeSnapshot.revise(
            source,
            previous: previous,
            changedNodeIds: _changedNodes!,
          )
        : MoveTreeSnapshot.capture(source, identity: identity);
    _snapshot = next;
    _changedNodes = null;
    _bulkChange = false;
    return next;
  }
}
