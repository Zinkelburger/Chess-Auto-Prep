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
  String? startFailure;
  var starts = 0;

  setUp(() {
    lab = BughouseLab();
    hypebeast = ScriptedHypeBeast();
    startFailure = null;
    starts = 0;
    engine = LabEngine(
      lab: lab,
      cores: 9,
      startEngine: () async {
        starts++;
        return switch (startFailure) {
          final reason? => HypeBeastStartFailed(reason),
          null => HypeBeastStarted(hypebeast),
        };
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
    engine.open();
    engine.toggle();
    await settle();
  }

  LinesOn shown() => engine.lines as LinesOn;

  test(
    'nothing is searched until the switch is on and the mode open',
    () async {
      engine.toggle();
      await settle();
      expect(hypebeast.asked, isEmpty);
      engine.toggle();
      engine.open();
      await settle();
      expect(hypebeast.asked, isEmpty);
      expect(engine.lines, isA<LinesOff>());
    },
  );

  test('one board: board 1 alone for its side to move, three lines, on all '
      'the cores but one, for ten seconds', () async {
    await on();
    final asked = hypebeast.asked.single;
    expect(asked.board, BoardNumber.one);
    expect(asked.coordination, isFalse);
    expect(asked.lines, 3);
    expect(asked.threads, 8);
    expect((asked.budget as TimeBudget).time, const Duration(seconds: 10));
    // The partner board is passed as the table has it.
    expect(asked.position, lab.position);
    expect(starts, 1);
    final lines = shown();
    expect(lines.thinking, isFalse);
    expect(lines.nodes, 200);
    expect(lines.rows.keys, [BoardNumber.one]);
    final rows = lines.rows[BoardNumber.one]!;
    expect(rows, hasLength(3));
    expect(rows.map((r) => r.score.text), ['-2.00', '-2.30', '-2.60']);
    expect(rows.every((r) => r.pv.length == 1), isTrue);
    // White on board 1 is A + B: the first row's score, as it stands.
    expect(lines.score.text, '-2.00');
  });

  test('one board, Black to move: its score is turned to A + B\'s', () async {
    lab.play(BoardNumber.one, 'e2e4');
    await on();
    final asked = hypebeast.asked.single;
    expect(
      asked.position.turn(BoardNumber.two),
      lab.position.turn(BoardNumber.two),
    );
    expect(shown().score.text, '+2.00');
    expect(shown().rows[BoardNumber.one]!.first.score.text, '+2.00');
  });

  test('one board: told the game that led to the table', () async {
    for (final uci in ['g1f3', 'b8c6']) {
      lab.play(BoardNumber.one, uci);
    }
    await on();
    expect(hypebeast.asked.single.played?.moves, ['1g1f3', '1b8c6']);
  });

  test(
    'two boards: each board with a move, coordinated, the cores shared',
    () async {
      lab.showBoards(LabBoards.two);
      await on();
      expect(
        hypebeast.asked.map(
          (q) => (q.board, q.coordination, q.lines, q.threads),
        ),
        [(BoardNumber.one, true, 1, 4), (BoardNumber.two, true, 1, 4)],
      );
      expect(starts, 2);
      final lines = shown();
      expect(lines.rows.keys, BoardNumber.values);
      // White moves on both: A's −2.00 and D's −2.00 (+2.00 for A + B) add.
      expect(lines.rows[BoardNumber.one]!.first.score.text, '-2.00');
      expect(lines.rows[BoardNumber.two]!.first.score.text, '+2.00');
      expect(lines.score.text, '0.00');
      expect(lines.nodes, 400);
    },
  );

  test('two boards: the engine is asked about the game played, and about '
      'the table alone once it was set up afresh', () async {
    lab.showBoards(LabBoards.two);
    for (final uci in ['g1f3', 'b8c6', 'f3g1', 'c6b8']) {
      lab.play(BoardNumber.one, uci);
    }
    await on();
    final asked = hypebeast.asked.first;
    expect(asked.played?.root, TablePosition.initial);
    expect(asked.played?.moves, ['1g1f3', '1b8c6', '1f3g1', '1c6b8']);

    // The same table set up afresh is another question, not a cached one.
    hypebeast.asked.clear();
    lab.loadDualFen(lab.position.dualFen);
    await settle();
    expect(hypebeast.asked, isNotEmpty);
    expect(hypebeast.asked.first.played?.moves, isEmpty);
  });

  test('two boards: the main line while searching, then the decision and '
      'the moves compared', () async {
    lab.showBoards(LabBoards.two);
    hypebeast.hold = true;
    await on();
    var rows = shown().rows[BoardNumber.one]!;
    expect(rows.map((r) => r.move), ['b1a3']);
    expect(shown().thinking, isTrue);
    hypebeast.release();
    await settle();
    rows = shown().rows[BoardNumber.one]!;
    expect(rows.map((r) => r.move), ['b1a3', 'b1c3', 'g1f3']);
    expect(rows.map((r) => r.score.text), ['-2.00', '-2.30', '-2.60']);
    expect(rows.first.shift, 0);
    expect(rows[1].shift, greaterThan(0));
    expect(shown().thinking, isFalse);
    expect(engine.rowsOn(BoardNumber.two), shown().rows[BoardNumber.two]);
    engine.playBest(BoardNumber.two);
    expect(lab.line.of(BoardNumber.two).last.san, 'Na3');
  });

  test('a decision to sit is a row without a score; the other board\'s '
      'score stands for the table', () async {
    lab.showBoards(LabBoards.two);
    hypebeast.answer = (question) => question.board == BoardNumber.one
        ? const HypeBeastSearched(
            decision: SeatDecision(null),
            report: SeatReport(nodes: 90),
          )
        : firstMoves(question);
    await on();
    final rows = shown().rows[BoardNumber.one]!;
    expect(rows.single.move, isNull);
    expect(rows.single.score.isEmpty, isTrue);
    expect(shown().score.text, '+2.00');
    engine.playBest(BoardNumber.one);
    expect(lab.line.of(BoardNumber.one), isEmpty);
  });

  test('a decision without a score stands for its board at the main '
      'search\'s score, so the bar keeps both boards', () async {
    lab.showBoards(LabBoards.two);
    hypebeast.answer = (question) {
      if (question.board != BoardNumber.one) return firstMoves(question);
      // A decides Nf3, which its coordinator did not score; its main search
      // ended at −2.70 for A.
      return const HypeBeastSearched(
        decision: SeatDecision('g1f3'),
        report: SeatReport(
          lines: [
            SeatLine(multipv: 1, depth: 12, cp: -200, nodes: 90, pv: ['b1a3']),
          ],
          coordination: Coordination('world_switch', [
            Candidate('b1a3', l: -200, s: -210),
            Candidate('g1f3'),
          ]),
          nodes: 90,
          summary: {'main_score_cp': '-270', 'reason': 'world_switch'},
        ),
      );
    };
    await on();
    final rows = shown().rows[BoardNumber.one]!;
    expect(rows.first.move, 'g1f3');
    expect(rows.first.score.isEmpty, isTrue);
    // −2.70 on board 1 and D's −2.00 (+2.00 for A + B) on board 2.
    expect(shown().score.text, '-0.70');
  });

  test('a sit stands for its board at the main search\'s score', () async {
    lab.showBoards(LabBoards.two);
    hypebeast.answer = (question) => question.board == BoardNumber.one
        ? const HypeBeastSearched(
            decision: SeatDecision(null),
            report: SeatReport(
              coordination: Coordination('hold_mated', []),
              nodes: 90,
              summary: {'main_score_cp': '-99998', 'reason': 'hold_mated'},
            ),
          )
        : firstMoves(question);
    await on();
    expect(shown().rows[BoardNumber.one]!.single.move, isNull);
    // A is mated in one whatever it plays: C + D's mate.
    expect(shown().score.text, '#-1');
  });

  test('the coordinator\'s own line for its decision is the first row, with '
      'its score; without one the row is as before', () async {
    lab.showBoards(LabBoards.two);
    hypebeast.answer = (question) {
      if (question.board != BoardNumber.one) return firstMoves(question);
      return const HypeBeastSearched(
        decision: SeatDecision('g1f3'),
        report: SeatReport(
          lines: [
            SeatLine(multipv: 1, depth: 12, cp: -200, nodes: 90, pv: ['b1a3']),
          ],
          coordination: Coordination(
            'world_switch',
            [Candidate('b1a3', l: -200, s: -210), Candidate('g1f3')],
            decisionLine: (
              move: 'g1f3',
              cp: -150,
              mate: null,
              depth: 14,
              pv: ['g1f3', 'g8f6', 'b1c3'],
            ),
          ),
          nodes: 90,
          summary: {'main_score_cp': '-270'},
        ),
      );
    };
    await on();
    final first = shown().rows[BoardNumber.one]!.first;
    expect(first.move, 'g1f3');
    expect(first.score.text, '-1.50');
    expect(first.pv, ['g1f3', 'g8f6', 'b1c3']);
    expect(shown().score.text, '+0.50');
  });

  group('clocks', () {
    /// Every seat has moved once, its clock noted after the move.
    const game = '''
[WhiteA "a"]
[BlackA "c"]
[WhiteB "d"]
[BlackB "b"]
[TimeControl "120+0"]

1A. e4 {118.500} 1B. d4 {117.000} 1a. e5 {116.200} 1b. d5 {115.900} *
''';
    const clocks = TableClocks(
      a: Duration(milliseconds: 118500),
      b: Duration(milliseconds: 115900),
      c: Duration(milliseconds: 116200),
      d: Duration(milliseconds: 117000),
    );

    test(
      'two boards with all four clocks: every search is sent them',
      () async {
        lab.pasteMoves(game);
        expect(lab.boards, LabBoards.two);
        await on();
        expect(hypebeast.asked.map((q) => (q.board, q.clocks)), [
          (BoardNumber.one, clocks),
          (BoardNumber.two, clocks),
        ]);
        expect(clocks.option, '118500,116200,117000,115900');
      },
    );

    test('one board, or a table without all four clocks, sends none', () async {
      lab.pasteMoves(game);
      lab.showBoards(LabBoards.one);
      await on();
      expect(hypebeast.asked.single.clocks, isNull);

      // Only A and D have moved, in a game that does not say how long the
      // clocks started with: B's and C's are unknown.
      hypebeast.asked.clear();
      lab
        ..pasteMoves('1A. e4 {118.500} 1B. d4 {117.000} *')
        ..showBoards(LabBoards.two);
      await settle();
      expect(hypebeast.asked.map((q) => q.clocks), [null, null]);
    });

    test('the clocks are part of what is remembered', () async {
      lab.pasteMoves(game);
      await on();
      expect(hypebeast.asked, hasLength(2));
      // The same table, reached with other clocks, is searched again.
      lab.pasteMoves(game.replaceAll('118.500', '60.000'));
      await settle();
      expect(hypebeast.asked, hasLength(4));
      expect(
        hypebeast.asked.last.clocks?.a,
        const Duration(milliseconds: 60000),
      );
      // Back to the first clocks: from memory.
      lab.pasteMoves(game);
      await settle();
      expect(hypebeast.asked, hasLength(4));
    });

    test('a process that was given clocks is replaced before a search '
        'without them', () async {
      final started = <ScriptedHypeBeast>[];
      final fresh = LabEngine(
        lab: lab,
        cores: 9,
        startEngine: () async {
          final engine = ScriptedHypeBeast();
          started.add(engine);
          return HypeBeastStarted(engine);
        },
      );
      addTearDown(fresh.dispose);
      lab.pasteMoves(game);
      fresh
        ..open()
        ..toggle();
      await settle();
      expect(started, hasLength(2));
      expect(started.every((e) => e.clocked && !e.gone), isTrue);

      // Board 1 alone: no clocks, so engine 0 is quit and another started.
      lab.showBoards(LabBoards.one);
      await settle();
      expect(started, hasLength(3));
      expect(started[0].gone, isTrue);
      expect(started[1].gone, isFalse);
      expect(started[2].asked.single.clocks, isNull);
      expect((fresh.lines as LinesOn).rows[BoardNumber.one], hasLength(3));

      // Clocks again, on a new table: the unclocked process takes them.
      lab
        ..showBoards(LabBoards.two)
        ..play(BoardNumber.one, 'g1f3');
      await settle();
      expect(started, hasLength(3));
      expect(started[2].asked.last.clocks, clocks);
      expect(started[2].clocked, isTrue);
    });
  });

  test('a mate on either board is the table\'s score', () async {
    lab.showBoards(LabBoards.two);
    hypebeast.answer = (question) => question.board == BoardNumber.two
        ? const HypeBeastSearched(
            decision: SeatDecision('e2e4'),
            report: SeatReport(
              lines: [
                SeatLine(
                  multipv: 1,
                  depth: 9,
                  mate: 3,
                  nodes: 50,
                  pv: ['e2e4'],
                ),
              ],
              nodes: 50,
            ),
          )
        : firstMoves(question);
    await on();
    // D, White on board 2, mates: C + D's mate, minus for A + B.
    expect(shown().rows[BoardNumber.two]!.first.score.text, '#-3');
    expect(shown().score.text, '#-3');
  });

  test('a new position drops the stale answer and starts over', () async {
    hypebeast.hold = true;
    engine.open();
    engine.toggle();
    await settle();
    expect(hypebeast.waiting, 1);
    lab.play(BoardNumber.one, 'e2e4');
    // The table changed: the search under way was told to stop.
    expect(hypebeast.stops, greaterThan(0));
    hypebeast.hold = false;
    await settle();
    final lines = shown();
    expect(lines.position, lab.position);
    expect(lines.rows[BoardNumber.one]!.first.move, 'a7a5');
    expect(hypebeast.asked, hasLength(2));
  });

  test('a table seen before is answered from memory', () async {
    await on();
    lab.play(BoardNumber.one, 'e2e4');
    await settle();
    lab.step(-1);
    await settle();
    expect(hypebeast.asked, hasLength(2));
    expect(shown().nodes, 200);
    expect(shown().thinking, isFalse);
  });

  test('the board count is part of what is remembered', () async {
    await on();
    lab.showBoards(LabBoards.two);
    await settle();
    expect(hypebeast.asked.map((q) => q.coordination), [false, true, true]);
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

  test('a start that throws is a start that failed, and the next one tries '
      'again', () async {
    var throwing = true;
    final flaky = LabEngine(
      lab: lab,
      cores: 9,
      startEngine: () async {
        starts++;
        if (throwing) throw const FormatException('bad manifest');
        return HypeBeastStarted(hypebeast);
      },
    );
    addTearDown(flaky.dispose);
    flaky
      ..open()
      ..toggle();
    await settle();
    expect(flaky.on, isFalse);
    expect(
      (flaky.lines as LinesStopped).reason,
      'The bughouse engine did not start.',
    );
    throwing = false;
    flaky.toggle();
    await settle();
    expect(starts, 2);
    expect((flaky.lines as LinesOn).rows[BoardNumber.one], hasLength(3));
  });

  test('a search the engine reports an error in turns the switch off and '
      'is not remembered', () async {
    HypeBeastAnswer Function(HypeBeastQuestion) answer = (_) =>
        const HypeBeastFailed(
          'The bughouse engine could not play the moves that led here.',
        );
    final engines = <ScriptedHypeBeast>[];
    final refusing = LabEngine(
      lab: lab,
      cores: 9,
      startEngine: () async {
        final started = ScriptedHypeBeast()..answer = answer;
        engines.add(started);
        return HypeBeastStarted(started);
      },
    );
    addTearDown(refusing.dispose);
    refusing
      ..open()
      ..toggle();
    await settle();
    expect(
      (refusing.lines as LinesStopped).reason,
      'Analysis failed: The bughouse engine could not play the moves that '
      'led here.',
    );
    answer = firstMoves;
    refusing.toggle();
    await settle();
    // Asked again, by a new process, rather than answered from memory.
    expect(engines, hasLength(2));
    expect(engines.last.asked, hasLength(1));
    expect((refusing.lines as LinesOn).rows[BoardNumber.one], hasLength(3));
  });

  test('an engine that fails mid-search turns the switch off', () async {
    hypebeast.hold = true;
    await on();
    hypebeast.crash();
    await settle();
    expect(engine.on, isFalse);
    expect(
      (engine.lines as LinesStopped).reason,
      'Analysis failed: The bughouse engine stopped.',
    );
  });

  test('a board with no move to make is not searched', () async {
    lab.loadDualFen(
      'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3',
    );
    await on();
    expect(hypebeast.asked, isEmpty);
    expect(shown().thinking, isFalse);
  });

  group('as the engine reports', () {
    test('the rows, nodes and progress follow each report', () async {
      hypebeast.hold = true;
      await on();
      var lines = shown();
      expect(lines.rows[BoardNumber.one], hasLength(3));
      expect(lines.nodes, 50);
      expect(lines.progress, inInclusiveRange(0.0, 1.0));
      expect(lines.thinking, isTrue);
      hypebeast.report();
      await settle();
      expect(shown().nodes, 100);
      hypebeast.release();
      await settle();
      lines = shown();
      expect(lines.nodes, 200);
      expect(lines.thinking, isFalse);
      expect(lines.progress, 1);
      // Never restarted on the same table.
      expect(hypebeast.asked, hasLength(1));
    });

    test('two boards: both stream, their nodes added', () async {
      lab.showBoards(LabBoards.two);
      hypebeast.hold = true;
      await on();
      final lines = shown();
      expect(lines.rows.keys, BoardNumber.values);
      expect(lines.nodes, 100);
      expect(lines.thinking, isTrue);
    });

    test(
      'a new position cuts the searches short and drops their reports',
      () async {
        lab.showBoards(LabBoards.two);
        hypebeast.hold = true;
        await on();
        lab.play(BoardNumber.one, 'e2e4');
        expect(hypebeast.stops, greaterThan(0));
        await settle();
        expect(hypebeast.asked, hasLength(4));
        hypebeast.report();
        await settle();
        final lines = shown();
        expect(lines.position, lab.position);
        expect(lines.rows[BoardNumber.one]!.first.move, 'a7a5');
        expect(lines.thinking, isTrue);
      },
    );

    test(
      'switched off, the search is cut short and nothing is shown',
      () async {
        hypebeast.hold = true;
        await on();
        engine.toggle();
        expect(hypebeast.stops, greaterThan(0));
        await settle();
        expect(engine.lines, isA<LinesOff>());
      },
    );
  });
}
