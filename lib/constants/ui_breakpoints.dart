/// Shared responsive layout breakpoints.
///
/// Use these instead of bare numeric literals in [LayoutBuilder] and
/// [MediaQuery] width checks so all screens break at the same widths.
library;

/// Below this width, switch to a single-column (compact) layout.
const double kCompactBreakpoint = 960;

/// Below this width, toolbar action buttons collapse from text+icon to icon-only.
const double kToolbarCompactBreakpoint = 900;
