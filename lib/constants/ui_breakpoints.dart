/// Shared responsive layout breakpoints.
///
/// Use these instead of bare numeric literals in [LayoutBuilder] and
/// [MediaQuery] width checks so all screens break at the same widths.
library;

/// Below this width, switch to a single-column (compact) layout.
const double kCompactBreakpoint = 960;

/// At or above this width, use the three-zone repertoire layout (board / main / context).
const double kWideBreakpoint = 1100;
