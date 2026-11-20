/// How Hivemind, the two-board engine, reads a table, and how its numbers
/// are read back.
///
/// **The score is not pawns.** Hivemind prints `180·tan(1.56·Q)` of an MCTS
/// value Q in −1…1, so the tangent inverts exactly ([qOf]). The network
/// reads its one clock input — may this team sit instead of moving? — as
/// about ±0.58 of Q, more than a queen, and in its search exactly one team
/// may sit ([ClockCase]), so a level opening reads about +2.3 for the team
/// that may and −2.3 for the other. That is the clock's real worth and it
/// stays in the score. Whatever else the two searches disagree on is
/// measured and taken out: search the table once for each team, and with
/// each team's value written `q = ±advantage + offset`,
///
///     offset    = (q_A+B + q_C+D) / 2
///     advantage = (q_A+B − q_C+D) / 2
///
/// The shift is taken in Q and the tangent put back afterwards ([scoreOf]):
/// the tangent is steeper at the offset than at zero, so subtracting from the
/// printed number would inflate every advantage. The result is Hivemind's
/// scale, + good for the team named, which is what the Bughouse mode prints.
///
/// Example: a level opening, C + D may sit: A + B's search prints cp −228
/// (Q −0.573), C + D's cp +231 (Q +0.577); the offset is +0.002 and A + B's
/// score −0.575 of Q, printed `-2.29`: C + D's right to sit.
library;

import 'dart:math' as math;

import 'package:dartchess/dartchess.dart' show Side;

import 'table.dart';

/// Which team is up on the diagonal clock, and so may sit — wait for a
/// piece rather than move — while it is on move. Hivemind knows only these
/// two: its `TimeAdvantage` says whether the searched team may sit, and its
/// search gives the other team the opposite, so one team or the other
/// always may. There is no case where neither may.
enum ClockCase {
  abMaySit(
    'A + B may sit',
    'A + B are up on the diagonal clock, so they can wait rather than move',
  ),
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
    cdMaySit => team == Team.cd,
  };
}

/// A board the searched team may not sit on: the engine's `RequireMoveOn`.
enum MustMove {
  either('none'),
  one('A'),
  two('B');

  const MustMove(this.engineValue);

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
    this.depth,
    this.cp,
    this.mate,
  });

  /// MultiPV rank, 1 first. The engine ranks by visits, not by score.
  final int rank;
  final int? cp;

  /// Plies to mate, + when the searched team mates.
  final int? mate;
  final int nodes;
  final int? depth;
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

/// Rank 1 first — the line `bestmove` follows, the engine's own choice —
/// then the rest by score for the searched team. The engine ranks MultiPV
/// by visits, and a measured block scored ranks 1–5 +0.08, −0.61, −0.38,
/// −0.46, −0.53, so its own order beside the numbers reads as a mistake.
List<JointLine> rankedLines(Iterable<JointLine> lines) {
  final byRank = lines.toList()..sort((a, b) => a.rank.compareTo(b.rank));
  if (byRank.length < 2) return byRank;
  double strength(JointLine line) =>
      TableScore(score: line.q, mate: line.mate).strength;
  final rest = byRank.sublist(1)
    ..sort((a, b) => strength(b).compareTo(strength(a)));
  return [byRank.first, ...rest];
}

/// The searched team's [count] choices on [board], one line each: the
/// moves there the engine visited most — a null move is a sit on that
/// board — each with its most-visited line, best-scoring first.
///
/// The engine's own choice, the most-visited, is not kept on top: its
/// visit lead settles early, so pinned there it held a worse score above a
/// better one for the rest of a live search, and the rows never swapped.
///
/// The engine ranks joint actions, both boards' moves at once, so a team on
/// move on both boards shows the same move on one board across several of
/// its lines (`(Nc6,d5)`, `(Nc6,e6)`, `(Nc6,pass)`); this reads one board's
/// moves out of the same search.
List<JointLine> boardChoices(
  Iterable<JointLine> lines,
  BoardNumber board, {
  int count = 3,
}) {
  final byRank = lines.where((line) => line.pv.isNotEmpty).toList()
    ..sort((a, b) => a.rank.compareTo(b.rank));
  final seen = <String?>{};
  final picked = <JointLine>[];
  for (final line in byRank) {
    if (picked.length == count) break;
    if (seen.add(line.pv.first.on(board))) picked.add(line);
  }
  double strength(JointLine line) =>
      TableScore(score: line.q, mate: line.mate).strength;
  return picked..sort((a, b) {
    final better = strength(b).compareTo(strength(a));
    return better != 0 ? better : a.rank.compareTo(b.rank);
  });
}

/// How far [line] falls behind [best] for the team searched, 0 to 1: half
/// the difference in value, as lila measures how much thinner to draw an
/// engine move's arrow than its best one. A mate counts as the whole value.
double shiftFrom(JointLine best, JointLine line) {
  double value(JointLine of) => switch ((of.mate, of.q)) {
    (final int mate, _) => mate > 0 ? 1 : -1,
    (_, final double q) => q,
    _ => -1,
  };
  return ((value(best) - value(line)) / 2).clamp(0.0, 1.0);
}

/// [team] as the engine's `Team` option: its colour on board 1.
String engineTeam(Team team) =>
    team.onBoardOne == Side.white ? 'white' : 'black';
