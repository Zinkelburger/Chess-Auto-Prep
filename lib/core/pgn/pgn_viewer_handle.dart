/// The slice of the PGN viewer widget's control surface that core-layer
/// code is allowed to touch.
///
/// `PgnViewerController` (core) drives the board through this interface;
/// `PgnViewerWidgetController` (widgets) implements it against the live
/// widget state. Core must never import the widget layer directly — add
/// members here instead when the controller needs a new capability.
abstract interface class PgnViewerHandle {
  /// Step one mainline/variation move back.
  void goBack();

  /// Step one mainline/variation move forward.
  void goForward();

  /// FEN of the position currently shown, or null when nothing is loaded.
  String? get currentFen;

  /// Play [san] as an ephemeral analysis move at the current position.
  void addEphemeralMove(String san);

  /// Drop all ephemeral analysis lines and return to the game moves.
  void clearEphemeralMoves();

  /// Jump to the position after [moveNumber] (1-based full moves), from the
  /// side-to-move perspective given by [isWhiteToPlay].
  void jumpToMove(int moveNumber, bool isWhiteToPlay);

  /// Navigate directly to a mainline position by half-move index (0-based
  /// number of moves played from the start).
  void goToMainLineIndex(int moveIndex);

  /// Current 0-based mainline half-move index.
  int get mainLineIndex;

  /// Total number of mainline half-moves in the loaded game.
  int get mainLineLength;

  /// Mainline move SANs in order (for solitaire mode validation).
  List<String> get mainLineMoves;

  /// True when navigation is inside a variation / inline preview
  /// (off mainline).
  bool get inVariation;

  /// Record [san] as an ephemeral variation at the current mainline position
  /// without navigating into it (solitaire wrong attempts, shown live).
  void recordVariationMove(String san);

  /// Append solitaire guess notes to mainline move comments ([notes] keyed
  /// by 0-based move index), persisted through the movetext serializer.
  void addGuessAnnotations(Map<int, String> notes);

  /// Persist the user's wrong solitaire guesses as real sideline variations,
  /// keyed by the 0-based mainline ply they were tried at, so the saved /
  /// exported game shows what the solver tried beside the actual move.
  void addGuessVariations(Map<int, List<String>> wrongByPly);
}
