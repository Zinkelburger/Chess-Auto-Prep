/// Which detail pane the repertoire builder's context column is showing.
///
/// This file used to describe a two-mode builder — an Edit mode and an
/// Analyze mode, each with its own main and context zone. The Analyze half
/// was superseded by the current single layout
/// (`screens/repertoire/repertoire_screen_layout.dart`) and its widgets were
/// never removed; they and the enums that only they used have now gone.
library;

/// Context sub-views within the builder's context pane (TabBar).
enum EditContextView { browse, engine, expectimax, lines, tree }
