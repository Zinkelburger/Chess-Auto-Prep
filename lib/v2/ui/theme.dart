import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';

/// Spacing scale. Every gap in the app is one of these.
abstract final class Space {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
}

/// How wide the list beside the workspace starts out, whichever mode fills
/// it; the user drags it from there.
const libraryPanelWidth = 300.0;

/// How wide the chapter outline between the list and the board starts out.
/// The old app's column is 18% of the window's body clamped to 220–280.
const outlineColumnWidth = 240.0;

/// How tall one row of the outline is, and how far a line sits in under the
/// chapter it belongs to. Both are the old app's values.
const outlineRowHeight = 30.0;
const outlineIndent = 14.0;

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

/// How the board looks, resolved from the theme so a light theme can swap
/// it. The board itself is Lichess's `chessground`; this is the one place
/// that says what it draws with.
final class BoardTheme extends ThemeExtension<BoardTheme> {
  const BoardTheme({
    required this.lightSquare,
    required this.darkSquare,
    required this.lastMove,
    required this.selected,
    required this.validMove,
  });

  final Color lightSquare;
  final Color darkSquare;

  /// Laid over the from and to squares of the move just played.
  final Color lastMove;

  /// Laid over the square the user has picked a piece up from. Stronger
  /// than [lastMove], which it wins over.
  final Color selected;

  /// The dot on a square the picked-up piece can go to. Shown only when
  /// [showValidMoves] is on.
  final Color validMove;

  /// Whether picking a piece up marks the squares it can go to, as Lichess
  /// does. Off: the old app never did, and the marks are noise on a board
  /// that is mostly read rather than played on.
  static const showValidMoves = false;

  /// How long a piece takes to slide to its square when the position
  /// changes. The route and menu motion is 150 ms and 100 ms; a piece is a
  /// smaller thing moving a shorter way.
  static const animation = Duration(milliseconds: 120);

  /// Everything the board is given: colours, pieces, and how it behaves
  /// under a mouse. Both sides may move, there are no premoves, and a
  /// dragged piece stays its own size under the pointer rather than
  /// growing above a finger.
  ChessboardSettings get settings => ChessboardSettings(
    colorScheme: _colors,
    pieceAssets: PieceSet.cburnettAssets,
    animationDuration: animation,
    showValidMoves: showValidMoves,
    enablePremoves: false,
    dragFeedbackScale: 1,
    dragFeedbackOffset: Offset.zero,
  );

  ChessboardColorScheme get _colors {
    final plain = SolidColorChessboardBackground(
      lightSquare: lightSquare,
      darkSquare: darkSquare,
    );
    return ChessboardColorScheme(
      lightSquare: lightSquare,
      darkSquare: darkSquare,
      background: plain,
      whiteCoordBackground: SolidColorChessboardBackground(
        lightSquare: lightSquare,
        darkSquare: darkSquare,
        coordinates: true,
      ),
      blackCoordBackground: SolidColorChessboardBackground(
        lightSquare: lightSquare,
        darkSquare: darkSquare,
        coordinates: true,
        orientation: Side.black,
      ),
      lastMove: HighlightDetails(solidColor: lastMove),
      selected: HighlightDetails(solidColor: selected),
      validMoves: validMove,
      validPremoves: validMove,
    );
  }

  @override
  BoardTheme copyWith({
    Color? lightSquare,
    Color? darkSquare,
    Color? lastMove,
    Color? selected,
    Color? validMove,
  }) => BoardTheme(
    lightSquare: lightSquare ?? this.lightSquare,
    darkSquare: darkSquare ?? this.darkSquare,
    lastMove: lastMove ?? this.lastMove,
    selected: selected ?? this.selected,
    validMove: validMove ?? this.validMove,
  );

  @override
  BoardTheme lerp(BoardTheme? other, double t) {
    if (other == null) return this;
    return BoardTheme(
      lightSquare: Color.lerp(lightSquare, other.lightSquare, t)!,
      darkSquare: Color.lerp(darkSquare, other.darkSquare, t)!,
      lastMove: Color.lerp(lastMove, other.lastMove, t)!,
      selected: Color.lerp(selected, other.selected, t)!,
      validMove: Color.lerp(validMove, other.validMove, t)!,
    );
  }

  static BoardTheme of(BuildContext context) =>
      Theme.of(context).extension<BoardTheme>()!;
}

/// The bar between two panes the user can drag: one pixel of line, with a
/// grab area either side of it so it can be found with a mouse.
const paneDividerWidth = 1.0;
const paneDividerGrab = 4.0;

/// Narrower than this and a list is unreadable, a board unplayable.
const paneMinWidth = 180.0;
const boardPaneMinWidth = 320.0;

/// How wide the column to the right of the board is: the chapter, the
/// engine, the moves and their comment.
const sidePanelWidth = 360.0;

/// What the dividers between panes look like: the outline colour, the
/// accent while one is being dragged.
MultiSplitViewThemeData paneTheme(ColorScheme scheme) =>
    MultiSplitViewThemeData(
      dividerThickness: paneDividerWidth,
      dividerHandleBuffer: paneDividerGrab,
      dividerPainter: DividerPainters.background(
        color: scheme.outline,
        highlightedColor: scheme.primary,
      ),
    );

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
  validMove: Color(0x4014551E),
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

/// How tall one chapter row is. Small enough that a long study is one
/// screen, tall enough to hit.
const studyRowHeight = 34.0;
