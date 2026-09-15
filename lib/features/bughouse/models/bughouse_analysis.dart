/// What the analysis pane holds between passes: each team's standing answer,
/// the move under the pointer, and the rows of a scenario comparison.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../../models/board_annotation.dart';
import 'bughouse_eval.dart';
import 'bughouse_state.dart';

/// What one team currently thinks about the position.
///
/// Two of these are kept at all times, because a bughouse position has no
/// single side to move: each board has its own turn, so at any moment one team
/// may hold both moves, or one each, and the team you are on may hold neither.
/// Searching only our own team is what used to leave the pane saying the
/// engine "returned no move" in exactly the positions where the interesting
/// answer was what the opponents were about to do.
@immutable
class BughouseTeamAnalysis {
  const BughouseTeamAnalysis({
    required this.team,
    this.latest,
    this.lines = const [],
    this.best,
  });

  /// The colour this team plays on board A.
  final Side team;

  /// The newest top line, updated while a pass runs.
  final BughouseInfo? latest;

  /// The ranked shortlist from the last finished pass. Hivemind prints its
  /// MultiPV block once, at the end, so this lags [latest] by one pass.
  final List<BughouseInfo> lines;

  /// The joint action the last finished pass settled on.
  final BughouseJointMove? best;

  /// The line to calibrate and to head the table with.
  ///
  /// The finished block is preferred over the live line because calibration
  /// pairs two teams' searches and the finished ones are the pair that ran to
  /// the same budget. Before any pass has finished there is only [latest].
  BughouseInfo? get principal => lines.isNotEmpty ? lines.first : latest;

  bool get isEmpty => latest == null && best == null && lines.isEmpty;

  BughouseTeamAnalysis withLatest(BughouseInfo info) =>
      BughouseTeamAnalysis(team: team, latest: info, lines: lines, best: best);
}

/// What a hovered move puts on the two boards, and who put it there.
///
/// Held as finished annotations rather than as the move, because a move deep
/// in a line belongs to a position that is not the one on screen, and only
/// the panel row that owns the hover knows which.
@immutable
class BughouseHover {
  const BughouseHover({
    required this.owner,
    required this.a,
    required this.b,
    this.preview,
  });

  /// Who set it — so a row leaving the screen clears only its own highlight.
  final Object owner;

  final BughouseState? preview;
  final List<BoardAnnotation> a;
  final List<BoardAnnotation> b;

  List<BoardAnnotation> on(BughouseBoard which) =>
      which == BughouseBoard.a ? a : b;
}

/// One row of a scenario comparison.
///
/// Carries the offset measured for *this row*, because that is the thing the
/// rows do not share: the network reads the `TimeAdvantage` bit as most of the
/// raw score, so the row where we may sit sits on a different zero from the
/// rows where we may not.
@immutable
class BughouseScenarioResult {
  const BughouseScenarioResult({
    required this.label,
    required this.best,
    required this.info,
    required this.calibration,
  });

  final String label;
  final BughouseJointMove? best;
  final BughouseInfo? info;
  final BughouseCalibration calibration;

  /// The row's score from our seat, on the one scale every row shares.
  BughouseEval? get eval {
    final line = info;
    return line == null ? null : BughouseEval.of(line, calibration);
  }
}
