import 'package:dartchess/dartchess.dart';

import '../../../chess_core/generation/build_tree_node.dart';
import '../../../services/eval/db_move_list.dart';
import '../../../services/generation/fen_map.dart';
import '../../../utils/chess_utils.dart';
import '../../../utils/ease_utils.dart';

/// A legal move joined with independently stored analysis of its position.
class PositionMove {
  const PositionMove({
    required this.san,
    required this.uci,
    this.evalCp,
    this.expectedCp,
    this.chessDb,
    this.pvSan = const [],
  });
  final String san;
  final String uci;

  /// Scores use White's perspective, consistently across both sources.
  final int? evalCp;
  final int? expectedCp;
  final DbMove? chessDb;
  final List<String> pvSan;

  /// The stored score for the row, White's perspective: expectimax when the
  /// position has one, else the engine eval.
  int? get storedCp => expectedCp ?? evalCp;
}

/// Promotion pieces in the order the rows list them.
const List<Role> _promotionRoles = [
  Role.queen,
  Role.rook,
  Role.bishop,
  Role.knight,
];

/// Every legal move in [fen] joined with what the tree ([database] and/or
/// [liveNodeAt]) and [chessDb] know about the position it leads to, sorted
/// best first for the side to move (rows without a score last, then by SAN).
List<PositionMove> positionMoves(
  String fen, {
  FenMap? database,
  BuildTreeNode? Function(String fen)? liveNodeAt,
  bool playAsWhite = true,
  DbMoveList chessDb = DbMoveList.empty,
  bool sortByChessDb = false,
}) {
  final position = tryParseFen(fen);
  if (position == null) return const [];
  final parent = liveNodeAt?.call(fen) ?? database?.getCanonical(fen);
  final rows = <PositionMove>[];
  for (final MapEntry(key: from, value: targets)
      in position.legalMoves.entries) {
    for (final to in targets.squares) {
      final promotion =
          position.board.pieceAt(from)?.role == Role.pawn &&
          (to.rank == Rank.first || to.rank == Rank.eighth);
      for (final role in promotion ? _promotionRoles : const <Role?>[null]) {
        final move = NormalMove(from: from, to: to, promotion: role);
        final (after, san) = position.makeSan(move);
        final uci = moveToStandardUci(position, move);
        final child = parent?.children
            .where((n) => n.moveSan == san)
            .firstOrNull;
        // Also find standalone probes: their root may not be linked to parent.
        final node =
            liveNodeAt?.call(after.fen) ??
            database?.getCanonical(after.fen) ??
            child;
        final expected = node != null && node.hasExpectimax
            ? expectedCpFromWinProb(node.expectimaxValue) *
                  (playAsWhite ? 1 : -1)
            : null;
        rows.add(
          PositionMove(
            san: san,
            uci: uci,
            evalCp: node != null && node.hasEngineEval
                ? node.evalForUs(true)
                : null,
            expectedCp: expected,
            pvSan: node == null
                ? const []
                : uciPvToSan(node.fen, node.enginePv, maxMoves: 24),
            chessDb: chessDb.moves
                .where((m) => m.uci == uci || m.san == san)
                .firstOrNull,
          ),
        );
      }
    }
  }
  // Side-to-move perspective, so "higher is better" holds for both colours.
  final moverSign = position.turn == Side.white ? 1 : -1;
  int? score(PositionMove row) => sortByChessDb
      ? row.chessDb?.stmCp
      : switch (row.storedCp) {
          final cp? => cp * moverSign,
          null => null,
        };
  rows.sort((a, b) {
    final x = score(a), y = score(b);
    final order = switch ((x, y)) {
      (null, null) => 0,
      (null, _) => 1,
      (_, null) => -1,
      (final x?, final y?) => y.compareTo(x),
    };
    return order != 0 ? order : a.san.compareTo(b.san);
  });
  return rows;
}
