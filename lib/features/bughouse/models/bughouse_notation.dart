/// Reading engine output against a two-board position.
///
/// The engine speaks board-prefixed UCI and joint actions — `(g1f3,pass)` —
/// which is not a line anyone can follow. Everything here turns that into what
/// a reader wants: SAN on the board it was played on, the seat that plays it,
/// a principal variation split across the two seats that carry it, and the
/// arrows and drop markers that draw it on the boards.
library;

import 'package:dartchess/dartchess.dart';

import '../../../models/board_annotation.dart';
import '../../../utils/chess_utils.dart' show roleChar;
import 'bughouse_state.dart';

/// Parses the engine's UCI on one board, including `P@e5` drops.
///
/// Hivemind spells its promotions out (`b7a8q`), so the bare-`e7e8` reading
/// has never fired against the real engine — but a bare move is legal UCI
/// elsewhere, and a queen is the convention. Shared by the analysis pane, the
/// match runner and the replay so a live game and a replayed one agree about
/// what a move string meant.
Move? parseEngineUci(Crazyhouse position, String uci) {
  final move = Move.parse(uci);
  if (move == null) return null;
  if (move is NormalMove && move.promotion == null) {
    final piece = position.board.pieceAt(move.from);
    final lastRank = piece?.color == Side.white ? 7 : 0;
    if (piece?.role == Role.pawn && move.to.rank == lastRank) {
      return NormalMove(from: move.from, to: move.to, promotion: Role.queen);
    }
  }
  return move;
}

/// One seat's part of a joint action: who plays it, a tooltip naming them,
/// the move in SAN, and the board it lands on.
typedef BughouseSeatMove = ({
  String who,
  String hint,
  String move,
  BughouseBoard board,
});

/// One ply of a principal variation, as the two seats that play it.
///
/// A bughouse ply is a decision about two boards at once, so it has two cells,
/// not one move. Either may be absent: a seat that is not on move has nothing
/// to decide there, which is a blank rather than a `sit`.
class BughousePvStep {
  const BughousePvStep({
    required this.action,
    required this.before,
    required this.team,
    required this.seats,
    required this.onA,
    required this.onB,
  });

  /// The joint action itself, as the engine spelled it — what gets played
  /// when the step is clicked.
  final BughouseJointMove action;

  /// The two-board position this ply is played from: the one on screen for
  /// the first step, and the line's own positions after that. It is what the
  /// boards draw the ply against when it is hovered.
  final BughouseState before;

  /// The team that plays this ply — it alternates down the variation.
  final Side team;

  /// That team's two seats, `A + B` or `C + D`, so a continuation row says
  /// whose move it is without the reader counting plies.
  final String seats;

  /// SAN for the seat on board 1 — `Nf3`, `P@e5`, or `sit` for a deliberate
  /// pass. Null when that seat had no move to make.
  final String? onA;

  /// The same for board 2.
  final String? onB;

  String? on(BughouseBoard which) => which == BughouseBoard.a ? onA : onB;

  /// The seat letter that plays [which] on this ply: A or B on board 1, C or
  /// D on board 2, by which team is acting.
  String seatOn(BughouseBoard which, BughouseState state) =>
      state.seatLetter(which, which == BughouseBoard.a ? team : team.opposite);
}

/// Joint actions read against one position.
///
/// Pure: every method answers from [state] alone, so a stale action — one
/// from a search the position has since moved past — reads as the raw UCI or
/// as nothing, never as a move on the wrong board.
class BughouseNotation {
  const BughouseNotation(this.state);

  /// The position every action is read against.
  final BughouseState state;

  /// [half]'s move on [which] when it is a real, legal move here; null for a
  /// pass or anything that will not play on this position.
  Move? _legalMove(BughouseBoard which, BughouseHalfMove half) {
    final uci = half.uci;
    if (half.isPass || uci == null) return null;
    final move = parseEngineUci(state.board(which), uci);
    if (move == null || !state.board(which).isLegal(move)) return null;
    return move;
  }

  /// The position after [action], as far as its halves will play.
  BughouseState preview(BughouseJointMove action) {
    var next = state;
    for (final which in BughouseBoard.values) {
      final move = _legalMove(which, action.half(which));
      if (move != null) next = next.playMove(which, move) ?? next;
    }
    return next;
  }

  /// One half of a joint action as board shapes: an arrow for a move, and for
  /// a drop a ring on the landing square badged with the piece, because a drop
  /// comes from a reserve and so has nowhere to draw an arrow from.
  List<BoardAnnotation> annotate(
    BughouseBoard which,
    BughouseJointMove? action,
    AnnotationBrush brush,
  ) {
    if (action == null) return const [];
    final move = _legalMove(which, action.half(which));
    if (move == null) return const [];
    return switch (move) {
      NormalMove(:final from, :final to) => [
        BoardAnnotation(orig: from.name, dest: to.name, brush: brush),
      ],
      DropMove(:final to, :final role) => [
        BoardAnnotation(
          orig: to.name,
          brush: brush,
          label: roleChar(role).toUpperCase(),
        ),
      ],
    };
  }

  /// One half of a joint action as SAN — `Nxf7+` rather than `f5f7`, and
  /// `sit` for a pass. Falls back to the raw UCI when the move will not parse
  /// here, which is what a stale result looks like.
  String describeHalf(BughouseBoard which, BughouseJointMove move) {
    final half = move.half(which);
    final uci = half.uci;
    if (half.isPass || uci == null) return 'sit';
    final parsed = _legalMove(which, half);
    return parsed == null ? uci : state.board(which).makeSan(parsed).$2;
  }

  /// A joint action broken into the people who make it, dropping the halves
  /// that were never a decision.
  ///
  /// A joint action always carries two halves, so the board where the searched
  /// team is not on move comes back as a pass every single time. Printing that
  /// as `B sit` says the team chose to wait when it simply had nothing to move
  /// there, so that half is left out. A pass on a board the team *is* on move
  /// on is a real decision and still reads `sit`.
  ///
  /// [team] is the colour on board A of the team that was searched, which is
  /// what decides whether a row is you, your partner, or one of the two people
  /// playing against you.
  List<BughouseSeatMove> describeSeats(
    BughouseJointMove action, {
    required Side team,
  }) {
    final rows = <BughouseSeatMove>[];
    for (final which in BughouseBoard.values) {
      final mover = which == BughouseBoard.a ? team : team.opposite;
      final half = action.half(which);
      final passing = half.isPass || half.uci == null;
      if (passing && state.board(which).turn != mover) continue;
      rows.add((
        who: state.seatLetter(which, mover),
        hint: state.seatDescription(which, mover),
        move: describeHalf(which, action),
        board: which,
      ));
    }
    return rows;
  }

  /// The same thing on one line, for a shortlist row or a table cell.
  String describeJoint(BughouseJointMove action, {required Side team}) {
    final rows = describeSeats(action, team: team);
    return rows.isEmpty
        ? '—'
        : rows.map((r) => '${r.who} ${r.move}').join('   ·   ');
  }

  /// Just the moves, in board order — for a row that sits under one already
  /// naming the seats, where repeating the names costs a line wrap and buys
  /// nothing.
  String describeMoves(BughouseJointMove action, {required Side team}) {
    final rows = describeSeats(action, team: team);
    return rows.isEmpty ? '—' : rows.map((r) => r.move).join('  ·  ');
  }

  /// The engine's whole line in SAN, ply by ply, split across the two seats
  /// that carry it.
  ///
  /// The `pv` is a list of *joint* actions, so printed raw it reads
  /// `(g1f3,pass) (b8c6,e2e4)`. Replaying it gives SAN, and splitting each ply
  /// by board gives the two columns the panel lays it out in: our seats are A
  /// on board 1 and C on board 2, theirs B and D.
  ///
  /// Both halves of a ply are resolved against the position *before* either is
  /// applied — the engine decided them together, so a piece captured on one
  /// board must not pay for a drop on the other in the same ply. Replay stops
  /// at the first half that will not play, which is what a line from a
  /// superseded position looks like.
  ///
  /// Which team acts is read off the position for each ply rather than fixed
  /// to [team], because a variation alternates: the searched team moves, then
  /// the other two answer. That is what decides whether a `pass` in a ply is a
  /// deliberate sit or simply the half of a joint action nobody owned, and it
  /// is why each step carries the seats that played it.
  List<BughousePvStep> describePv(
    BughouseInfo info, {
    required Side team,
    int maxPlies = 6,
  }) {
    var position = state;
    final steps = <BughousePvStep>[];
    for (final action in info.pv) {
      if (steps.length >= maxPlies) break;
      // An all-pass ply names no team, so it stays with whoever moved last —
      // or, at the head of the line, with the team that was searched.
      final acting =
          _actingTeam(position, action) ??
          (steps.isEmpty ? team : steps.last.team);
      final step = _replayPly(position, action, acting);
      if (step == null) break;
      steps.add(
        BughousePvStep(
          action: action,
          before: position,
          team: acting,
          seats: state.teamLetters(acting),
          onA: step.sans[BughouseBoard.a],
          onB: step.sans[BughouseBoard.b],
        ),
      );
      position = step.after;
    }
    return steps;
  }

  /// The team that plays [action] from [position]: a real half is played by
  /// whoever is on turn on that board, and that names the team for the whole
  /// ply — both halves of a joint action belong to the same team. Null for an
  /// all-pass ply.
  static Side? _actingTeam(BughouseState position, BughouseJointMove action) {
    for (final which in BughouseBoard.values) {
      final half = action.half(which);
      if (half.isPass || half.uci == null) continue;
      final turn = position.board(which).turn;
      return which == BughouseBoard.a ? turn : turn.opposite;
    }
    return null;
  }

  /// One ply of a variation played out from [position]: the SAN each seat
  /// gets, and the position afterwards. Null when a half will not play, or
  /// when nobody had anything to say.
  static ({Map<BughouseBoard, String> sans, BughouseState after})? _replayPly(
    BughouseState position,
    BughouseJointMove action,
    Side acting,
  ) {
    final sans = <BughouseBoard, String>{};
    var next = position;
    for (final which in BughouseBoard.values) {
      final mover = which == BughouseBoard.a ? acting : acting.opposite;
      final half = action.half(which);
      final uci = half.uci;
      if (half.isPass || uci == null) {
        // Sitting is only a decision on a board the team is actually on move
        // on; elsewhere the pass is just the shape of a joint action.
        if (position.board(which).turn == mover) sans[which] = 'sit';
        continue;
      }
      final board = position.board(which);
      final move = parseEngineUci(board, uci);
      if (move == null || !board.isLegal(move)) return null;
      sans[which] = board.makeSan(move).$2;
      final played = next.playMove(which, move);
      if (played == null) return null;
      next = played;
    }
    if (sans.isEmpty) return null;
    return (sans: sans, after: next);
  }
}
