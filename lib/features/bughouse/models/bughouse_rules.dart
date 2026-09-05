import 'package:dartchess/dartchess.dart';

import 'bughouse_state.dart';

/// Hivemind's default terminal rule (Board::is_checkmate, engine-v0.1.0).
/// A checked seat can wait for a guaranteed partner capture that supplies a
/// legal blocking drop. A single-board Crazyhouse mate is not sufficient.
class BughouseRules {
  static BughouseBoard? losingBoard(BughouseState state, Side team) {
    final owned = [
      for (final which in BughouseBoard.values)
        if (state.board(which).turn ==
            (which == BughouseBoard.a ? team : team.opposite))
          which,
    ];
    for (final which in owned) {
      final board = state.board(which);
      if (board.isCheck &&
          !board.hasSomeLegalMoves &&
          !_partnerCanRescue(state, which, state.timeAdvantageFor(team))) {
        return which;
      }
    }
    // Hivemind treats no legal joint action as a loss, including stalemate.
    // A team with time advantage may wait only when it owns one board's turn.
    if (owned.isNotEmpty &&
        owned.every((which) => !state.board(which).hasSomeLegalMoves) &&
        (!state.timeAdvantageFor(team) || owned.length == 2)) {
      return owned.first;
    }
    return null;
  }

  static bool _partnerCanRescue(
    BughouseState state,
    BughouseBoard checked,
    bool timeAdvantage,
  ) {
    final partner = checked == BughouseBoard.a
        ? BughouseBoard.b
        : BughouseBoard.a;
    final checkedSide = state.board(checked).turn;
    final partnerTurn = state.board(partner).turn == checkedSide.opposite;
    if (!partnerTurn && !timeAdvantage) return false;

    bool usefulCapture(BughouseState candidate) {
      final before = candidate.board(checked);
      for (final move in moves(candidate.board(partner))) {
        final after = candidate.playMove(partner, move)!;
        // playMove handles en passant, promoted captures becoming pawns, and
        // castling not being a capture. Test the actual resulting legal drop:
        // this also rejects double, knight, contact and un-blockable checks.
        if (after.board(checked).pockets != before.pockets &&
            after.board(checked).hasSomeLegalMoves) {
          return true;
        }
      }
      return false;
    }

    if (partnerTurn) return usefulCapture(state);
    final replies = moves(state.board(partner)).toList();
    return replies.isNotEmpty &&
        replies.every((move) => usefulCapture(state.playMove(partner, move)!));
  }

  /// Legal moves including all promotions and reserve drops.
  static Iterable<Move> moves(Crazyhouse board) sync* {
    for (final entry in board.legalMoves.entries) {
      for (final to in entry.value.squares) {
        final promotion =
            board.board.pieceAt(entry.key)?.role == Role.pawn &&
            (to.rank == 0 || to.rank == 7);
        if (promotion) {
          for (final role in [
            Role.queen,
            Role.rook,
            Role.bishop,
            Role.knight,
          ]) {
            yield NormalMove(from: entry.key, to: to, promotion: role);
          }
        } else {
          yield NormalMove(from: entry.key, to: to);
        }
      }
    }
    for (final role in [
      Role.pawn,
      Role.knight,
      Role.bishop,
      Role.rook,
      Role.queen,
    ]) {
      if ((board.pockets?.of(board.turn, role) ?? 0) == 0) continue;
      for (final to in board.legalDrops.squares) {
        final move = DropMove(role: role, to: to);
        if (board.isLegal(move)) yield move;
      }
    }
  }
}
