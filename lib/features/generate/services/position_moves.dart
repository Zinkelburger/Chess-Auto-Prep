import 'package:dartchess/dartchess.dart';
import '../../../models/build_tree_node.dart';

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
}

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
  for (final entry in position.legalMoves.entries) {
    for (final to in entry.value.squares) {
      final promotion =
          position.board.pieceAt(entry.key)?.role == Role.pawn &&
          (to ~/ 8 == 0 || to ~/ 8 == 7);
      for (final role
          in promotion
              ? <Role?>[Role.queen, Role.rook, Role.bishop, Role.knight]
              : <Role?>[null]) {
        final move = NormalMove(from: entry.key, to: to, promotion: role);
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
  int? score(PositionMove row) => sortByChessDb
      ? row.chessDb?.stmCp
      : (row.expectedCp ?? row.evalCp) == null
      ? null
      : (row.expectedCp ?? row.evalCp)! *
            (position.turn == Side.white ? 1 : -1);
  rows.sort((a, b) {
    final x = score(a), y = score(b);
    if (x == null && y != null) return 1;
    if (y == null && x != null) return -1;
    final order = x != null && y != null ? y.compareTo(x) : 0;
    return order != 0 ? order : a.san.compareTo(b.san);
  });
  return rows;
}
