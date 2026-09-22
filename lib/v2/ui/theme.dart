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
  static const xl = 24.0;
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

/// The line under a chapter's name that says where it starts, and how its
/// moves are set: mono at the small size.
const outlineRootHeight = 16.0;
const outlineRootText = TextStyle(fontFamily: 'SourceCodePro', fontSize: 12);

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

/// Moves, FENs and evaluations share one monospace style.
const monoText = TextStyle(fontFamily: 'SourceCodePro', fontSize: 13);

/// The reading column's own two sizes, the old app's reading pane: moves in
/// mono at 16 with its line height, prose upright in the text face. A
/// comment is read, so it gets a book's measure rather than the column's
/// width.
const readingMoveText = TextStyle(
  fontFamily: 'SourceCodePro',
  fontSize: 16,
  height: 1.7,
);
const readingProseText = TextStyle(fontSize: 16, height: 1.55);

/// What a move's glyph means, beside the move under the board: the prose
/// face a step down, so it reads as a gloss rather than a second move.
const readingGlossText = TextStyle(fontSize: 14, height: 1.55);
const proseMaxWidth = 640.0;

/// The room around one move in the moves: enough that the eye parts the
/// tokens, little enough that a line still reads as a line.
const moveTokenPadding = EdgeInsets.symmetric(horizontal: 4, vertical: 1);

/// The reading column is a card, the old app's: its corners, and the room
/// between its edge and the words.
const readingCardRadius = 8.0;
const readingCardInset = Space.xl;

/// A diagram drawn in a comment: a position the author put there to be
/// looked at, so bigger than a hover board and smaller than the board.
const diagramSize = 160.0;

/// The least room under the board worth showing the move's note in: its
/// move row and two lines of prose.
const moveNoteMinHeight = 120.0;

/// How far a variation block sits in from the line it interrupts.
const variationIndent = 14.0;

/// The row of first / back / forward / end buttons under the moves.
const navRowHeight = 36.0;

/// The engine bar, as the old app laid it out: a row this tall for the
/// switch and the status, then one row per line, each with a gutter this
/// wide for the score and the moves after it. The score is read there and
/// nowhere larger.
const engineBarHeight = 32.0;
const engineRowHeight = 28.0;
const engineScoreWidth = 54.0;

/// The tab strip at the top of a pane whose content the user can switch —
/// Moves and Replies in the reading card — and the line under the chosen
/// tab. The old viewer's tabs were this: words in a row, one underlined.
const paneTabHeight = 32.0;
const paneTabUnderline = 2.0;

/// The Replies table: a row per move the model expects, as tall as an
/// engine row, with its share in a gutter as wide as an engine score.
const replyRowHeight = engineRowHeight;
const replyShareWidth = engineScoreWidth;

/// How many rows a line opens out to when its chevron is pressed.
const engineExpandedRows = 6;

/// How wide the board that floats under a hovered engine move is, and how
/// far under the move it sits.
const previewBoardSize = 200.0;
const previewBoardGap = 6.0;

/// The pointer rests on a move this long before its board appears, so
/// sweeping across a line does not flash every position in it.
const previewDelay = Duration(milliseconds: 80);

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
  /// growing above a finger. [coordinates] is the user's setting.
  ChessboardSettings settings({required bool coordinates}) =>
      ChessboardSettings(
        colorScheme: _colors,
        pieceAssets: PieceSet.cburnettAssets,
        animationDuration: animation,
        showValidMoves: showValidMoves,
        enableCoordinates: coordinates,
        enablePremoves: false,
        dragFeedbackScale: 1,
        dragFeedbackOffset: Offset.zero,
      );

  /// The small board that floats under a hovered engine move: the same
  /// colours and pieces, no animation because it shows one position.
  StaticChessboardSettings get previewSettings => StaticChessboardSettings(
    colorScheme: _colors,
    pieceAssets: PieceSet.cburnettAssets,
    animationDuration: Duration.zero,
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

/// Narrower than this and a list is unreadable, a board unplayable, a
/// paragraph a ribbon.
const paneMinWidth = 180.0;
const boardPaneMinWidth = 320.0;
const readingPaneMinWidth = 300.0;

/// One of the six glyph buttons in the edit strip.
const glyphButtonWidth = 36.0;
const glyphButtonHeight = 30.0;

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

/// The reading card, near black under the moves: the old app's, and what
/// made its reading pane look the way it did.
const _reading = Color(0xFF0C0C0E);
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
    surfaceContainerLowest: _reading,
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

/// The settings dialog: small and fixed, so it never grows into a page.
/// A list of places on the left, at most a handful of rows on the right,
/// each one line tall. Tall enough for six places; a seventh means a place
/// has to go, not the dialog grow.
const settingsDialogWidth = 640.0;
const settingsDialogHeight = 340.0;
const settingsListWidth = 180.0;
const settingRowHeight = 36.0;
const settingNumberWidth = 64.0;
const settingSecretWidth = 200.0;

/// How tall one row of a list is — a study, its chapters, the games of a
/// file. Small enough that a long list is one screen, tall enough to hit.
const listRowHeight = 34.0;

/// How wide the number in front of a game in a list is: room for four
/// digits, which a downloaded collection needs.
const gameOrdinalWidth = 40.0;

/// How wide the typeable game number under the board is: four digits.
const gameNumberWidth = 52.0;

/// The Explorer tab's table: the move gutter, the games gutter, the header
/// row over them and the menu the gear opens. The result bar takes what is
/// left of the row.
const explorerMoveWidth = 88.0;
const explorerGamesWidth = 96.0;
const explorerHeaderHeight = 22.0;
const explorerMenuWidth = 300.0;

/// The three parts of a result bar: White's wins are light, draws are the
/// muted grey, Black's wins are the near-black of the reading card, so the
/// bar reads like a chessboard's two colours with a grey between.
const resultBarWhite = Color(0xFFE6E6E8);
const resultBarDraw = Color(0xFF6E6E74);
const resultBarBlack = Color(0xFF2A2A2E);

/// A part of the bar narrower than this share of the row carries no
/// number: the number would not fit.
const resultBarLabelFrom = 0.14;
