import 'package:chess_auto_prep/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
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
    expect(ClockCase.values.map((c) => c.bookName), [
      'ahead',
      'even',
      'behind',
    ]);
  });

  group('one board\'s choices', () {
    JointLine line(int rank, int cp, String? one, String? two) =>
        JointLine(rank: rank, cp: cp, nodes: 100, pv: [JointMove(one, two)]);

    test('each move once, from its most-visited line, the engine\'s choice '
        'first and the rest best-scoring first', () {
      final lines = [
        line(1, 20, 'g1f3', 'd7d5'),
        line(2, 10, 'g1f3', 'e7e6'),
        line(3, 40, 'e2e4', 'd7d5'),
        line(4, 90, 'e2e4', null),
        line(5, 30, 'd2d4', 'c7c5'),
        line(6, 99, 'c2c4', null),
      ];
      final one = boardChoices(lines, BoardNumber.one);
      expect(one.map((l) => l.pv.first.one), ['g1f3', 'e2e4', 'd2d4']);
      expect(one[1].rank, 3);
      final two = boardChoices(lines, BoardNumber.two);
      expect(two.map((l) => l.pv.first.two), ['d7d5', null, 'e7e6']);
    });

    test('how far a line falls behind the best, half the value apart', () {
      final best = line(1, 0, 'e2e4', null);
      expect(shiftFrom(best, best), 0);
      const worse = JointLine(
        rank: 2,
        cp: -180,
        nodes: 100,
        pv: [JointMove('d2d4', null)],
      );
      expect(shiftFrom(best, worse), closeTo(-qOf(-180) / 2, 1e-9));
      expect(shiftFrom(worse, best), 0);
      const mated = JointLine(rank: 3, mate: -2, nodes: 100, pv: []);
      expect(shiftFrom(best, mated), 0.5);
    });
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

    test('one board\'s part of a line is numbered as that board counts', () {
      const pv = [
        JointMove('e2e4', null),
        JointMove('e7e5', 'd2d4'),
        JointMove('g1f3', null),
        JointMove('e5e4', null),
      ];
      expect(
        boardPv(TablePosition.initial, pv, BoardNumber.one),
        '1. e4 e5 2. Nf3',
      );
      expect(boardPv(TablePosition.initial, pv, BoardNumber.two), '1. d4');
      expect(
        boardPv(TablePosition.initial, pv.skip(1).toList(), BoardNumber.one),
        '',
      );
      final afterE4 = TablePosition.initial.play(BoardNumber.one, 'e2e4')!;
      expect(
        boardPv(afterE4.after, pv.skip(1).toList(), BoardNumber.one, limit: 2),
        '1... e5 2. Nf3',
      );
    });
  });
}
