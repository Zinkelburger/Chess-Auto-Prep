import 'package:chess_auto_prep/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/features/bughouse/lab_engine.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

void main() {
  late BughouseLab lab;
  late ScriptedHivemind hivemind;
  late LabEngine engine;
  String? startFailure;
  var starts = 0;

  setUp(() {
    lab = BughouseLab();
    hivemind = ScriptedHivemind();
    startFailure = null;
    starts = 0;
    engine = LabEngine(
      lab: lab,
      passes: const [800, 4000],
      liveNodes: 800,
      zeroNodes: 400,
      startEngine: () async {
        starts++;
        return switch (startFailure) {
          final reason? => HivemindStartFailed(reason),
          null => HivemindStarted(hivemind),
        };
      },
    );
  });

  tearDown(() {
    engine.dispose();
    lab.dispose();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> on() async {
    engine.open();
    engine.toggle();
    for (var i = 0; i < 20; i++) {
      await settle();
    }
  }

  int nodes(HivemindQuestion question) => (question.budget as NodeBudget).nodes;

  test(
    'nothing is searched until the switch is on and the mode open',
    () async {
      engine.toggle();
      await settle();
      expect(hivemind.asked, isEmpty);
      engine.toggle();
      engine.open();
      await settle();
      expect(hivemind.asked, isEmpty);
      expect(engine.lines, isA<LinesOff>());
    },
  );

  test('one board: each pass asks board 1 of its mover and the zero of the '
      'other team, deeper each time', () async {
    await on();
    expect(hivemind.asked.take(4).map(nodes), [800, 800, 4000, 4000]);
    final own = hivemind.asked.first;
    expect(
      (own.team, own.mustMove, own.maySit),
      (Team.ab, MustMove.one, false),
    );
    final zero = hivemind.asked[1];
    expect(zero.team, Team.cd);
    expect(zero.position.turn(BoardNumber.two), Side.white);
    final lines = engine.lines as LinesOn;
    expect(lines.thinking, isFalse);
    expect(lines.nodes, 4000);
    expect(lines.rows.keys, [BoardNumber.one]);
    expect(lines.rows[BoardNumber.one], hasLength(3));
    // Both teams read cp −200: the zero is measured and the table level.
    expect(lines.score.text, '0.00');
    // Then each side that may sit is scored briefly, the searches that
    // match Even's reused.
    expect(hivemind.asked.skip(4).map((q) => (q.team, q.maySit, nodes(q))), [
      (Team.ab, true, labClockNodes),
      (Team.cd, true, labClockNodes),
    ]);
    expect(lines.byClock.keys, [ClockCase.abMaySit, ClockCase.cdMaySit]);
  });

  test('one board: the side on move may sit when the clock says so', () async {
    lab.setClock(ClockCase.abMaySit);
    await on();
    final own = hivemind.asked.first;
    expect(
      (own.team, own.mustMove, own.maySit),
      (Team.ab, MustMove.either, true),
    );
    expect(hivemind.asked[1].maySit, isFalse);
  });

  test(
    'one board, Black to move: the partner board is A + B\'s to move',
    () async {
      lab.play(BoardNumber.one, 'e2e4');
      await on();
      final zero = hivemind.asked.firstWhere((q) => q.team == Team.ab);
      expect(zero.position.turn(BoardNumber.two), Side.black);
      expect(zero.mustMove, MustMove.either);
      // Its lines are read on the table searched, where B is on move.
      final row = (engine.lines as LinesOn).rows[BoardNumber.one]!.first;
      expect(row.table.turn(BoardNumber.two), Side.black);
    },
  );

  test(
    'two boards: each team with a move, sitting as the clock says',
    () async {
      lab.showBoards(LabBoards.two);
      lab.setClock(ClockCase.cdMaySit);
      await on();
      final first = hivemind.asked.take(2).toList();
      expect(first.map((q) => (q.team, q.mustMove, q.maySit)), [
        (Team.ab, MustMove.either, false),
        (Team.cd, MustMove.either, true),
      ]);
      expect((engine.lines as LinesOn).rows.keys, BoardNumber.values);
    },
  );

  test('two boards: a team on move on both shows each board\'s own best '
      'moves, not the same move in every joint line', () async {
    lab
      ..showBoards(LabBoards.two)
      ..play(BoardNumber.two, 'd2d4');
    hivemind.answer = (question) => question.team == Team.ab
        ? const HivemindSearched(
            best: JointMove('g1f3', 'd7d5'),
            lines: [
              JointLine(
                rank: 1,
                cp: 50,
                nodes: 800,
                pv: [JointMove('g1f3', 'd7d5')],
              ),
              JointLine(
                rank: 2,
                cp: 40,
                nodes: 800,
                pv: [JointMove('g1f3', 'e7e6')],
              ),
              JointLine(
                rank: 3,
                cp: 30,
                nodes: 800,
                pv: [JointMove('g1f3', null)],
              ),
              JointLine(
                rank: 4,
                cp: -400,
                nodes: 800,
                pv: [JointMove('e2e4', 'd7d5')],
              ),
            ],
          )
        : const HivemindSearched(best: null, lines: []);
    await on();
    final rows = (engine.lines as LinesOn).rows;
    expect(rows[BoardNumber.one]!.map((r) => r.move), ['g1f3', 'e2e4']);
    expect(rows[BoardNumber.two]!.map((r) => r.move), ['d7d5', 'e7e6', null]);
    expect(rows[BoardNumber.one]!.first.shift, 0);
    // e4 is far behind: its arrow is not drawn.
    expect(rows[BoardNumber.one]!.last.shift, greaterThan(0.2));
    expect(engine.rowsOn(BoardNumber.two), rows[BoardNumber.two]);
    engine.playBest(BoardNumber.two);
    expect(lab.line.of(BoardNumber.two).last.san, 'd5');
  });

  test('a new position drops the stale answer and starts over', () async {
    hivemind.hold = true;
    engine.open();
    engine.toggle();
    await settle();
    expect(hivemind.waiting, 1);
    lab.play(BoardNumber.one, 'e2e4');
    // The table changed: the search under way was told to stop.
    expect(hivemind.stops, greaterThan(0));
    hivemind.hold = false;
    for (var i = 0; i < 20; i++) {
      await settle();
    }
    final lines = engine.lines as LinesOn;
    expect(lines.position, lab.position);
    expect(lines.rows[BoardNumber.one], isNotEmpty);
  });

  test('a table seen before is answered from memory', () async {
    await on();
    final asked = hivemind.asked.length;
    lab.play(BoardNumber.one, 'e2e4');
    for (var i = 0; i < 20; i++) {
      await settle();
    }
    lab.step(-1);
    for (var i = 0; i < 20; i++) {
      await settle();
    }
    expect(hivemind.asked.length, asked * 2);
    expect((engine.lines as LinesOn).nodes, 4000);
  });

  test(
    'an engine that will not start turns the switch off and says why',
    () async {
      startFailure = 'No engine here.';
      await on();
      expect(engine.on, isFalse);
      expect((engine.lines as LinesStopped).reason, 'No engine here.');
    },
  );

  test('a board with no move to make is not searched', () async {
    lab.loadDualFen(
      'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3',
    );
    await on();
    expect(hivemind.asked, isEmpty);
    expect((engine.lines as LinesOn).thinking, isFalse);
  });

  group('an engine that reports as it searches', () {
    setUp(() => hivemind.streams = true);

    test('one board: one search per team, on two engines, the rows '
        'following each report', () async {
      hivemind.hold = true;
      await on();
      expect(starts, 2);
      expect(hivemind.asked.map((q) => (q.team, nodes(q))), [
        (Team.ab, 800),
        (Team.cd, 400),
      ]);
      var lines = engine.lines as LinesOn;
      expect(lines.rows[BoardNumber.one], hasLength(3));
      expect(lines.nodes, 50);
      expect(lines.progress, 50 / 800);
      expect(lines.thinking, isTrue);
      hivemind.report();
      await settle();
      lines = engine.lines as LinesOn;
      expect(lines.nodes, 100);
      // The other team has reported too: the zero is measured.
      expect(lines.score.text, '0.00');
      hivemind.release();
      for (var i = 0; i < 20; i++) {
        await settle();
      }
      lines = engine.lines as LinesOn;
      expect(lines.nodes, 200);
      expect(lines.thinking, isFalse);
      // Never restarted on the same table.
      expect(
        hivemind.asked.where((q) => nodes(q) != labClockNodes),
        hasLength(2),
      );
    });

    test('two boards: both teams stream, their nodes added', () async {
      lab.showBoards(LabBoards.two);
      hivemind.hold = true;
      await on();
      expect(hivemind.asked.map((q) => (q.team, nodes(q))), [
        (Team.ab, 800),
        (Team.cd, 800),
      ]);
      final lines = engine.lines as LinesOn;
      expect(lines.rows.keys, BoardNumber.values);
      expect(lines.nodes, 100);
      expect(lines.progress, 100 / 1600);
    });

    test('a new position cuts both searches short and drops their '
        'reports', () async {
      hivemind.hold = true;
      await on();
      final asked = hivemind.asked.length;
      lab.play(BoardNumber.one, 'e2e4');
      expect(hivemind.stops, greaterThan(0));
      for (var i = 0; i < 20; i++) {
        await settle();
      }
      expect(hivemind.asked.length, asked + 2);
      hivemind.report();
      await settle();
      final lines = engine.lines as LinesOn;
      expect(lines.position, lab.position);
      expect(lines.rows.keys, [BoardNumber.one]);
      expect(lines.thinking, isTrue);
    });

    test('a finished search is remembered for the table', () async {
      await on();
      final asked = hivemind.asked.length;
      lab.play(BoardNumber.one, 'e2e4');
      for (var i = 0; i < 20; i++) {
        await settle();
      }
      lab.step(-1);
      for (var i = 0; i < 20; i++) {
        await settle();
      }
      expect(hivemind.asked.length, asked * 2);
      final lines = engine.lines as LinesOn;
      expect(lines.nodes, 200);
      expect(lines.thinking, isFalse);
    });
  });
}
