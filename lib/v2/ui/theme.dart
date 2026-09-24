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

/// The widest a typeable choice field's suggestions grow.
const choiceFieldMenuWidth = 280.0;

/// How wide a filter rule's rule box is, beside a field box that takes the
/// rest of the line.
const filterRuleWidth = 96.0;

/// The narrowest a filter rule's first line holds both its field and its
/// rule box; under it the rule goes on a line of its own.
const filterRuleLineWidth = 260.0;

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
/// Moves, Replies, Search in the reading card: the tabs share its width,
/// each one a target as big as a button, the chosen one filled. The line
/// is what shows where a dragged tab will land.
const paneTabHeight = 40.0;
const paneTabInset = 4.0;
const paneTabMinWidth = 84.0;
const paneTabRadius = 6.0;
const paneTabUnderline = 2.0;

/// The Search tab: its number fields, the table's header and rows, and
/// the columns for how often a reply is played and for the two values.
const searchEloWidth = 84.0;
const searchDepthWidth = 64.0;
const searchHeaderHeight = 24.0;
const searchRowHeight = 32.0;
const searchShareWidth = 64.0;
const searchValueWidth = 88.0;

/// The Replies table: a row per move the model expects, as tall as an
/// engine row, with its share in a gutter as wide as an engine score.
const replyRowHeight = engineRowHeight;
const repliesStatusHeight = 44.0;
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

/// How the workspace is first shared between the board and the card beside
/// it: two parts to three, the card the wider. The split view reads a flex
/// pane's `min` as a flex too, not as pixels, so the shares are written in
/// the same units as [boardPaneMinWidth] and [readingPaneMinWidth] and the
/// minimums keep the proportion they were meant to have.
const boardShare = 400.0;
const cardShare = 600.0;
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

/// The accent a step darker, under white words: the filled button, the one
/// strongest action on a screen. White on [_accent] is 3.2:1 and reads as
/// faded; on this it is 5.3:1 and the button still stands off the card.
const _accentFill = Color(0xFF3A6EA8);

/// A second action: a dark blue-grey button with pale words, 9.6:1, so it
/// reads as a button and not as a disabled chip, without competing with
/// the filled one.
const _tonal = Color(0xFF26354A);
const _onTonal = Color(0xFFD6E4F5);

/// A control that cannot be used now: legible at 4:1, plainly not on.
const _disabledFill = Color(0xFF2C2C30);
const _disabledText = Color(0xFF8A8A90);
const _buttonOutline = Color(0xFF5A5A60);

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
    secondaryContainer: _tonal,
    onSecondaryContainer: _onTonal,
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
    filledButtonTheme: FilledButtonThemeData(style: _filled),
    outlinedButtonTheme: OutlinedButtonThemeData(style: _outlined),
    textButtonTheme: TextButtonThemeData(style: _textButton),
    // The snackbar is pale, and the default action colour is paler still.
    extensions: const [_board],
  );
}

/// Button words are medium weight at the body size: thin words in a thin
/// outline are what made the old buttons look switched off.
const _buttonLabel = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);

/// Filled: white on the darker accent.
final _filled = ButtonStyle(
  textStyle: const WidgetStatePropertyAll(_buttonLabel),
  backgroundColor: _whenOn(_accentFill, _disabledFill),
  foregroundColor: _whenOn(Colors.white, _disabledText),
);

/// A second action beside a filled one — Show solution beside Next: the
/// dark blue-grey fill with pale words. Pass it to a [FilledButton]; the
/// theme's filled style is the strong one.
final secondaryButtonStyle = ButtonStyle(
  backgroundColor: _whenOn(_tonal, _disabledFill),
  foregroundColor: _whenOn(_onTonal, _disabledText),
);

WidgetStateProperty<Color> _whenOn(Color on, Color off) =>
    WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled) ? off : on,
    );

/// Outlined: near-white words in a grey line that can be seen.
final _outlined = ButtonStyle(
  textStyle: const WidgetStatePropertyAll(_buttonLabel),
  foregroundColor: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.disabled) ? _disabledText : _text,
  ),
  side: WidgetStateProperty.resolveWith(
    (states) => BorderSide(
      color: states.contains(WidgetState.disabled)
          ? _disabledFill
          : _buttonOutline,
    ),
  ),
);

/// Text buttons stay in the accent, at the medium weight.
final _textButton = ButtonStyle(
  textStyle: const WidgetStatePropertyAll(_buttonLabel),
  foregroundColor: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.disabled) ? _disabledText : null,
  ),
);

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

/// A row of the trainer's lists: a name over a line of moves.
const trainRowHeight = 44.0;

/// A row of the puzzle list: the move and its result on one line, the
/// opponent and the date under it.
const puzzleRowHeight = 44.0;

/// The box the Tactics filters take a number of days in.
const dayCountWidth = 44.0;

/// The Puzzle tab's feedback lines and its star row keep these heights
/// whether they hold anything or not, so the buttons under them never move.
const feedbackLineHeight = 40.0;
const starRowHeight = 36.0;

/// How wide the number in front of a game in a list is: room for four
/// digits, which a downloaded collection needs.
const gameOrdinalWidth = 40.0;

/// How wide the typeable game number under the board is: four digits.
const gameNumberWidth = 52.0;

/// The typed-move field under the board: room for `exd8=Q+` and no more,
/// so the game counter beside it keeps its place on the narrowest board.
const moveFieldWidth = 96.0;

/// The Explorer tab's table: the move gutter, the games gutter, the header
/// row over them, and the height of one filter chip. The result bar sits after the
/// games, no wider than [explorerBarMaxWidth]: a bar across the whole card
/// is a stripe the eye reads before the moves.
const explorerMoveWidth = 64.0;
const explorerGamesWidth = 96.0;

/// The widest the end of the Explorer tab's source row grows — the
/// filters' summary or what a source on this machine is over — so the
/// databases keep the rest of the row.
const explorerTrailingMaxWidth = 220.0;
const explorerBarMaxWidth = 220.0;
const explorerBarHeight = 16.0;
const explorerHeaderHeight = 22.0;
const explorerChipHeight = 32.0;

/// The explorer Book's table: the lines gutter and the files column; the move
/// gutter is the explorer's, and how the line goes on takes the rest.
const treeLinesWidth = 56.0;
const treeFilesWidth = 140.0;

/// The three parts of a result bar, kept dimmer than the moves beside them:
/// White's wins a soft grey, draws a mid grey, Black's wins a step above
/// the reading card. Each part's number is in its own ink, quiet on all
/// three.
const resultBarWhite = Color(0xFFA4A4AA);
const resultBarWhiteInk = Color(0xFF1B1B1D);
const resultBarDraw = Color(0xFF55555B);
const resultBarDrawInk = Color(0xFFC4C4C8);
const resultBarBlack = Color(0xFF2A2A2E);
const resultBarBlackInk = Color(0xFF9A9AA0);

/// The number in a bar part: mono at the small size.
const resultBarText = TextStyle(fontFamily: 'SourceCodePro', fontSize: 12);

/// The Bughouse lab, laid out as the BughouseDB page: two boards side by
/// side, each as large as the window leaves room for between these two.
const labBoardMin = 200.0;
const labBoardMax = 480.0;

/// What the left column needs under the boards besides the seat rows: the
/// move list, navigation and archive. Expanded setup can scroll.
const labBoardChrome = 250.0;

/// The narrowest the right-hand panel may become before the boards shrink.
const labPanelMinWidth = 440.0;
const labPanelMaxWidth = 480.0;

/// The gap between the two boards, and between the boards and the panel.
const labBoardGap = 20.0;
const labColumnGap = 16.0;

/// A seat row beside a board: the turn dot, `Player A`, then the reserve
/// tray, its pieces as large as the board's squares, and the room around
/// them.
const labSeatPadding = 8.0;
const labTurnDot = 11.0;

/// Each board's own move list: a few moves tall, then it scrolls.
const labMoveListHeight = 48.0;
const labMoveRowHeight = 22.0;
const labMoveNumberWidth = 34.0;

/// The label column of the right panel's rows (`Time`).
const labLabelWidth = 64.0;

/// The FICS archive under each board: its heading and this many
/// continuations.
const labArchiveRows = 6;
const labArchiveGamesWidth = 80.0;

/// A row of a board's move table, and its score column.
const labTableRowHeight = 28.0;
const labScoreWidth = 60.0;

/// The status line over the tables, shown when there is a problem.
const labStatusHeight = 30.0;

/// The setup boxes' text: FENs and reserves in mono at the small size.
const labSetupText = TextStyle(fontFamily: 'SourceCodePro', fontSize: 12);

/// The turn dot of the seat to move: White's plain white, Black's black in
/// a grey ring so it shows on the dark panel. A fact, not decoration.
const labWhiteDot = Color(0xFFFFFFFF);
const labBlackDot = Color(0xFF000000);
const labBlackDotRing = Color(0xFF5A5A60);

/// A move pointed at in a table, or the squares a picked-up reserve piece
/// can be dropped on: Lichess's pale blue.
const labHintColor = Color(0x99003088);

/// The Books mode: the list of books, a repertoire's or a chapter's row,
/// and how far a chapter sits in from its repertoire.
const booksListWidth = 260.0;
const bookRowHeight = 36.0;
const bookChapterIndent = 28.0;
