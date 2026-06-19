import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../models/tactics_position.dart';
import '../pgn_viewer_widget.dart';

/// Owns the "Show Solution" navigation state for the tactics Tactic tab:
/// seeding the solution line into the PGN viewer once per position and walking
/// the board / PGN cursor forward and back through it.
///
/// This used to live inline in TacticsControlPanel; it is extracted so the
/// trickiest part of the panel (board + PGN cursor kept in lock-step) is
/// isolated and unit-reviewable.
class TacticsSolutionNavigator {
  TacticsSolutionNavigator({
    required this.pgn,
    required this.currentTactic,
    required this.solutionToSan,
    required this.syncPgnToTactic,
    required this.setBoardPosition,
  });

  /// PGN viewer driven in parallel with the board.
  final PgnViewerWidgetController pgn;

  /// The tactic currently loaded, or `null` when none is active.
  final TacticsPosition? Function() currentTactic;

  /// Computes the SAN solution line for a tactic.
  final List<String> Function(TacticsPosition) solutionToSan;

  /// Re-highlights the PGN viewer at the tactic's start move.
  final VoidCallback syncPgnToTactic;

  /// Writes a board position to the app/board state.
  final void Function(Position position) setBoardPosition;

  /// Current arrow-key position in the solution line (-1 = at tactic start).
  int _navIndex = -1;

  /// Cached SAN solution for the current position so we don't recompute.
  List<String> _sanCache = const [];

  /// FEN for which the solution has already been seeded into the PGN.
  String? _seededForFen;

  /// SAN moves of the seeded solution line (empty until seeded).
  List<String> get sanMoves => _sanCache;

  /// The move index to highlight in the solution line, or `null` for none.
  int? get activeIndex => _navIndex >= 0 ? _navIndex : null;

  /// Reset all navigation state (call when loading a new position).
  void reset() {
    _navIndex = -1;
    _sanCache = const [];
    _seededForFen = null;
  }

  /// Seed the full solution as an ephemeral variation in the PGN viewer once
  /// per position. Subsequent toggles / arrow presses reuse it.
  void ensureSeeded() {
    final tactic = currentTactic();
    if (tactic == null) return;
    if (_seededForFen == tactic.fen) return;

    final san = solutionToSan(tactic);
    if (san.isEmpty) return;

    _sanCache = san;
    _seededForFen = tactic.fen;
    _navIndex = -1;

    syncPgnToTactic();
    for (final move in san) {
      pgn.addEphemeralMove(move);
    }
    for (int i = 0; i < san.length; i++) {
      pgn.goBack();
    }
  }

  /// Navigate the board and PGN viewer to a specific index in the solution.
  void navigateToIndex(int targetIndex) {
    final san = _sanCache;
    if (san.isEmpty) return;
    targetIndex = targetIndex.clamp(-1, san.length - 1);

    final delta = targetIndex - _navIndex;
    if (delta > 0) {
      for (int i = 0; i < delta; i++) {
        pgn.goForward();
      }
    } else if (delta < 0) {
      for (int i = 0; i < -delta; i++) {
        pgn.goBack();
      }
    }
    _navIndex = targetIndex;
    _navigateBoard(_navIndex);
  }

  /// Step one move forward. Returns `true` if the cursor moved.
  bool arrowForward() {
    final san = _sanCache;
    if (san.isEmpty) return false;
    if (_navIndex >= san.length - 1) return false;

    _navIndex++;
    _navigateBoard(_navIndex);
    pgn.goForward();
    return true;
  }

  /// Step one move back. Returns `true` if the cursor moved.
  bool arrowBack() {
    if (_navIndex < 0) return false;

    _navIndex--;
    _navigateBoard(_navIndex);
    pgn.goBack();
    return true;
  }

  /// Click handler: jump from wherever we are to [clickedIndex].
  void onMoveTapped(List<String> sanMoves, int clickedIndex) {
    if (sanMoves.isEmpty || clickedIndex < 0) return;

    ensureSeeded();

    final delta = clickedIndex - _navIndex;
    if (delta > 0) {
      for (int i = 0; i < delta; i++) {
        pgn.goForward();
      }
    } else if (delta < 0) {
      for (int i = 0; i < -delta; i++) {
        pgn.goBack();
      }
    }

    _navIndex = clickedIndex;
    _navigateBoard(clickedIndex);
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
        final move = pos.parseSan(san[i]);
        if (move == null) break;
        pos = pos.play(move);
      }
      setBoardPosition(pos);
    } catch (e) {
      debugPrint('[TacticsSolutionNavigator] Board nav failed: $e');
    }
  }
}
