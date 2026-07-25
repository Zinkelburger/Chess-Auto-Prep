/// How much of the repertoire builder's width the board column takes.
///
/// The board is square, so its width is also its height budget: shrinking it
/// hands the reclaimed width straight to the engine/PGN columns beside it.
/// [widthFactor] scales the natural size (the largest square that fits the
/// pane), so [large] is exactly the pre-existing layout.
library;

enum BoardSize {
  small('Small', 0.62),
  medium('Medium', 0.80),
  large('Large', 1.0);

  const BoardSize(this.label, this.widthFactor);

  /// Menu label, spelled out.
  final String label;

  /// Multiplier on the largest board that would fit the pane.
  final double widthFactor;

  /// Parse a persisted [name], falling back to [large] (the classic layout).
  static BoardSize fromName(String? name) {
    for (final size in values) {
      if (size.name == name) return size;
    }
    return large;
  }
}
