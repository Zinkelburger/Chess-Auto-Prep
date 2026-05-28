/// Operational modes for the repertoire builder.
///
/// Replaces the 8-tab system with two focused modes.
library;

enum RepertoireMode {
  edit,
  analyze,
}

/// Context sub-views within Edit mode.
enum EditContextView {
  engine,
  expectimax,
  tree,
}

/// Sub-tabs within Analyze mode.
enum AnalyzeTab {
  lines,
  coverage,
  traps,
  evalTree,
}
