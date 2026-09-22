import '../moves/move_tree_snapshot.dart';
import '../moves/move_tree_view.dart';

/// Detached Viewer variations, keyed by their mainline branch ply.
/// Owners mark changed ancestry before editing; navigation reuses the view.
class SidelineProjectionCache {
  Map<int, List<MoveNodeSnapshot>>? _view;
  final _changes = <int, Set<int>>{};
  final _bulkPlies = <int>{};

  void reset() {
    _view = null;
    _changes.clear();
    _bulkPlies.clear();
  }

  /// Null ancestry recaptures a whole ply. Empty ancestry reconciles roots,
  /// sharing retained roots when only a root was added or removed.
  void changed(int ply, {Iterable<int>? ancestry}) {
    if (_view == null) return;
    if (ancestry == null) {
      _bulkPlies.add(ply);
    } else {
      (_changes[ply] ??= {}).addAll(ancestry);
    }
  }

  Map<int, List<MoveNodeSnapshot>> read(Map<int, List<MoveNodeView>> source) {
    final previous = _view;
    if (previous != null && _changes.isEmpty && _bulkPlies.isEmpty) {
      return previous;
    }
    final next = <int, List<MoveNodeSnapshot>>{};
    for (final MapEntry(key: ply, value: roots) in source.entries) {
      final prior = previous?[ply];
      next[ply] =
          prior != null &&
              !_changes.containsKey(ply) &&
              !_bulkPlies.contains(ply)
          ? prior
          : MoveNodeSnapshot.captureAll(
              roots,
              previous: _bulkPlies.contains(ply) ? null : prior,
              changedNodeIds: _changes[ply] ?? const {},
            );
    }
    _view = Map.unmodifiable(next);
    _changes.clear();
    _bulkPlies.clear();
    return _view!;
  }
}
