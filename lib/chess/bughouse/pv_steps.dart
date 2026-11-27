import 'package:dartchess/dartchess.dart' show Side;

import 'table.dart';

/// One move of an engine line as a token: the board it is on, the move both
/// ways, what goes before it (`12.`, `12...` or nothing), the table after
/// it, and the moves that play the line up to and including it.
typedef PvStep = ({
  BoardNumber board,
  String uci,
  String san,
  String label,
  TablePosition after,
  List<(BoardNumber, String)> through,
});

/// [pv], moves of [board] as the engine prints them, played from
/// [position] as tokens, numbered as that board counts its moves, up to
/// [limit]. Stops at the first move that does not play, which is what a
/// line from another table looks like, or a drop of a piece the engine
/// expects the partner board to send.
List<PvStep> pvSteps(
  TablePosition position,
  BoardNumber board,
  List<String> pv, {
  int limit = 8,
}) {
  final steps = <PvStep>[];
  final through = <(BoardNumber, String)>[];
  var table = position;
  for (final uci in pv) {
    if (steps.length >= limit) break;
    final before = table.board(board);
    final played = table.play(board, uci);
    if (played == null) break;
    table = played.after;
    through.add((board, played.move.uci));
    steps.add((
      board: board,
      uci: played.move.uci,
      san: played.move.san,
      label: before.turn == Side.white
          ? '${before.fullmoves}.'
          : steps.isEmpty
          ? '${before.fullmoves}...'
          : '',
      after: table,
      through: List.unmodifiable(through),
    ));
  }
  return steps;
}

/// The moves to play for [steps] up to and including the one at [index],
/// in order.
List<(BoardNumber, String)> pvMovesTo(List<PvStep> steps, int index) =>
    index < 0 ? const [] : steps[index].through;
