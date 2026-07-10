/// Column layout shared by the lines table header and line rows so
/// the stat columns stay aligned at every pane width.
library;

class LineTableLayout {
  /// Show the Moves / Traps / Coverage columns. In narrow side panels these
  /// collapse into inline badges on the line cell instead.
  final bool showMovesColumn;
  final bool showTrapsColumn;
  final bool showCoverageColumn;

  const LineTableLayout({
    required this.showMovesColumn,
    required this.showTrapsColumn,
    required this.showCoverageColumn,
  });

  factory LineTableLayout.forWidth(double width) {
    final wide = width >= 520;
    return LineTableLayout(
      showMovesColumn: wide,
      showTrapsColumn: wide,
      showCoverageColumn: wide,
    );
  }

  static const double movesWidth = 52;
  static const double easeWidth = 52;
  static const double coherenceWidth = 82;
  static const double trapsWidth = 48;
  static const double coverageWidth = 82;
}
