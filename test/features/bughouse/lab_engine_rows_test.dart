// What the Bughouse lab's engine shows: that it is thinking from the start,
// three rows a board at most, nothing for a table it is no longer looking
// at, and one engine with one board.
import 'package:chess_auto_prep/chess/bughouse/hypebeast.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/hypebeast_engine.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/features/bughouse/lab_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_bughouse.dart';

void main() {
  late BughouseLab lab;
  late ScriptedHypeBeast hypebeast;
  late LabEngine engine;

  var starts = 0;

  setUp(() {
    lab = BughouseLab();
    hypebeast = ScriptedHypeBeast();
    starts = 0;
    engine = LabEngine(
      lab: lab,
      cores: 4,
      startEngine: () async {
        starts++;
        return HypeBeastStarted(hypebeast);
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

  SeatLine line(int rank, String move) =>
      SeatLine(multipv: rank, depth: 10, cp: 10, nodes: 800, pv: [move]);

  test('says it is thinking from the moment it starts', () async {
    hypebeast.hold = true;
    engine
      ..open()
      ..toggle();
    await Future<void>.delayed(Duration.zero);
    expect((engine.lines as LinesOn).thinking, isTrue);
  });

  test('shows three rows a board at most', () async {
    hypebeast.answer = (question) => HypeBeastSearched(
      decision: const SeatDecision('e2e4'),
      report: SeatReport(
        lines: [
          line(1, 'e2e4'),
          line(2, 'd2d4'),
          line(3, 'c2c4'),
          line(4, 'g1f3'),
          line(5, 'b1c3'),
        ],
      ),
    );
    await on();
    expect(engine.rowsOn(BoardNumber.one), hasLength(3));
  });

  test('a table changed while the mode is away shows no rows', () async {
    await on();
    expect(engine.rowsOn(BoardNumber.one), isNotEmpty);
    engine.close();
    lab.play(BoardNumber.one, 'e2e4');
    expect(engine.rowsOn(BoardNumber.one), isEmpty);
  });

  test('an answer to a table already left is never shown', () async {
    hypebeast.hold = true;
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
    hypebeast.hold = false;
    for (var i = 0; i < 5; i++) {
      hypebeast.release();
      await settle();
    }
    expect(stale, isEmpty);
    expect((engine.lines as LinesOn).rows, isNotEmpty);
  });

  test('one board runs on one engine', () async {
    await on();
    expect(starts, 1);
  });

  test('an answer that comes after the mode is left is not shown', () async {
    hypebeast.hold = true;
    await on();
    final before = (engine.lines as LinesOn).nodes;
    engine.close();
    hypebeast.release();
    await settle();
    final lines = engine.lines as LinesOn;
    expect(lines.nodes, before);
    expect(lines.thinking, isTrue);
  });
}
