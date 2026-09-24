/// How Hivemind, the two-board engine, reads a table, and how its numbers
/// are read back.
///
/// **The score is not pawns.** Hivemind prints `180·tan(1.56·Q)` of an MCTS
/// value Q in −1…1, so the tangent inverts exactly ([qOf]). Q carries a
/// large offset that is not the position's: the network reads its one clock
/// input — may this team sit instead of moving? — as about ±0.58 of Q, more
/// than a queen, so a level opening reads about −2.3 from both seats when
/// neither team may sit. The offset also differs from position to position
/// (−0.31 to −0.67 of Q across dead-level mirrored tables), so it is
/// measured: search the table once for each team, and with each team's
/// value written `q = ±advantage + offset`,
///
///     offset    = (q_A+B + q_C+D) / 2
///     advantage = (q_A+B − q_C+D) / 2
///
/// The shift is taken in Q and the tangent put back afterwards ([scoreOf]):
/// the tangent is steeper at the offset than at zero, so subtracting from the
/// printed number would inflate every advantage. The result is Hivemind's
/// scale re-centred — 0.00 level, + good for the team named — which is what
/// the precomputed book stores and what the lab prints.
///
/// Example: a level opening, neither team may sit: A + B's search prints
/// cp −228 (Q −0.573), C + D's cp −231 (Q −0.577); the offset is −0.575,
/// A + B's advantage +0.002 of Q, printed `+0.01` — level, as it should be.
library;

import 'dart:math' as math;

import 'package:dartchess/dartchess.dart' show Side;

import 'table.dart';

/// Which team is up on the diagonal clock, and so may sit — wait for a
/// piece rather than move — while it is on move. The two diagonal margins
/// are one number (both boards start together and one clock per board
/// runs), so a team is up, level or down: three cases, not four.
enum ClockCase {
  abMaySit(
    'A + B may sit',
    'A + B are up on the diagonal clock, so they can wait rather than move',
  ),
  even('Even', 'Neither team is up on the clock: both have to move'),
  cdMaySit(
    'C + D may sit',
    'C + D are up on the diagonal clock, so they can wait rather than move',
  );

  const ClockCase(this.label, this.hint);

  final String label;
  final String hint;

  /// The engine's `TimeAdvantage` input for [team] in this case.
  bool maySit(Team team) => switch (this) {
    abMaySit => team == Team.ab,
    even => false,
    cdMaySit => team == Team.cd,
  };
}

/// A board the searched team may not sit on: the engine's `RequireMoveOn`.
enum MustMove {
  either('Either', 'none'),
  one('Board 1', 'A'),
  two('Board 2', 'B');

  const MustMove(this.label, this.engineValue);

  final String label;
  final String engineValue;
}

/// One decision about both boards, as the engine prints it: `(d2d4,pass)`.
/// A null half is a sit — a deliberate wait, often the best move — or a
/// board where the team had nothing to decide.
final class JointMove {
  const JointMove(this.one, this.two);

  final String? one;
  final String? two;

  /// `(g1f3,pass)` → Nf3 on board 1 and a sit on board 2; `(none)` and
  /// anything else not two halves → null.
  static JointMove? parse(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('(') || !trimmed.endsWith(')')) return null;
    final halves = trimmed.substring(1, trimmed.length - 1).split(',');
    if (halves.length != 2) return null;
    String? half(String token) {
      final t = token.trim();
      return const {'', 'pass', 'none', '(none)'}.contains(t) ? null : t;
    }

    return JointMove(half(halves[0]), half(halves[1]));
  }

  String? on(BoardNumber board) => board == BoardNumber.one ? one : two;

  @override
  bool operator ==(Object other) =>
      other is JointMove && other.one == one && other.two == two;

  @override
  int get hashCode => Object.hash(one, two);

  @override
  String toString() => '(${one ?? 'pass'},${two ?? 'pass'})';
}

/// One ranked line of a search, as the engine printed it: its raw score
/// from the searched team's side and the joint moves it expects.
final class JointLine {
  const JointLine({
    required this.rank,
    required this.pv,
    required this.nodes,
    this.cp,
    this.mate,
  });

  /// MultiPV rank, 1 first. The engine ranks by visits, not by score.
  final int rank;
  final int? cp;

  /// Plies to mate, + when the searched team mates.
  final int? mate;
  final int nodes;
  final List<JointMove> pv;

  /// The raw value in Q, or null for a mate.
  double? get q => mate == null && cp != null ? qOf(cp!) : null;
}

const _tangentScale = 180.0;
const _tangentRate = 1.56;

/// Q behind a printed score, exactly: the tangent inverted.
double qOf(num cp) => math.atan(cp / _tangentScale) / _tangentRate;

/// A value in Q back on Hivemind's scale, in pawn-like units. Clamped
/// before the tangent, which runs to infinity at ±1: past about ±10 it is
/// winning either way.
double scoreOf(double q) =>
    _tangentScale * math.tan(_tangentRate * q.clamp(-0.9, 0.9)) / 100;

/// What the clock bit alone is worth to the network, in Q: a level table
/// reads cp −230 with it off and +230 with it on, from either seat.
const sitBitQ = 0.5814;

/// The offset a level table gives, for when a team has no move to search:
/// each team reads its own bit as ±[sitBitQ], and the offset is their mean.
double assumedOffset(ClockCase clock) =>
    Team.values
        .map((team) => clock.maySit(team) ? sitBitQ : -sitBitQ)
        .reduce((a, b) => a + b) /
    2;

/// Where the zero of a score came from.
enum ZeroSource {
  /// Both teams were searched here, so the offset cancels exactly.
  measured('Zero is measured here, from both teams’ searches.'),

  /// The other team was not searched — it had no move, or the search was
  /// stopped first — so the level table's offset stands in.
  assumed('Zero is assumed: the other team was not searched here.');

  const ZeroSource(this.note);

  final String note;
}

/// A score for A + B on the re-centred scale, or a mate, + for A + B.
final class TableScore {
  const TableScore({this.score, this.mate});

  /// [line], searched for [team], read against [offset].
  factory TableScore.of(JointLine line, Team team, double offset) {
    final sign = team == Team.ab ? 1 : -1;
    if (line.mate case final mate?) return TableScore(mate: sign * mate);
    final q = line.q;
    if (q == null) return const TableScore();
    return TableScore(score: sign * scoreOf(q - offset));
  }

  final double? score;
  final int? mate;

  bool get isEmpty => score == null && mate == null;

  /// The same score from [team]'s side.
  TableScore forTeam(Team team) => team == Team.ab
      ? this
      : TableScore(
          score: score == null ? null : -score!,
          mate: mate == null ? null : -mate!,
        );

  /// For sorting a table, higher better for A + B: any mate for beats any
  /// score, the quicker the better.
  double get strength => switch ((score, mate)) {
    (_, final int mate) => mate > 0 ? 1e6 - mate : -1e6 - mate,
    (final double score, _) => score,
    _ => double.negativeInfinity,
  };

  /// `+0.25`, `-1.40`, `#3`, `#-2`, or `—` when there is nothing.
  String get text => switch ((score, mate)) {
    (_, final int mate) => mate >= 0 ? '#$mate' : '#-${-mate}',
    (final double score, _) => _signed(score),
    _ => '—',
  };
}

String _signed(double score) {
  final hundredths = (score * 100).round();
  if (hundredths == 0) return '0.00';
  final text = (hundredths.abs() / 100).toStringAsFixed(2);
  return hundredths > 0 ? '+$text' : '-$text';
}

/// Which team answers a move on [board] of [position]: the other seat of
/// that board.
Team answering(TablePosition position, BoardNumber board) =>
    position.mover(board).team.other;

/// [team] as the engine's `Team` option: its colour on board 1.
String engineTeam(Team team) =>
    team.onBoardOne == Side.white ? 'white' : 'black';

/// [team]'s part of [joint] on each board where that team is on move:
/// `A Nf3`, or `B sits` for a deliberate wait. A board the other team is on
/// move on has nothing to decide there and is left out.
Map<BoardNumber, String> teamHalves(
  TablePosition position,
  JointMove joint,
  Team team,
) => {
  for (final board in BoardNumber.values)
    if (position.mover(board).team == team)
      board: _half(position, board, joint.on(board)),
};

String _half(TablePosition position, BoardNumber board, String? uci) {
  final seat = position.mover(board).letter;
  if (uci == null) return '$seat sits';
  final played = position.play(board, uci);
  return '$seat ${played?.move.san ?? uci}';
}

/// A principal variation from [position] as seat-lettered SAN, a `·`
/// between joint actions — `A e4 · C e5 B d5` — as the book stores one. A
/// joint action where nothing moves is `sit`; the reading stops at the first
/// move that does not play, which is what a line from another position
/// looks like.
String readablePv(TablePosition position, List<JointMove> pv, {int limit = 6}) {
  final steps = <String>[];
  var table = position;
  for (final joint in pv.take(limit)) {
    final halves = <String>[];
    for (final board in BoardNumber.values) {
      final uci = joint.on(board);
      if (uci == null) continue;
      final seat = table.mover(board).letter;
      final played = table.play(board, uci);
      if (played == null) return steps.join(' · ');
      halves.add('$seat ${played.move.san}');
      table = played.after;
    }
    steps.add(halves.isEmpty ? 'sit' : halves.join(' '));
  }
  return steps.join(' · ');
}
