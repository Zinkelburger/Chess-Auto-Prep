import 'package:chess_auto_prep/v2/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:flutter_test/flutter_test.dart';

JointLine line(int cp, {int? mate}) => JointLine(
  rank: 1,
  cp: mate == null ? cp : null,
  mate: mate,
  nodes: 200,
  pv: const [],
);

void main() {
  group('the score', () {
    test('Q is the tangent undone, and back again', () {
      expect(qOf(-230), closeTo(-0.5814, 0.001));
      expect(scoreOf(qOf(-230)), closeTo(-2.30, 0.001));
    });

    test('a level opening re-centres to zero from both teams', () {
      // Measured: A + B cp −228, C + D cp −231, neither may sit.
      final offset = (qOf(-228) + qOf(-231)) / 2;
      expect(TableScore.of(line(-228), Team.ab, offset).text, '+0.01');
      // C + D's line reads for A + B with the sign turned: the same number.
      expect(TableScore.of(line(-231), Team.cd, offset).text, '+0.01');
    });

    test('a searched team up a piece reads + for it, − for the other', () {
      final score = TableScore.of(
        line(100),
        Team.cd,
        assumedOffset(ClockCase.even),
      );
      expect(score.score, lessThan(0));
      expect(score.forTeam(Team.cd).score, greaterThan(0));
    });

    test('a mate is kept as plies, signed for A + B', () {
      final score = TableScore.of(line(0, mate: 3), Team.cd, 0);
      expect(score.mate, -3);
      expect(score.text, '#-3');
      expect(score.forTeam(Team.cd).text, '#3');
      expect(score.strength, lessThan(-1000));
    });

    test('nothing reads as a dash and sorts last', () {
      const nothing = TableScore();
      expect(nothing.text, '—');
      expect(nothing.strength, double.negativeInfinity);
    });

    test('the assumed offset: −0.58 when nobody may sit, 0 when one may', () {
      expect(assumedOffset(ClockCase.even), closeTo(-sitBitQ, 1e-9));
      expect(assumedOffset(ClockCase.abMaySit), 0);
      expect(assumedOffset(ClockCase.cdMaySit), 0);
    });
  });

  test('the clock cases give each team its bit', () {
    expect(ClockCase.abMaySit.maySit(Team.ab), isTrue);
    expect(ClockCase.abMaySit.maySit(Team.cd), isFalse);
    expect(ClockCase.even.maySit(Team.ab), isFalse);
    expect(ClockCase.cdMaySit.maySit(Team.cd), isTrue);
  });

  group('joint moves', () {
    test('read both halves; pass and none are a sit', () {
      expect(JointMove.parse('(g1f3,pass)'), const JointMove('g1f3', null));
      expect(JointMove.parse('(none,P@f7)'), const JointMove(null, 'P@f7'));
      expect(JointMove.parse('(none)'), isNull);
      expect(JointMove.parse('g1f3'), isNull);
      expect(const JointMove('g1f3', null).toString(), '(g1f3,pass)');
    });

    test('read as the seats that play them', () {
      final halves = teamHalves(
        TablePosition.initial,
        const JointMove('d2d4', null),
        Team.ab,
      );
      // A moves on board 1; on board 2 D (C + D) is on move, not B.
      expect(halves, {BoardNumber.one: 'A d4'});
      final theirs = teamHalves(
        TablePosition.initial,
        const JointMove(null, 'e2e4'),
        Team.cd,
      );
      expect(theirs, {BoardNumber.two: 'D e4'});
    });

    test('a line reads seat by seat, stopping where it no longer plays', () {
      expect(
        readablePv(TablePosition.initial, const [
          JointMove('d2d4', null),
          JointMove('d7d5', 'd2d4'),
          JointMove(null, null),
          JointMove('e2e5', null),
        ]),
        'A d4 · C d5 D d4 · sit',
      );
    });
  });
}
