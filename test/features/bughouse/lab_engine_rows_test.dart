// What the Bughouse lab's engine shows: that it is thinking from the start,
// three rows a board at most, a mate found by either team as the score,
// nothing for a table it is no longer looking at, and passes on one engine.
import 'package:chess_auto_prep/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/features/bughouse/lab_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

void main() {
  late BughouseLab lab;
  late ScriptedHivemind hivemind;
  late LabEngine engine;

  var starts = 0;

  setUp(() {
    lab = BughouseLab();
    hivemind = ScriptedHivemind();
    starts = 0;
    engine = LabEngine(
      lab: lab,
      passes: const [800],
      liveNodes: 800,
      zeroNodes: 400,
      startEngine: () async {
        starts++;
        return HivemindStarted(hivemind);
      },
    );
  });
  tearDown(() {
    engine.dispose();
    lab.dispose();
  });

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> on() async {
    engine
      ..open()
      ..toggle();
    await settle();
  }

  JointLine line(int rank, String move, {int? cp = 10, int? mate}) => JointLine(
    rank: rank,
    cp: mate == null ? cp : null,
    mate: mate,
    nodes: 800,
    pv: [JointMove(move, null)],
  );

  test('says it is thinking from the moment it starts', () async {
    hivemind.hold = true;
    engine
      ..open()
      ..toggle();
    await Future<void>.delayed(Duration.zero);
    expect((engine.lines as LinesOn).thinking, isTrue);
  });

  test('shows three rows a board at most', () async {
    hivemind.answer = (question) => question.team == Team.ab
        ? HivemindSearched(
            best: const JointMove('e2e4', null),
            lines: [
              line(1, 'e2e4'),
              line(2, 'd2d4'),
              line(3, 'c2c4'),
              line(4, 'g1f3'),
              line(5, 'b1c3'),
            ],
          )
        : const HivemindSearched(best: null, lines: []);
    await on();
    expect(engine.rowsOn(BoardNumber.one), hasLength(3));
  });

  test('a mate found by either team is the score', () async {
    hivemind.answer = (question) => question.team == Team.ab
        ? HivemindSearched(
            best: const JointMove('e2e4', null),
            lines: [line(1, 'e2e4', cp: 30)],
          )
        : HivemindSearched(
            best: const JointMove('e7e5', null),
            lines: [line(1, 'e7e5', mate: 3)],
          );
    await on();
    expect((engine.lines as LinesOn).score.mate, isNotNull);
  });

  test('a table changed while the mode is away shows no rows', () async {
    await on();
    expect(engine.rowsOn(BoardNumber.one), isNotEmpty);
    engine.close();
    lab.play(BoardNumber.one, 'e2e4');
    expect(engine.rowsOn(BoardNumber.one), isEmpty);
  });

  test('an answer to a table already left is never shown', () async {
    hivemind.hold = true;
    await on();
    lab.play(BoardNumber.one, 'e2e4');
    final stale = <LinesOn>[];
    void heard() {
      if (engine.lines case final LinesOn lines
          when lines.rows.isNotEmpty && lines.position != lab.position) {
        stale.add(lines);
      }
    }

    engine.addListener(heard);
    addTearDown(() => engine.removeListener(heard));
    hivemind.hold = false;
    for (var i = 0; i < 5; i++) {
      hivemind.release();
      await settle();
    }
    expect(stale, isEmpty);
    expect((engine.lines as LinesOn).rows, isNotEmpty);
  });

  test('passes run on one engine', () async {
    await on();
    expect(starts, 1);
  });

  test('an answer that comes after the mode is left is not shown', () async {
    hivemind.hold = true;
    await on();
    engine.close();
    hivemind.release();
    await settle();
    final lines = engine.lines;
    expect(lines is LinesOn ? lines.rows : const {}, isEmpty);
  });
}
