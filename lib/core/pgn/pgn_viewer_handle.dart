/// The slice of the PGN viewer widget's control surface that core-layer
/// code is allowed to touch.
///
/// `PgnViewerController` (core) drives the board through this interface;
/// `PgnViewerWidgetController` (widgets) implements it against the live
/// widget state. Core must never import the widget layer directly — add
/// members here instead when the controller needs a new capability.
library;

import '../../models/move_tree.dart';
import 'solitaire_reveal.dart';
import 'solitaire_script.dart';

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

  /// Whether the reader currently carries user-added, unsaved analysis moves.
  bool get hasEphemeralMoves;

  /// Squares used to mark the most recent move(s) on the shared board.
  Set<String> get recentMoveSquares;

  /// Leave a sideline or inline preview and return to its mainline anchor.
  void returnToMainline();

  /// Jump to the position after [moveNumber] (1-based full moves), from the
  /// side-to-move perspective given by [isWhiteToPlay].
  void jumpToMove(int moveNumber, bool isWhiteToPlay);

  /// Navigate directly to a mainline position by half-move index (0-based
  /// number of moves played from the start).
  void goToMainLineIndex(int moveIndex);

  /// Navigate onto a sideline [node] branching from mainline ply [branchPly].
  void goToVariationNode(MoveNode node, int branchPly);

  /// Current 0-based mainline half-move index.
  int get mainLineIndex;

  /// Total number of mainline half-moves in the loaded game.
  int get mainLineLength;

  /// Mainline move SANs in order (for solitaire mode validation).
  List<String> get mainLineMoves;

  /// True when navigation is inside a variation / inline preview
  /// (off mainline).
  bool get inVariation;

  /// Id of the sideline node the cursor is on, or null on the mainline.
  int? get currentVariationNodeId;

  /// Whether the game carries saved (non-ephemeral) sidelines — the material
  /// a solitaire variations drill would cover.
  bool get hasSavedSidelines;

  /// Lay out a solitaire session over the loaded game. Null when no game is
  /// loaded. See `buildSolitaireScript`.
  SolitaireScript? buildSolitaireScript({
    required int fromMainlinePly,
    required bool includeVariations,
  });

  /// What solitaire lets the movetext show and navigation reach; null when
  /// no session is running. Applied immediately, so a navigation issued right
  /// after is judged against the new frontier.
  void setSolitaireReveal(SolitaireReveal? reveal);

  /// Record [san] as an ephemeral alternative at the current position without
  /// navigating into it (solitaire wrong attempts, shown live).
  void recordVariationMove(String san);

  /// Append solitaire guess notes to mainline move comments ([notes] keyed
  /// by 0-based move index), persisted through the movetext serializer.
  void addGuessAnnotations(Map<int, String> notes);

  /// Append solitaire guess notes to sideline moves ([notes] keyed by
  /// [MoveNode.id]).
  void addGuessNodeAnnotations(Map<int, String> notes);

  /// Persist the user's wrong solitaire guesses as real sideline variations,
  /// keyed by the 0-based mainline ply they were tried at, so the saved /
  /// exported game shows what the solver tried beside the actual move.
  void addGuessVariations(Map<int, List<String>> wrongByPly);

  /// Persist wrong guesses made inside a sideline as saved alternatives under
  /// the node they were played from ([wrongByParentId] keyed by
  /// [MoveNode.id]).
  void addGuessNodeVariations(Map<int, List<String>> wrongByParentId);
}
