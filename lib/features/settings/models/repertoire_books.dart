enum BookSide { white, black }

/// Committed repertoire folder selections, independent of their PGN colors.
class RepertoireBooks {
  RepertoireBooks({
    Iterable<String> white = const [],
    Iterable<String> black = const [],
  }) : white = _paths(white),
       black = _paths(black);

  final List<String> white;
  final List<String> black;

  static List<String> _paths(Iterable<String> values) {
    final paths = <String>{};
    for (final path in values) {
      if (path.trim().isEmpty || path.contains('\u0000')) {
        throw ArgumentError.value(path, 'path', 'Invalid repertoire path');
      }
      paths.add(path);
    }
    return List.unmodifiable(paths);
  }

  List<String> forSide(BookSide side) => side == BookSide.white ? white : black;
  bool get hasAny => white.isNotEmpty || black.isNotEmpty;
  RepertoireBooks withSide(BookSide side, Iterable<String> paths) =>
      RepertoireBooks(
        white: side == BookSide.white ? paths : white,
        black: side == BookSide.black ? paths : black,
      );

  @override
  bool operator ==(Object other) =>
      other is RepertoireBooks &&
      _equal(white, other.white) &&
      _equal(black, other.black);
  static bool _equal(List<String> a, List<String> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
  @override
  int get hashCode => Object.hash(Object.hashAll(white), Object.hashAll(black));
}
