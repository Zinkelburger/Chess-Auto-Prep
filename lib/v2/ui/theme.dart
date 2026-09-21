import 'package:flutter/material.dart';

/// Spacing scale. Every gap in the app is one of these.
abstract final class Space {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
}

/// How wide the library panel beside the workspace is.
const libraryPanelWidth = 300.0;

/// How wide a dialog that asks for one line of text is. Wide enough for a
/// long chapter name, narrow enough not to fill the window.
const nameDialogWidth = 360.0;

/// How tall a dialog that asks the user to pick from a list is. Fixed, so the
/// list does not grow and shrink under the pointer as the search narrows it.
const choiceDialogHeight = 280.0;

/// How big an icon is. Icons sit with the text they label, so they follow
/// the type scale rather than Material's default 24.
abstract final class IconSize {
  /// In a button beside body text.
  static const action = 18.0;

  /// The tick in a menu row, and the gap held for it where there is none.
  static const menu = 16.0;
}

/// How wide the evaluation bar beside the board is. A token because the
/// workspace lays the board out next to it, so the bar can be rewritten
/// without the layout having to know the widget.
const evalBarWidth = 12.0;

/// Moves, FENs and evaluations share one monospace style.
const monoText = TextStyle(fontFamily: 'SourceCodePro', fontSize: 13);

/// The headline evaluation in the engine pane.
const scoreText = TextStyle(
  fontFamily: 'SourceCodePro',
  fontSize: 18,
  fontWeight: FontWeight.w600,
);

/// Board colours, resolved from the theme so a light theme can swap them.
final class BoardTheme extends ThemeExtension<BoardTheme> {
  const BoardTheme({
    required this.lightSquare,
    required this.darkSquare,
    required this.lastMove,
    required this.selected,
    required this.coordinate,
    required this.scrim,
    required this.promotionChoice,
  });

  final Color lightSquare;
  final Color darkSquare;

  /// Laid over the from and to squares of the move just played.
  final Color lastMove;

  /// Laid over the square the user has picked a piece up from. Stronger
  /// than [lastMove], which it wins over.
  final Color selected;

  final Color coordinate;

  /// Over the whole board while it is waiting for an answer.
  final Color scrim;

  /// The disc a promotion choice sits on.
  final Color promotionChoice;

  @override
  BoardTheme copyWith({
    Color? lightSquare,
    Color? darkSquare,
    Color? lastMove,
    Color? selected,
    Color? coordinate,
    Color? scrim,
    Color? promotionChoice,
  }) => BoardTheme(
    lightSquare: lightSquare ?? this.lightSquare,
    darkSquare: darkSquare ?? this.darkSquare,
    lastMove: lastMove ?? this.lastMove,
    selected: selected ?? this.selected,
    coordinate: coordinate ?? this.coordinate,
    scrim: scrim ?? this.scrim,
    promotionChoice: promotionChoice ?? this.promotionChoice,
  );

  @override
  BoardTheme lerp(BoardTheme? other, double t) {
    if (other == null) return this;
    return BoardTheme(
      lightSquare: Color.lerp(lightSquare, other.lightSquare, t)!,
      darkSquare: Color.lerp(darkSquare, other.darkSquare, t)!,
      lastMove: Color.lerp(lastMove, other.lastMove, t)!,
      selected: Color.lerp(selected, other.selected, t)!,
      coordinate: Color.lerp(coordinate, other.coordinate, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      promotionChoice: Color.lerp(promotionChoice, other.promotionChoice, t)!,
    );
  }

  /// The file letters and rank digits, sized to a board whose squares are
  /// [side] wide: a share of the square, so they hold their proportion
  /// whatever the board is scaled to.
  TextStyle coordinateStyle(double side) =>
      TextStyle(color: coordinate, fontSize: side * _coordinateShare);

  static const _coordinateShare = 0.18;

  static BoardTheme of(BuildContext context) =>
      Theme.of(context).extension<BoardTheme>()!;
}

/// Neutral greys, one muted blue accent, colour kept for meaning.
const _surface = Color(0xFF1B1B1D);
const _panel = Color(0xFF242427);
const _outline = Color(0xFF3A3A3E);
const _text = Color(0xFFE6E6E8);
const _muted = Color(0xFF9A9AA0);
const _accent = Color(0xFF5F93CC);

const _board = BoardTheme(
  lightSquare: Color(0xFFF0D9B5),
  darkSquare: Color(0xFFB58863),
  lastMove: Color(0x559BC700),
  selected: Color(0x669BC700),
  coordinate: Color(0xCC5A4632),
  scrim: Color(0x80000000),
  promotionChoice: Color(0xFFB0B0B0),
);

/// The dark workspace. Type is Inter at 14/13/12 with Source Code Pro for
/// moves.
ThemeData darkTheme() {
  const scheme = ColorScheme.dark(
    surface: _surface,
    onSurface: _text,
    primary: _accent,
    onPrimary: Colors.white,
    secondary: _accent,
    outline: _outline,
    surfaceContainerHighest: _panel,
    onSurfaceVariant: _muted,
  );
  final base = ThemeData(
    colorScheme: scheme,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: _surface,
    dividerColor: _outline,
    useMaterial3: true,
  );
  return base.copyWith(
    textTheme: _sized(base.textTheme),
    extensions: const [_board],
  );
}

/// The type scale, sized from the styles the theme built rather than from
/// bare ones: a fresh TextStyle carries no family, and a style put into the
/// theme without one is text in whatever font the platform falls back to.
TextTheme _sized(TextTheme base) => base.copyWith(
  titleMedium: base.titleMedium?.copyWith(
    fontSize: 18,
    fontWeight: FontWeight.w600,
  ),
  bodyMedium: base.bodyMedium?.copyWith(fontSize: 14),
  bodySmall: base.bodySmall?.copyWith(fontSize: 13, color: _muted),
  labelSmall: base.labelSmall?.copyWith(fontSize: 12, color: _muted),
);

/// How wide the study panel beside the workspace is. Narrower than the
/// library's: a chapter list is one column of short names.
const studyPanelWidth = 240.0;

/// How tall one chapter row is. Small enough that a long study is one
/// screen, tall enough to hit.
const studyRowHeight = 34.0;
