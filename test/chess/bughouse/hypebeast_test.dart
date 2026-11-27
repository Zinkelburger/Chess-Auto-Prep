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

/// HypeBeast v1.1.2 deciding to sit, as it printed it: the hold race set's
/// mated-in-one hold (`openings/hold_race_set.json` item 4 in the engine
/// repository, seat `Awhite`, all four clocks given, ten seconds), its
/// forecast, chance, price and draw reports left out.
final _sit = File(
  'test/fixtures/bughouse/hypebeast_v112_sit.txt',
).readAsLinesSync();

/// HypeBeast v1.1.2's coordinator on board 1 for White over ten seconds, as
/// it printed it, the same reports and its `currmove` lines left out.
final _coordinatedV112 = File(
  'test/fixtures/bughouse/hypebeast_v112_coordinated.txt',
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

    test('hb_summary: a value with spaces does not hide the reason', () {
      final summary = parseSummary(
        _sit.firstWhere((l) => l.startsWith('info string hb_summary ')),
      );
      expect(summary['reason'], 'hold_mated');
      expect(summary['decision'], 'pass');
      expect(summary['main_score_cp'], '-99998');
    });

    test(
      'hb_summary scores: centipawns, or a mate as 100000 less its plies',
      () {
        expect(parseSummaryScore('1553'), (cp: 1553, mate: null));
        expect(parseSummaryScore('-37'), (cp: -37, mate: null));
        // Mated in two plies is mate in −1; mating in one ply, three or four
        // is mate in 1, 2 and 2, as an info line counts it.
        expect(parseSummaryScore('-99998'), (cp: null, mate: -1));
        expect(parseSummaryScore('-99996'), (cp: null, mate: -2));
        expect(parseSummaryScore('99999'), (cp: null, mate: 1));
        expect(parseSummaryScore('99997'), (cp: null, mate: 2));
        expect(parseSummaryScore('99996'), (cp: null, mate: 2));
        expect(parseSummaryScore('none'), isNull);
        expect(parseSummaryScore(null), isNull);
      },
    );

    test('decision_line: the engine\'s score and line for its decision', () {
      final c = parseCoordination(
        '{"reason":"override","candidates":[{"move":"c8g4","L":250,"S":null}],'
        '"decision_line":{"move":"c8g4","cp":296,"depth":18,'
        '"pv":["c8g4","f1e2","g4e2"]}}',
      )!;
      final line = c.decisionLine!;
      expect(
        (line.move, line.cp, line.mate, line.depth),
        ('c8g4', 296, null, 18),
      );
      expect(line.pv, ['c8g4', 'f1e2', 'g4e2']);
      final mate = parseCoordination(
        '{"reason":"team_win_main","decision_line":{"move":"Q@h7","mate":2,'
        '"depth":9,"pv":["Q@h7","g8h7"]}}',
      )!;
      expect(mate.decisionLine?.mate, 2);
      expect(mate.decisionLine?.cp, isNull);
    });

    test('decision_line: one without a score, or whose line starts with '
        'another move, is read as far as it holds', () {
      expect(
        parseCoordination(
          '{"reason":"x","decision_line":{"move":"e2e4","depth":3}}',
        )!.decisionLine,
        isNull,
      );
      expect(
        parseCoordination(
          '{"reason":"x","decision_line":{"move":"e2e4","cp":5,"pv":["d2d4"]}}',
        )!.decisionLine?.pv,
        ['e2e4'],
      );
      // v1.1.2 prints none.
      expect(read(_coordinatedV112).coordination!.decisionLine, isNull);
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

    test('a search ended on time: a level last block with a line cut short '
        'gives way, at the closing line, to the depth it completed', () {
      // v1.1.2, seat Ablack, MultiPV 3, two seconds: line 3 of depth 14 is
      // cut to two moves with a provisional score.
      const lines = [
        'info depth 13 seldepth 17 multipv 1 score cp -113 nodes 400736 '
            'pv e8f7 d1f3 f7e8 c4d5',
        'info depth 13 seldepth 17 multipv 2 score cp -137 nodes 400736 '
            'pv d8h4 c4d5 c8g4 d1e1',
        'info depth 13 seldepth 19 multipv 3 score cp -315 nodes 400736 '
            'pv d8d7 f7h8 d5f4 e1g1',
        'info depth 14 seldepth 23 multipv 1 score cp -115 nodes 568025 '
            'pv e8f7 d1f3 f7e8 c4d5',
        'info depth 14 seldepth 17 multipv 2 score cp -138 nodes 568025 '
            'pv d8h4 c4d5 c8g4 d1e1',
        'info depth 14 seldepth 21 multipv 3 score cp -323 nodes 568025 '
            'pv d8d7 f7h8',
        'info depth 13 score cp -113 nodes 568025 time 2007',
      ];
      // Still searching: the last level block.
      expect(read(lines.take(6)).lines.map((l) => (l.depth, l.cp)), [
        (14, -115),
        (14, -138),
        (14, -323),
      ]);
      final closed = read(lines);
      expect(closed.lines.map((l) => (l.depth, l.cp, l.pv.length)), [
        (13, -113, 4),
        (13, -137, 4),
        (13, -315, 4),
      ]);
      expect(closed.nodes, 568025);
      // A closing line at the depth shown, or deeper, keeps it.
      expect(
        read([
          ...lines.take(6),
          'info depth 14 score cp -115 nodes 9',
        ]).lines.map((l) => l.depth),
        [14, 14, 14],
      );
    });

    test('an hb_error is kept for the search\'s answer', () {
      final report = read([
        'info string hb_error position illegal move 1e2e5',
        'info depth 0 nodes 0 time 1',
      ]);
      expect(report.error, 'position illegal move 1e2e5');
      expect(read(_coordinated).error, isNull);
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
        // The closing line says depth 17 was the last one completed.
        expect(report.main!.depth, 17);
        expect(report.main!.pv, ['e7e6', 'b1c3', 'e6d5', 'd2d4', 'g8f6']);
        expect(report.coordination!.candidates, hasLength(5));
        expect(report.nodes, 1126201);
        // While it still searched, the depth-18 line, cut to one move.
        expect(read(_coordinated.take(3)).main!.depth, 18);
      },
    );

    test('v1.1.2 coordinated: the summary\'s main score and reason', () {
      final report = read(_coordinatedV112);
      expect(report.mainScore, (cp: 1553, mate: null));
      expect(report.reason, 'kept_main');
      expect(report.summary['decision'], 'd4f6');
      expect(report.nodes, 1872437);
      expect(report.coordination!.candidates.map((c) => c.move), [
        'd4f6',
        'd4c3',
        'g2b7',
        'd4a4',
      ]);
    });

    test('v1.1.2 sitting: no candidates, a mate against it, and why', () {
      final report = read(_sit);
      expect(parseBestMove(_sit.last, BoardNumber.one)!.sits, isTrue);
      expect(report.coordination!.candidates, isEmpty);
      expect(report.coordination!.reason, 'hold_mated');
      expect(report.reason, 'hold_mated');
      expect(report.mainScore, (cp: null, mate: -1));
      expect(report.main!.mate, -1);
      expect(report.summary['wait'], 'skip_partner_not_on_turn');
    });
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
      // One scale: the coordinator's S for every row, the decision's too,
      // which keeps the main line's moves.
      expect(rows.map((r) => (r.move, r.cp, r.pv.length)), [
        ('e7e6', 176, 5),
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
        'the coordinator; the main line follows as a candidate, on the same '
        'scale', () {
      final rows = seatRows(
        read(_coordinated),
        coordinated: true,
        decision: const SeatDecision('g8f6'),
        count: 3,
      );
      expect(rows.map((r) => (r.move, r.cp, r.pv.length)), [
        ('g8f6', 157, 1),
        ('e7e6', 176, 5),
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

    test('the decision with the coordinator\'s own line: its score and its '
        'line, whether or not it is the main line\'s move', () {
      final report = read([
        ..._coordinated.take(4),
        'info string hb_coord {"reason":"world_switch","candidates":['
            '{"move":"e7e6","L":262,"S":176},{"move":"g8f6","L":null,"S":null}],'
            '"decision_line":{"move":"g8f6","cp":171,"depth":16,'
            '"pv":["g8f6","b1c3","e7e6"]}}',
      ]);
      final rows = seatRows(
        report,
        coordinated: true,
        decision: const SeatDecision('g8f6'),
        count: 3,
      );
      // g8f6, unscored by the coordinator, has the engine's own score;
      // e7e6 the coordinator's.
      expect(rows.map((r) => (r.move, r.cp, r.pv.join(' '))), [
        ('g8f6', 171, 'g8f6 b1c3 e7e6'),
        ('e7e6', 176, 'e7e6'),
      ]);
      final kept = read([
        ..._coordinated.take(4),
        'info string hb_coord {"reason":"kept_main","candidates":[],'
            '"decision_line":{"move":"e7e6","mate":-4,"depth":18,'
            '"pv":["e7e6","d5e6"]}}',
      ]);
      final row = seatRows(
        kept,
        coordinated: true,
        decision: const SeatDecision('e7e6'),
        count: 3,
      ).single;
      expect((row.move, row.cp, row.mate), ('e7e6', null, -4));
      expect(row.pv, ['e7e6', 'd5e6']);
    });

    test('the real sit: one row, sitting, without a score', () {
      final rows = seatRows(
        read(_sit),
        coordinated: true,
        decision: parseBestMove(_sit.last, BoardNumber.one),
        count: 3,
      );
      final row = rows.single;
      expect((row.move, row.cp, row.mate), (null, null, null));
      expect(row.pv, isEmpty);
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

  group('the coordinator\'s clipped scores', () {
    test('a score at its limit is a bound, on the row and in A + B\'s '
        'score', () {
      final report = read([
        'info depth 9 seldepth 9 multipv 1 score mate 3 nodes 9 pv d1h5 g7g6',
        'info string hb_coord {"reason":"kept_main","candidates":['
            '{"move":"d1h5","L":2000,"S":2000},{"move":"f1c4","L":-2000}]}',
      ]);
      final rows = seatRows(
        report,
        coordinated: true,
        decision: const SeatDecision('d1h5'),
        count: 3,
      );
      // The main line's mate says more than the coordinator's limit.
      expect(rows.map((r) => (r.move, r.cp, r.mate, r.clipped)), [
        ('d1h5', null, 3, false),
        ('f1c4', -2000, null, true),
      ]);
      expect(
        TableScore.forSeat(cp: 2000, team: Team.ab, clipped: true).text,
        '>+20',
      );
      expect(
        TableScore.forSeat(cp: 2000, team: Team.cd, clipped: true).text,
        '<-20',
      );
      // A mate stays a mate.
      expect(
        TableScore.forSeat(mate: 3, team: Team.ab, clipped: true).text,
        '#3',
      );
    });

    test('a sum with a bound in it is a bound when they lean one way', () {
      const bound = TableScore(cp: 2000, clipped: true);
      expect(TableScore.sum(const [bound, TableScore(cp: -350)]).text, '>+16');
      expect(
        TableScore.sum(const [bound, TableScore(cp: -2000, clipped: true)]),
        const TableScore(cp: 0),
      );
      expect(
        TableScore.sum(const [bound, TableScore(cp: -2500)]).text,
        '-5.00',
      );
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
        (move: 'e2e4', cp: cp, mate: mate, pv: const ['e2e4'], clipped: false);

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
