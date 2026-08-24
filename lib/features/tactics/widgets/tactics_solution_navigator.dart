import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../models/tactics_position.dart';
import '../../../utils/chess_utils.dart' show playSanOrNullMove;
import '../../../widgets/pgn_viewer_widget.dart';

/// Owns the "Show Solution" navigation state for the tactics Tactic tab:
/// caching the solution line and walking the board / PGN cursor along it.
///
/// The solution is **not** the PGN mainline. The mainline is the tactic's
/// source game — the line where the player actually went wrong — so the
/// solution is shown the same way any other move played at the board is: as a
/// variation branching off the tactic's own ply. Navigating to solution move
/// `i` means "park on the mainline at the tactic's position, then replay
/// solution moves 0..i from there". Replaying is idempotent — the viewer
/// follows the mainline where the game happens to have played the same move
/// and reuses the existing variation node otherwise — so the same call both
/// seeds the line the first time and moves the cursor every time after.
///
/// Nothing here clears the PGN tree. The moves the player tried are theirs;
/// asking to see the solution is not a reason to throw them away.
class TacticsSolutionNavigator {
  TacticsSolutionNavigator({
    required this.pgn,
    required this.currentTactic,
    required this.solutionToSan,
    required this.setBoardPosition,
  });

  /// PGN viewer driven in parallel with the board.
  final PgnViewerWidgetController pgn;

  /// The tactic currently loaded, or `null` when none is active.
  final TacticsPosition? Function() currentTactic;

  /// Computes the SAN solution line for a tactic.
  final List<String> Function(TacticsPosition) solutionToSan;

  /// Writes a board position to the app/board state.
  final void Function(Position position) setBoardPosition;

  /// Current position in the solution line (-1 = at the tactic's own position,
  /// before any solution move).
  int _navIndex = -1;

  /// Cached SAN solution for [_cachedForFen] so we don't replay the line with
  /// dartchess on every rebuild.
  List<String> _sanCache = const [];

  /// FEN the cached solution belongs to.
  String? _cachedForFen;

  /// SAN moves of the solution line for the loaded tactic, computed on first
  /// use and cached until the tactic changes. Empty when nothing is loaded or
  /// the tactic has no replayable solution.
  List<String> get sanMoves {
    _ensureCached();
    return _sanCache;
  }

  /// The move index to highlight in the solution line, or `null` for none.
  int? get activeIndex => _navIndex >= 0 ? _navIndex : null;

  /// Reset all navigation state (call when loading a new position).
  void reset() {
    _navIndex = -1;
    _sanCache = const [];
    _cachedForFen = null;
  }

  /// Navigate the board and PGN viewer to a specific index in the solution
  /// (-1 = back at the tactic's own position).
  void navigateToIndex(int targetIndex) {
    final san = sanMoves;
    if (san.isEmpty) return;

    _navIndex = targetIndex.clamp(-1, san.length - 1);
    _syncPgnCursor(_navIndex);
    _navigateBoard(_navIndex);
  }

  /// Step one move forward. Returns `true` if the cursor moved.
  bool arrowForward() {
    final san = sanMoves;
    if (san.isEmpty || _navIndex >= san.length - 1) return false;
    navigateToIndex(_navIndex + 1);
    return true;
  }

  /// Step one move back. Returns `true` if the cursor moved.
  bool arrowBack() {
    if (_navIndex < 0 || sanMoves.isEmpty) return false;
    navigateToIndex(_navIndex - 1);
    return true;
  }

  /// Click handler: jump from wherever we are to [clickedIndex].
  void onMoveTapped(int clickedIndex) {
    if (clickedIndex < 0) return;
    navigateToIndex(clickedIndex);
  }

  /// Compute and cache the solution SANs for the loaded tactic.
  void _ensureCached() {
    final tactic = currentTactic();
    if (tactic == null) {
      if (_cachedForFen != null) reset();
      return;
    }
    if (_cachedForFen == tactic.fen) return;

    _cachedForFen = tactic.fen;
    _sanCache = solutionToSan(tactic);
    _navIndex = -1;
  }

  /// Put the PGN cursor on solution move [index] — on the tactic's own ply
  /// when [index] is negative. Best-effort: a viewer that isn't mounted, or
  /// one still showing a different game, leaves the tree untouched.
  void _syncPgnCursor(int index) {
    final tactic = currentTactic();
    if (tactic == null) return;
    if (!pgn.goToFen(tactic.fen)) return;
    for (int i = 0; i <= index && i < _sanCache.length; i++) {
      pgn.addEphemeralMove(_sanCache[i]);
    }
  }

  /// Set the board to the state after playing solution moves 0..[index]
  /// (or to the tactic start when index < 0).
  void _navigateBoard(int index) {
    final tactic = currentTactic();
    if (tactic == null) return;

    try {
      Position pos = Chess.fromSetup(Setup.parseFen(tactic.fen));
      final san = _sanCache;
      for (int i = 0; i <= index && i < san.length; i++) {
        final next = playSanOrNullMove(pos, san[i]);
        if (next == null) break;
        pos = next;
      }
      setBoardPosition(pos);
    } catch (e) {
      debugPrint('[TacticsSolutionNavigator] Board nav failed: $e');
    }
  }
}
