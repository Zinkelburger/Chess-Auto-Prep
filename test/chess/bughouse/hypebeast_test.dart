import 'dart:io';

import 'package:chess_auto_prep/chess/bughouse/hypebeast.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:flutter_test/flutter_test.dart';

/// HypeBeast v1.1.2 searching board 1 alone for Black with MultiPV 3
/// (`Coordination false`, eight threads, three seconds) after 1. e4 d5 2.
/// exd5 Nf6 3. Nc3, as it printed it.
final _alone = File(
  'test/fixtures/bughouse/hypebeast_v112_alone.txt',
).readAsLinesSync();

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
    test('alone: a block shows once all its lines are in, nodes growing', () {
      expect(read(_alone.take(2)).lines.single.pv, ['f6d5']);
      var report = read(_alone.take(4));
      expect(report.lines.map((l) => (l.multipv, l.depth, l.cp)), [
        (1, 1, -78),
        (2, 1, -81),
        (3, 1, -87),
      ]);
      expect(report.nodes, 489);
      // Line 1 of depth 2 alone does not replace the depth-1 block.
      report = read(_alone.take(5));
      expect(report.lines.map((l) => l.depth), [1, 1, 1]);
      report = read(_alone.take(7));
      expect(report.lines.map((l) => l.depth), [2, 2, 2]);
    });

    test('a block with a line behind line 1\'s depth is not shown', () {
      final report = read([
        'info depth 8 seldepth 9 multipv 1 score cp 30 nodes 5 pv e2e4',
        'info depth 8 seldepth 9 multipv 2 score cp 20 nodes 5 pv d2d4',
        'info depth 9 seldepth 12 multipv 1 score cp 35 nodes 9 pv e2e4',
        'info depth 8 seldepth 9 multipv 2 score cp 20 nodes 9 pv d2d4',
      ]);
      expect(report.lines.map((l) => (l.depth, l.cp)), [(8, 30), (8, 20)]);
    });

    test(
      'a stopped search: its last block, one line deeper than the rest, '
      'gives way to the last level one; the closing line counts the nodes',
      () {
        final report = read(_alone);
        expect(report.lines.map((l) => (l.depth, l.cp, l.pv.first)), [
          (17, -38, 'c7c6'),
          (17, -49, 'e7e6'),
          (17, -53, 'g7g6'),
        ]);
        expect(report.nodes, 10305309);
      },
    );

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

    test('a block printed twice at one depth replaces itself', () {
      final report = read([
        'info depth 21 seldepth 31 multipv 1 score cp 45 nodes 9 pv e7e6 d5e6',
        'info depth 21 seldepth 31 multipv 2 score cp -50 nodes 9 pv c7c6',
        'info depth 21 seldepth 31 multipv 1 score cp 41 nodes 19 pv e7e6 d5e6',
        'info depth 21 seldepth 31 multipv 2 score cp -44 nodes 19 pv c7c6',
      ]);
      expect(report.lines.map((l) => l.cp), [41, -44]);
    });

    test(
      'coordinated: each main line, the report and the whole search size',
      () {
        final report = read(_coordinated);
        expect(report.main!.depth, 18);
        expect(report.main!.pv, ['e7e6']);
        expect(report.coordination!.candidates, hasLength(5));
        expect(report.nodes, 1126201);
      },
    );
  });

  group('rows', () {
    test('alone: each line whole, best first, at most the count', () {
      final rows = seatRows(read(_alone), coordinated: false, count: 2);
      expect(rows.map((r) => (r.move, r.cp)), [('c7c6', -38), ('e7e6', -49)]);
      expect(rows.first.pv.length, greaterThan(2));
    });

    test('alone: lines out of order by rank are sorted by score for the '
        'side to move', () {
      final report = read([
        'info depth 17 seldepth 23 multipv 1 score cp -44 nodes 9 pv e7e6 d5e6',
        'info depth 17 seldepth 25 multipv 2 score cp -38 nodes 9 pv c7c6 d2d4',
        'info depth 17 seldepth 25 multipv 3 score cp -53 nodes 9 pv g7g6 d2d4',
      ]);
      final rows = seatRows(report, coordinated: false, count: 3);
      expect(rows.map((r) => (r.move, r.cp)), [
        ('c7c6', -38),
        ('e7e6', -44),
        ('g7g6', -53),
      ]);
    });

    test('alone: a mate for the side to move first, one against it last', () {
      final report = read([
        'info depth 9 seldepth 9 multipv 1 score cp 300 nodes 9 pv a2a3',
        'info depth 9 seldepth 9 multipv 2 score mate -2 nodes 9 pv b2b3',
        'info depth 9 seldepth 9 multipv 3 score mate 3 nodes 9 pv c2c3',
      ]);
      expect(
        seatRows(report, coordinated: false, count: 3).map((r) => r.move),
        ['c2c3', 'a2a3', 'b2b3'],
      );
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
        ('e7e6', 292, 1),
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
        ('e7e6', 292, 1),
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
