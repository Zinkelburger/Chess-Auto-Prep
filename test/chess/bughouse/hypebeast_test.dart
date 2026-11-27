import 'package:chess_auto_prep/chess/bughouse/hypebeast.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lines as HypeBeast v1.1.1 printed them, searching the start position
/// alone with MultiPV 3 (`Coordination false`).
const _alone = [
  'info string NNUE evaluation using /x/bughouse-cd8cceab93fe.nnue enabled',
  'info depth 1 seldepth 1 multipv 1 score cp 92 nodes 21 nps 1615 tbhits 0 '
      'time 13 pv d2d4',
  'info depth 1 seldepth 1 multipv 2 score cp 20 nodes 21 nps 1615 tbhits 0 '
      'time 13 pv e2e3',
  'info depth 1 seldepth 1 multipv 3 score cp 2 nodes 21 nps 1615 tbhits 0 '
      'time 13 pv d2d3',
  'info depth 5 seldepth 5 multipv 1 score cp 63 nodes 837 nps 59785 tbhits 0 '
      'time 14 pv e2e4 d7d5 e4d5 d8d5 d2d4',
  'info depth 4 seldepth 2 multipv 2 score cp 0 nodes 837 nps 59785 tbhits 0 '
      'time 14 pv d2d4 a7a6',
  'info depth 4 seldepth 1 multipv 3 score cp 0 nodes 837 nps 59785 tbhits 0 '
      'time 14 pv e2e3',
  'info depth 18 seldepth 26 multipv 1 score cp 56 nodes 1336850 nps 1015843 '
      'hashfull 92 tbhits 0 time 1316 pv e2e4 e7e5 g1f3 b8c6 b1c3 g8f6',
  'info depth 19 seldepth 24 multipv 1 score cp 48 nodes 1521565 nps 1012351 '
      'hashfull 107 tbhits 0 time 1503 pv e2e4 e7e5',
  'info depth 18 score cp 56 nodes 1521565 time 1502',
  'info string hb_summary budget_ms=1500 coord=0 decision=e2e4 main_depth=18 '
      'reason=main seat=Awhite team=white total_nodes=1521565 elapsed_ms=1502',
];

/// The coordinator searching board 1 for Black (seat `Ablack`), as v1.1.1
/// printed it, its other reports shortened.
const _coordinated = [
  'info string hb_forecast {"ready":true,"lines":[]}',
  'info depth 17 seldepth 18 multipv 1 score cp 263 nodes 576763 nps 669098 '
      'tbhits 0 time 862 pv e7e6 b1c3 e6d5 d2d4 g8f6',
  'info depth 18 seldepth 20 multipv 1 score cp 292 nodes 790462 nps 679674 '
      'hashfull 47 tbhits 0 time 1163 pv e7e6',
  'info string hb_coord {"reason":"kept_main","partner_base":-83,'
      '"candidates":[{"move":"e7e6","source":"main","L":262,"S":176},'
      '{"move":"c7c6","source":"root","L":146,"S":98},'
      '{"move":"d8d5","source":"delivery","L":88,"S":66},'
      '{"move":"b8c6","source":"root","L":null,"S":null},'
      '{"move":"g8f6","source":"world","L":183,"S":157}]}',
  'info depth 17 score cp 263 nodes 1126201 time 1960',
  'info string hb_summary budget_ms=2000 coord=1 decision=e7e6 main_depth=17 '
      'reason=kept_main total_nodes=1126201 elapsed_ms=1960',
];

SeatReport read(Iterable<String> lines) {
  final reader = SeatReader();
  lines.forEach(reader.read);
  return reader.report;
}

void main() {
  group('an info line', () {
    test('reads depth, rank, score, nodes and the moves', () {
      final line = parseSeatInfo(
        'info depth 15 seldepth 21 multipv 2 score cp -28 nodes 265188 '
        'nps 354529 tbhits 0 time 748 pv b8c6 d2d4 N@f3',
      )!;
      expect(line.depth, 15);
      expect(line.seldepth, 21);
      expect(line.multipv, 2);
      expect(line.cp, -28);
      expect(line.mate, isNull);
      expect(line.nodes, 265188);
      expect(line.pv, ['b8c6', 'd2d4', 'N@f3']);
      expect(line.bound, isFalse);
    });

    test('reads a mate and a bound', () {
      final mate = parseSeatInfo(
        'info depth 9 seldepth 2 multipv 1 score mate -2 nodes 9 pv a8a1',
      )!;
      expect(mate.mate, -2);
      expect(mate.cp, isNull);
      final bound = parseSeatInfo(
        'info depth 9 multipv 1 score cp 40 lowerbound nodes 9 pv e2e4',
      )!;
      expect(bound.bound, isTrue);
      expect(bound.cp, 40);
      expect(bound.pv, ['e2e4']);
    });

    test('without a pv is the closing verdict; strings are not lines', () {
      final verdict = parseSeatInfo(
        'info depth 17 score cp 263 nodes 11 time 5',
      )!;
      expect(verdict.pv, isEmpty);
      expect(verdict.depth, 17);
      expect(parseSeatInfo('info string hb_summary total_nodes=3'), isNull);
      expect(parseSeatInfo('info nodes 3'), isNull);
      expect(parseSeatInfo('bestmove (e2e4,pass)'), isNull);
    });
  });

  group('the coordinator', () {
    test('hb_coord: the reason and each move with L and S, null kept', () {
      final c = parseCoordination(
        '{"reason":"kept_main","candidates":[{"move":"e7e6","L":262,"S":176},'
        '{"move":"b8c6","L":null,"S":null},{"move":"c7c6","L":146,"S":null}]}',
      )!;
      expect(c.reason, 'kept_main');
      expect(c.candidates.map((x) => (x.move, x.l, x.s, x.score)), [
        ('e7e6', 262, 176, 176),
        ('b8c6', null, null, null),
        ('c7c6', 146, null, 146),
      ]);
    });

    test('hb_coord without candidates, or not JSON', () {
      final win = parseCoordination('{"reason":"team_win_main","team_wins":1}');
      expect(win!.candidates, isEmpty);
      expect(parseCoordination('{"reason":'), isNull);
      expect(parseCoordination('[1]'), isNull);
    });

    test('hb_summary: key=value pairs', () {
      expect(parseSummary('decision=e7e6 main_depth=17 reason=kept_main x'), {
        'decision': 'e7e6',
        'main_depth': '17',
        'reason': 'kept_main',
      });
    });
  });

  group('bestmove', () {
    test('the seat\'s half of the joint move', () {
      expect(
        parseBestMove('bestmove (g8f6,pass)', BoardNumber.one),
        const SeatDecision('g8f6'),
      );
      expect(
        parseBestMove('bestmove (pass,a8a1)', BoardNumber.two),
        const SeatDecision('a8a1'),
      );
      expect(parseBestMove('bestmove e2e4', BoardNumber.one)!.move, 'e2e4');
    });

    test('pass is a sit; none is no decision', () {
      expect(
        parseBestMove('bestmove (pass,pass)', BoardNumber.one)!.sits,
        isTrue,
      );
      expect(parseBestMove('bestmove (none)', BoardNumber.one), isNull);
      expect(parseBestMove('bestmove (none,pass)', BoardNumber.one), isNull);
      expect(parseBestMove('bestmove', BoardNumber.one), isNull);
    });
  });

  group('a search read', () {
    test('alone: the lines by rank, nodes growing', () {
      final report = read(_alone.take(4));
      expect(report.lines.map((l) => (l.multipv, l.cp, l.pv.first)), [
        (1, 92, 'd2d4'),
        (2, 20, 'e2e3'),
        (3, 2, 'd2d3'),
      ]);
      expect(report.nodes, 21);
    });

    test(
      'v1.1.1\'s unsearched ranks are dropped once the main line is deep',
      () {
        final report = read(_alone.take(7));
        expect(report.lines.map((l) => l.multipv), [1]);
        expect(report.main!.pv.first, 'e2e4');
      },
    );

    test('a real second line with a level score is kept', () {
      final report = read([
        'info depth 12 seldepth 18 multipv 1 score cp 30 nodes 9 pv e2e4',
        'info depth 12 seldepth 16 multipv 2 score cp 0 nodes 9 pv d2d4 d7d5',
      ]);
      expect(report.lines.map((l) => l.multipv), [1, 2]);
    });

    test('the cut line of a stopped iteration gives way to the verdict\'s', () {
      final report = read(_alone);
      expect(report.main!.depth, 18);
      expect(report.main!.cp, 56);
      expect(report.main!.pv, hasLength(6));
      expect(report.nodes, 1521565);
    });

    test('a bound on the main line is noise; on a later rank it stays', () {
      final report = read([
        'info depth 10 seldepth 12 multipv 1 score cp 30 nodes 5 pv e2e4',
        'info depth 11 seldepth 12 multipv 1 score cp 80 lowerbound nodes 9 '
            'pv d2d4',
        'info depth 10 seldepth 12 multipv 2 score cp 10 upperbound nodes 9 '
            'pv g1f3',
      ]);
      expect(report.main!.pv.first, 'e2e4');
      expect(report.lines.last.pv.first, 'g1f3');
      expect(report.nodes, 9);
    });

    test('a new main line drops ranks two iterations older', () {
      final report = read([
        'info depth 8 seldepth 9 multipv 1 score cp 30 nodes 5 pv e2e4',
        'info depth 8 seldepth 9 multipv 2 score cp 20 nodes 5 pv d2d4',
        'info depth 10 seldepth 12 multipv 1 score cp 35 nodes 9 pv e2e4',
      ]);
      expect(report.lines.map((l) => l.multipv), [1]);
    });

    test(
      'coordinated: the main line, the report and the whole search size',
      () {
        final report = read(_coordinated);
        expect(report.main!.depth, 17);
        expect(report.main!.pv, hasLength(5));
        expect(report.coordination!.candidates, hasLength(5));
        expect(report.nodes, 1126201);
      },
    );
  });

  group('rows', () {
    test('alone: each line whole, at most the count', () {
      final rows = seatRows(read(_alone.take(4)), coordinated: false, count: 2);
      expect(rows.map((r) => (r.move, r.cp, r.pv.length)), [
        ('d2d4', 92, 1),
        ('e2e3', 20, 1),
      ]);
    });

    test('coordinated, while searching: the main line alone', () {
      final rows = seatRows(
        read(_coordinated.take(3)),
        coordinated: true,
        count: 3,
      );
      expect(rows.single.move, 'e7e6');
      expect(rows.single.pv, ['e7e6']);
    });

    test('coordinated, decided: the decision as the main line, then the '
        'moves compared best first by S, unscored last', () {
      final report = read(_coordinated);
      final rows = seatRows(
        report,
        coordinated: true,
        decision: const SeatDecision('e7e6'),
        count: 5,
      );
      expect(rows.map((r) => (r.move, r.cp, r.pv.length)), [
        ('e7e6', 263, 5),
        ('g8f6', 157, 1),
        ('c7c6', 98, 1),
        ('d8d5', 66, 1),
        ('b8c6', null, 1),
      ]);
      expect(
        seatRows(
          report,
          coordinated: true,
          decision: const SeatDecision('e7e6'),
          count: 3,
        ),
        hasLength(3),
      );
    });

    test('a decision other than the main line\'s move takes its score from '
        'the coordinator; the main line follows as a candidate', () {
      final rows = seatRows(
        read(_coordinated),
        coordinated: true,
        decision: const SeatDecision('g8f6'),
        count: 3,
      );
      expect(rows.map((r) => (r.move, r.cp, r.pv.length)), [
        ('g8f6', 157, 1),
        ('e7e6', 263, 5),
        ('c7c6', 98, 1),
      ]);
    });

    test('a sit is a row of its own, without a score, then the candidates', () {
      final rows = seatRows(
        read(_coordinated),
        coordinated: true,
        decision: const SeatDecision(null),
        count: 3,
      );
      expect(rows.first.move, isNull);
      expect(rows.first.cp, isNull);
      expect(rows.first.pv, isEmpty);
      expect(rows.skip(1).map((r) => r.move), ['e7e6', 'g8f6']);
    });

    test('a sit with nothing compared is the only row', () {
      final rows = seatRows(
        read(['info depth 0 nodes 120 time 4']),
        coordinated: true,
        decision: const SeatDecision(null),
        count: 3,
      );
      expect(rows.single.move, isNull);
    });
  });

  group('the score from A + B\'s side', () {
    test('board 1: White is A, kept; Black is C, turned', () {
      expect(TableScore.forSeat(cp: 25, team: Team.ab).text, '+0.25');
      expect(TableScore.forSeat(cp: 263, team: Team.cd).text, '-2.63');
    });

    test('board 2: Black is B, kept; White is D, turned', () {
      // Seat Bblack is A + B's partner.
      final position = TablePosition.initial
          .play(BoardNumber.two, 'e2e4')!
          .after;
      expect(position.mover(BoardNumber.two).team, Team.ab);
      expect(TableScore.forSeat(mate: 1, team: Team.ab).text, '#1');
      expect(TableScore.forSeat(cp: -140, team: Team.cd).text, '+1.40');
      expect(TableScore.forSeat(mate: 2, team: Team.cd).text, '#-2');
    });

    test('nothing reads as a dash; zero as 0.00', () {
      expect(const TableScore().text, '—');
      expect(const TableScore().isEmpty, isTrue);
      expect(const TableScore(cp: 0).text, '0.00');
      expect(const TableScore(cp: -4).text, '-0.04');
    });

    test(
      'two boards add; a mate on either is the score, the quicker of two',
      () {
        expect(
          TableScore.sum(const [TableScore(cp: 120), TableScore(cp: -45)]),
          const TableScore(cp: 75),
        );
        expect(
          TableScore.sum(const [TableScore(cp: 120), TableScore(mate: -3)]),
          const TableScore(mate: -3),
        );
        expect(
          TableScore.sum(const [TableScore(mate: 5), TableScore(mate: -2)]),
          const TableScore(mate: -2),
        );
        expect(
          TableScore.sum(const [TableScore(), TableScore(cp: 30)]),
          const TableScore(cp: 30),
        );
        expect(TableScore.sum(const [TableScore()]).isEmpty, isTrue);
      },
    );
  });

  group('arrow shifts', () {
    SeatRow row(int? cp, {int? mate}) =>
        (move: 'e2e4', cp: cp, mate: mate, pv: const ['e2e4']);

    test('half the difference in lila\'s winning chances', () {
      final shifts = rowShifts([row(100), row(100), row(-100), row(null)]);
      expect(shifts[0], 0);
      expect(shifts[1], 0);
      expect(shifts[2], closeTo(winningChances(100), 1e-9));
      expect(shifts[3], 1);
    });

    test('a mate is the whole chance', () {
      expect(rowShifts([row(null, mate: 2), row(null, mate: -3)])[1], 1);
      expect(rowShifts([row(0), row(null, mate: 4)])[1], 0);
    });

    test('an unscored first row: the others from the best scored one', () {
      expect(rowShifts([row(null), row(50), row(50)]), [0, 0, 0]);
    });

    test('lila\'s curve', () {
      expect(winningChances(0), 0);
      expect(winningChances(300), closeTo(0.5025, 0.001));
    });
  });

  test('seat options: the board and colour to move, the team by board 1', () {
    final after = TablePosition.initial.play(BoardNumber.one, 'e2e4')!.after;
    expect(seatOptions(after, BoardNumber.one), (
      seat: 'Ablack',
      team: 'black',
    ));
    expect(seatOptions(after, BoardNumber.two), (
      seat: 'Bwhite',
      team: 'black',
    ));
    final both = after.play(BoardNumber.two, 'd2d4')!.after;
    expect(seatOptions(both, BoardNumber.two), (seat: 'Bblack', team: 'white'));
    expect(seatOptions(TablePosition.initial, BoardNumber.one), (
      seat: 'Awhite',
      team: 'white',
    ));
  });
}
