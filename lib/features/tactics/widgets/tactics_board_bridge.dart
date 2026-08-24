import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../controllers/tactics_session_controller.dart';
import '../../../widgets/pgn_viewer_widget.dart';
import 'tactics_solution_navigator.dart';

/// The one place the tactics screen writes to the board and the PGN tab.
///
/// A tactics puzzle drives two views at once: the board on the left and the
/// PGN tree on the right. Keeping them in step was five methods on the
/// control panel's state, reached into by three of its mixins — so "what puts
/// a move on the board" had no single answer, and the pair could drift apart
/// depending on which path a move arrived through.
///
/// Everything played at the board lands in the PGN tree — the solution moves
/// you found, the wrong ones you tried, and the opponent's replies — as a
/// variation off the position you played it from. Switching to the PGN tab
/// then shows the line you just played instead of an untouched game you have
/// to re-enter by hand.
///
/// Board writes go through callbacks rather than a direct `AppState`
/// reference, matching [TacticsSolutionNavigator]: the owner reassigns
/// nothing, and this stays constructible in a test without a widget tree.
class TacticsBoardBridge {
  TacticsBoardBridge({
    required this.pgn,
    required this.solutionNav,
    required this.currentPosition,
    required this.setPosition,
    required this.setFlipped,
    required this.notifyGameChanged,
  });

  /// PGN viewer driven in parallel with the board.
  final PgnViewerWidgetController pgn;

  /// Solution-line cursor, reset whenever the loaded tactic changes.
  final TacticsSolutionNavigator solutionNav;

  /// The position currently on the board.
  final Position Function() currentPosition;

  final void Function(Position position) setPosition;
  final void Function(bool flipped) setFlipped;

  /// Tells the app a move was appended, so views watching the game repaint.
  final VoidCallback notifyGameChanged;

  /// Apply a move (or a whole position) the session produced.
  ///
  /// This replaced a `goForward()` on the PGN cursor, which assumed the
  /// solution *was* the PGN mainline. That stopped being true once puzzles
  /// started carrying their whole source game: the mainline there is the game
  /// as played, so stepping it forward walked onto the move the player
  /// actually blundered, not the one they had just found.
  ///
  /// Returns false when the update could not be applied (an unparseable move
  /// or FEN), so the caller can surface it.
  bool applyUpdate(TacticsBoardUpdate update) {
    try {
      if (update.applyMoveUci != null) {
        return playMove(update.applyMoveUci!);
      }
      if (update.setFen != null) {
        setPosition(Chess.fromSetup(Setup.parseFen(update.setFen!)));
        // The opponent's reply arrives as a FEN plus its SAN.
        if (update.san != null) pgn.addEphemeralMove(update.san!);
      }
      return true;
    } catch (e) {
      debugPrint('[TacticsBoardBridge] Board update failed: $e');
      return false;
    }
  }

  /// Play [moveUci] onto the board and record it in the PGN tab. Used for
  /// session moves and for free play in analysis mode alike — the two used to
  /// be separate copies of this.
  bool playMove(String moveUci) {
    try {
      final move = Move.parse(moveUci);
      if (move == null) return false;
      final (newPos, san) = currentPosition().makeSan(move);
      setPosition(newPos);
      notifyGameChanged();
      pgn.addEphemeralMove(san);
      return true;
    } catch (e) {
      debugPrint('[TacticsBoardBridge] Move failed: $e');
      return false;
    }
  }

  /// Put a tactic on the board with the solver's colour at the bottom.
  /// Returns the error message when [setup]'s FEN will not parse.
  String? showPosition(TacticsPositionSetup setup) {
    try {
      setPosition(Chess.fromSetup(Setup.parseFen(setup.fen)));
      setFlipped(setup.flipBoard);
      return null;
    } catch (e) {
      return 'Error loading position: $e';
    }
  }

  /// Back to the standard starting position — used when leaving a puzzle, so
  /// a stale tactic FEN is not left on the board.
  void resetToStart() {
    setPosition(Chess.initial);
    setFlipped(false);
  }

  /// The tactic on the board changed (loaded, reloaded after an edit, or
  /// reset): drop the solution-line cursor and the scratch analysis, and park
  /// the PGN viewer back on the tactic's own position.
  ///
  /// That position is a ply *inside* the source game, not its first move —
  /// this used to jump to mainline index 0, which is where the game starts,
  /// left over from when a tactic's PGN was its solution and nothing else.
  /// Falls back to the game start only when the tactic's position isn't in
  /// the loaded game (a viewer that hasn't mounted yet, or still holds the
  /// previous tactic).
  void resetToTactic(String? tacticFen) {
    solutionNav.reset();
    pgn.clearEphemeralMoves();
    if (tacticFen == null || !pgn.goToFen(tacticFen)) {
      pgn.goToMainLineIndex(0);
    }
  }
}
