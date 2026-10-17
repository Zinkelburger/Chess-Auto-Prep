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

  setUp(() {
    lab = BughouseLab();
    hivemind = ScriptedHivemind();
    startFailure = null;
    engine = LabEngine(
      lab: lab,
      passes: const [800, 4000],
      startEngine: () async => switch (startFailure) {
        final reason? => HivemindStartFailed(reason),
        null => HivemindStarted(hivemind),
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
    expect(hivemind.asked.map(nodes), [800, 800, 4000, 4000]);
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
    expect(lines.teams.keys, [Team.ab]);
    expect(lines.teams[Team.ab], hasLength(3));
    // Both teams read cp −200: the zero is measured and the table level.
    expect(lines.score.text, '0.00');
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
      final row = (engine.lines as LinesOn).teams[Team.cd]!.first;
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
      expect((engine.lines as LinesOn).teams.keys, [Team.ab, Team.cd]);
    },
  );

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
    expect(lines.teams[Team.cd], isNotEmpty);
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
}
