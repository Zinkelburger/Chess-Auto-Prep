import 'package:flutter/material.dart';

/// Spacing scale. Every gap in the app is one of these.
abstract final class Space {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
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
    required this.coordinate,
  });

  final Color lightSquare;
  final Color darkSquare;

  /// Laid over the from and to squares of the move just played.
  final Color lastMove;

  final Color coordinate;

  @override
  BoardTheme copyWith({
    Color? lightSquare,
    Color? darkSquare,
    Color? lastMove,
    Color? coordinate,
  }) => BoardTheme(
    lightSquare: lightSquare ?? this.lightSquare,
    darkSquare: darkSquare ?? this.darkSquare,
    lastMove: lastMove ?? this.lastMove,
    coordinate: coordinate ?? this.coordinate,
  );

  @override
  BoardTheme lerp(BoardTheme? other, double t) {
    if (other == null) return this;
    return BoardTheme(
      lightSquare: Color.lerp(lightSquare, other.lightSquare, t)!,
      darkSquare: Color.lerp(darkSquare, other.darkSquare, t)!,
      lastMove: Color.lerp(lastMove, other.lastMove, t)!,
      coordinate: Color.lerp(coordinate, other.coordinate, t)!,
    );
  }

  static BoardTheme of(BuildContext context) =>
      Theme.of(context).extension<BoardTheme>()!;
}

/// The dark workspace: neutral greys, one muted blue accent, colour kept for
/// meaning. Type is Inter at 14/13/12 with Source Code Pro for moves.
ThemeData darkTheme() {
  const surface = Color(0xFF1B1B1D);
  const panel = Color(0xFF242427);
  const outline = Color(0xFF3A3A3E);
  const text = Color(0xFFE6E6E8);
  const muted = Color(0xFF9A9AA0);
  const accent = Color(0xFF5F93CC);

  const scheme = ColorScheme.dark(
    surface: surface,
    onSurface: text,
    primary: accent,
    onPrimary: Colors.white,
    secondary: accent,
    outline: outline,
    surfaceContainerHighest: panel,
    onSurfaceVariant: muted,
  );
  final base = ThemeData(
    colorScheme: scheme,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: surface,
    dividerColor: outline,
    useMaterial3: true,
  );
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      titleMedium: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      bodyMedium: const TextStyle(fontSize: 14),
      bodySmall: const TextStyle(fontSize: 13, color: muted),
      labelSmall: const TextStyle(fontSize: 12, color: muted),
    ),
    extensions: const [
      BoardTheme(
        lightSquare: Color(0xFFF0D9B5),
        darkSquare: Color(0xFFB58863),
        lastMove: Color(0x669BC700),
        coordinate: Color(0xCC5A4632),
      ),
    ],
  );
}
