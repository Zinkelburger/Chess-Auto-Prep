/// A cursor into a move tree.
///
/// Each element is a child index at successive depths.
/// `[]` = starting position (before any move).
/// `[0]` = first root child (mainline first move).
/// `[0, 1]` = mainline first move → second child (first variation).
///
/// Wraps a `List<int>` with value semantics for equality/hashCode.
class TreePath {
  final List<int> _indices;

  const TreePath(List<int> indices) : _indices = indices;

  /// Empty path — starting position.
  static const TreePath empty = TreePath([]);

  /// Copy from an existing iterable.
  factory TreePath.from(Iterable<int> source) =>
      TreePath(List<int>.unmodifiable(source));

  /// Number of plies deep.
  int get length => _indices.length;
  bool get isEmpty => _indices.isEmpty;
  bool get isNotEmpty => _indices.isNotEmpty;

  /// Access a child index at depth [i].
  int operator [](int i) => _indices[i];

  /// Parent path (one ply back).  Returns [empty] when already at root.
  TreePath get parent =>
      _indices.isEmpty ? empty : TreePath(_indices.sublist(0, length - 1));

  /// Extend this path with a child index.
  TreePath child(int index) => TreePath([..._indices, index]);

  /// Path truncated to [n] elements.
  TreePath take(int n) => n >= length ? this : TreePath(_indices.sublist(0, n));

  /// Last element.
  int get last => _indices.last;

  /// Whether every element is 0 (mainline).
  bool get isMainline => _indices.every((i) => i == 0);

  /// Whether [other] is a descendant of (or equal to) this path.
  bool isAncestorOf(TreePath other) {
    if (other.length < length) return false;
    for (int i = 0; i < length; i++) {
      if (_indices[i] != other[i]) return false;
    }
    return true;
  }

  /// Iterate over indices.
  Iterable<int> get indices => _indices.map((index) => index);

  /// Convert to a plain list (e.g. for serialization).
  List<int> toList() => List<int>.from(_indices);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TreePath) return false;
    if (length != other.length) return false;
    for (int i = 0; i < length; i++) {
      if (_indices[i] != other._indices[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_indices);

  @override
  String toString() => 'TreePath(${_indices.join(', ')})';
}
