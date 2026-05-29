/// Operational modes for the repertoire builder.
///
/// Replaces the 8-tab system with two focused modes.
library;

enum RepertoireMode {
  edit,
  analyze,
}

/// Context sub-views within Edit mode (context pane TabBar).
enum EditContextView {
  browse,
  engine,
  expectimax,
  lines,
  tree,
}

/// Sub-tabs within Analyze mode (legacy; prefer [AnalyzeMainView] + [AnalyzeContextView]).
enum AnalyzeTab {
  lines,
  coverage,
  traps,
  evalTree,
}

/// Main analyze work area: lines list vs coverage-focused view.
enum AnalyzeMainView {
  lines,
  coverage,
}

/// Analyze context detail pane beside the board / main zone.
enum AnalyzeContextView {
  traps,
  evalTree,
  metrics,
}
