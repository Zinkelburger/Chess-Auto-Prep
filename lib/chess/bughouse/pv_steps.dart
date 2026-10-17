import 'package:dartchess/dartchess.dart' show Side;

import 'hivemind.dart';
import 'table.dart';

/// One move of an engine line as a token: the board it is on, the move both
/// ways, what goes before it (`12.`, `12...`, or the seat's letter), the
/// table after it, which of the line's joint actions it belongs to, and
/// the moves that play the line up to and including it. [uci] is null for
/// `sit`, a joint action in which nothing moves.
typedef PvStep = ({
  BoardNumber board,
  String? uci,
  String san,
  String label,
  TablePosition after,
  int joint,
  List<(BoardNumber, String)> through,
});

/// [pv] from [position] as tokens. With [board], that board's moves alone,
/// numbered as it counts them — the other board's moves are played but not
/// shown — up to [limit] moves; a step plays that board's moves only,
/// unless [throughBoth], when it plays the other board's before it too.
/// Without [board], every move of both boards, seat-lettered, up to [limit]
/// joint actions. Stops at the first move that does not play, which is what
/// a line from another table looks like.
List<PvStep> pvSteps(
  TablePosition position,
  List<JointMove> pv, {
  BoardNumber? board,
  bool throughBoth = false,
  int limit = 8,
}) {
  final steps = <PvStep>[];
  final through = <(BoardNumber, String)>[];
  var table = position;
  for (final (joint, action) in pv.indexed) {
    if (board == null && joint >= limit) break;
    var moved = false;
    for (final on in BoardNumber.values) {
      final uci = action.on(on);
      if (uci == null) continue;
      final before = table.board(on);
      final played = table.play(on, uci);
      if (played == null) return steps;
      table = played.after;
      moved = true;
      if (board == null || on == board || throughBoth) {
        through.add((on, played.move.uci));
      }
      if (board != null && on != board) continue;
      final shown = steps.length;
      steps.add((
        board: on,
        uci: played.move.uci,
        san: played.move.san,
        label: board == null
            ? Seat.of(on, before.turn).letter
            : before.turn == Side.white
            ? '${before.fullmoves}.'
            : shown == 0
            ? '${before.fullmoves}...'
            : '',
        after: table,
        joint: joint,
        through: List.unmodifiable(through),
      ));
      if (board != null && steps.length >= limit) return steps;
    }
    if (!moved && board == null) {
      steps.add((
        board: BoardNumber.one,
        uci: null,
        san: 'sit',
        label: '',
        after: table,
        joint: joint,
        through: List.unmodifiable(through),
      ));
    }
  }
  return steps;
}

/// The moves to play for [steps] up to and including the one at [index],
/// in order; a `sit` plays nothing more.
List<(BoardNumber, String)> pvMovesTo(List<PvStep> steps, int index) =>
    index < 0 ? const [] : steps[index].through;
